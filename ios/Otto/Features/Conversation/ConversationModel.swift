import Foundation
import Observation

/// One row in the conversation transcript.
struct TranscriptEntry: Identifiable {
    enum Role {
        case user
        case otto
        /// System-ish asides (permission problems, request failures,
        /// "Interrupted."). Rendered small and centered.
        case notice
    }

    let id = UUID()
    var role: Role
    var text: String
    /// For user rows: false while the transcriber is still revising the
    /// partial; the row re-renders in place as recognition sharpens.
    var isFinal: Bool
}

/// Bridges VoiceLoop (an actor) to SwiftUI.
///
/// Consumes the loop's two streams exactly once for the app's lifetime: the
/// lossless event stream becomes transcript rows and state, the lossy mic
/// stream becomes waveform bars. Everything here is MainActor; every call
/// into the loop hops through a Task.
@MainActor
@Observable
final class ConversationModel {

    // MARK: - UI state

    private(set) var state: VoiceLoopState = .idle
    private(set) var entries: [TranscriptEntry] = []
    private(set) var signedIn = false

    /// The server-side conversation being continued. Persisted so a relaunch
    /// within the session's 30-minute idle window keeps its context.
    private(set) var sessionId: String?

    /// The permanently visible composer. Voice is the default, never a
    /// requirement — this field must always work.
    var composerText = ""

    /// Newest-last normalized mic levels (0…1), fixed width for stable bars.
    private(set) var micBars: [Float] = ConversationModel.silentBars
    private(set) var lastLevelDb: Float = -120

    // MARK: - Message drafting

    /// Where the draft flow stands. The view shows a confirmation card in
    /// `.confirming`; spoken confirmations arrive as captured utterances.
    enum DraftStage: Equatable {
        case idle
        case choosingContact(draftBody: String, candidates: [ContactResolver.Candidate])
        case confirming(ComposeRequest)
    }

    private(set) var draftStage: DraftStage = .idle
    /// Drives the system compose sheet (.sheet(item:)).
    var composeRequest: ComposeRequest?

    private var pendingDraft: (recipientName: String, body: String)?
    private let contacts = ContactResolver()

    // MARK: - Debug overlay

    private(set) var overlayVisible = false
    private(set) var lastTimings: TurnTimings?
    private(set) var debugSnapshot: VoiceDebugSnapshot?

    /// Live-tunable from the overlay slider; persisted so a good value found
    /// on-device survives relaunches.
    var bargeThresholdDb: Float {
        didSet {
            UserDefaults.standard.set(bargeThresholdDb, forKey: Self.bargeThresholdKey)
            let value = bargeThresholdDb
            Task { await self.voiceLoop.setBargeThreshold(value) }
        }
    }

    // MARK: - Plumbing

    private static let bargeThresholdKey = "otto.debug.bargeThresholdDb"
    private static let sessionKey = "otto.sessionId"
    private static let barCount = 36
    private static var silentBars: [Float] { Array(repeating: 0, count: barCount) }

    private let auth: any AuthProvider
    private let voiceLoop: VoiceLoop
    /// Created with the model at app start so its notification delegate is
    /// installed before any reminder can fire in the foreground.
    private let reminders = ReminderScheduler()
    /// The task screen's state — task events upsert into it live so
    /// voice-added items animate in while the screen is open.
    private let tasksModel: TasksModel
    private var activated = false
    private var ottoTurnOpen = false
    private var eventTask: Task<Void, Never>?
    private var levelTask: Task<Void, Never>?

    init(auth: any AuthProvider, tasksModel: TasksModel) {
        self.auth = auth
        self.tasksModel = tasksModel
        self.voiceLoop = VoiceLoop(auth: auth)
        self.bargeThresholdDb =
            (UserDefaults.standard.object(forKey: Self.bargeThresholdKey) as? Float) ?? -30
        self.sessionId = UserDefaults.standard.string(forKey: Self.sessionKey)
        self.signedIn = auth.currentUserId != nil
    }

    /// Idempotent; called from the root view's .task. Starts the stream
    /// consumers and pushes the persisted barge threshold into the loop.
    func activate() {
        guard !activated else { return }
        activated = true

        eventTask = Task {
            let events = await self.voiceLoop.events()
            for await event in events {
                self.handle(event)
            }
        }
        levelTask = Task {
            let levels = await self.voiceLoop.micLevels()
            for await db in levels {
                self.handleLevel(db)
            }
        }
        let threshold = bargeThresholdDb
        let session = sessionId
        Task {
            await self.voiceLoop.setBargeThreshold(threshold)
            await self.voiceLoop.setSession(session)
        }
    }

    /// Re-reads auth state — called on appear and whenever the settings
    /// sheet closes (sign in/out happens in there).
    func refreshAccount() {
        signedIn = auth.currentUserId != nil
    }

    // MARK: - Intents

    /// Mic button: idle starts the voice conversation; any other state stops
    /// everything (including speech from a typed turn).
    func toggleVoice() {
        if state == .idle {
            Task {
                guard await self.prepareForTurn() else { return }
                await self.voiceLoop.startConversation()
            }
        } else {
            Task { await self.voiceLoop.stopConversation() }
        }
    }

    func sendTyped() {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        composerText = ""
        // Mid-draft, typed input is the confirmation/choice — never a turn.
        if draftStage != .idle {
            Task { await self.handleDraftReply(text) }
            return
        }
        Task {
            guard await self.prepareForTurn() else {
                // Give the message back — a failed precondition (signed out,
                // bad server URL) must not eat what the user typed.
                self.composerText = text
                return
            }
            await self.voiceLoop.submitText(text)
        }
    }

    /// Tapped confirmation on the draft card.
    func confirmDraftTapped() {
        if case .confirming(let request) = draftStage {
            composeRequest = request
            resetDraftFlow()
        }
    }

    /// Tapped cancel on the draft card.
    func cancelDraftTapped() {
        resetDraftFlow()
        appendNotice("Draft discarded.")
    }

    func toggleOverlay() {
        overlayVisible.toggle()
        if overlayVisible {
            refreshSnapshot()
        }
    }

    /// Clears the session and transcript; the next turn starts a fresh
    /// conversation server-side. Speech already in flight is left to finish.
    func newConversation() {
        sessionId = nil
        UserDefaults.standard.removeObject(forKey: Self.sessionKey)
        entries = []
        ottoTurnOpen = false
        lastTimings = nil
        Task { await self.voiceLoop.setSession(nil) }
    }

    // MARK: - Turn preconditions

    /// Signed in + a parseable server URL pushed into the loop. Failures land
    /// in the transcript as notices instead of silently doing nothing.
    private func prepareForTurn() async -> Bool {
        refreshAccount()
        guard signedIn else {
            appendNotice("Sign in first — open settings from the top right.")
            return false
        }
        let urlString =
            UserDefaults.standard.string(forKey: DebugModel.serverURLKey) ?? "http://localhost:8080"
        guard let url = URL(string: urlString), url.scheme != nil else {
            appendNotice("Invalid server URL: \(urlString)")
            return false
        }
        await voiceLoop.configure(serverURL: url)
        // Idempotent re-seed: kills any launch race between activate()'s
        // seeding task and the first turn.
        await voiceLoop.setSession(sessionId)
        return true
    }

    // MARK: - Event handling

    private func handle(_ event: ConversationEvent) {
        switch event {
        case .state(let newState):
            state = newState
            if newState == .listening {
                // Reached after done AND after barge-in — either way the
                // otto row is finished growing.
                ottoTurnOpen = false
            }
            if newState == .idle {
                // The conversation can end (stop button, interruption) while
                // the last row is still a live partial; seal it so a later,
                // unrelated turn can't overwrite it in place.
                finalizeTrailingUserRow()
            }
            if newState == .idle || newState == .thinking {
                micBars = Self.silentBars
            }
        case .userPartial(let text):
            upsertUserRow(text, isFinal: false)
        case .userFinal(let text):
            upsertUserRow(text, isFinal: true)
        case .ottoToken(let token):
            appendOttoToken(token)
        case .ottoDone:
            ottoTurnOpen = false
            if pendingDraft != nil {
                // Start the read-back flow only after Otto's own words finish.
                Task { await self.beginDraftFlow() }
            }
        case .draft(let recipientName, let body):
            pendingDraft = (recipientName, body)
        case .capturedUtterance(let text):
            Task { await self.handleDraftReply(text) }
        case .task(let task):
            tasksModel.apply(task)
            Task {
                let outcome = await self.reminders.handle(task)
                if case .permissionDenied = outcome {
                    self.appendNotice(
                        "Notifications are off, so this reminder won't ring. Enable them for Otto in Settings."
                    )
                }
            }
        case .session(let id):
            sessionId = id
            UserDefaults.standard.set(id, forKey: Self.sessionKey)
        case .timing(let timings):
            lastTimings = timings
            if overlayVisible {
                refreshSnapshot()
            }
        case .notice(let text):
            appendNotice(text)
        }
    }

    private func upsertUserRow(_ text: String, isFinal: Bool) {
        ottoTurnOpen = false
        if let index = entries.indices.last, entries[index].role == .user, !entries[index].isFinal {
            entries[index].text = text
            entries[index].isFinal = isFinal
        } else {
            entries.append(TranscriptEntry(role: .user, text: text, isFinal: isFinal))
        }
    }

    private func appendOttoToken(_ token: String) {
        if ottoTurnOpen, let index = entries.indices.last, entries[index].role == .otto {
            entries[index].text += token
        } else {
            entries.append(TranscriptEntry(role: .otto, text: token, isFinal: true))
            ottoTurnOpen = true
        }
    }

    private func appendNotice(_ text: String) {
        entries.append(TranscriptEntry(role: .notice, text: text, isFinal: true))
    }

    private func finalizeTrailingUserRow() {
        if let index = entries.indices.last, entries[index].role == .user, !entries[index].isFinal {
            entries[index].isFinal = true
        }
    }

    // MARK: - Draft flow

    /// parse → resolve contact → READ BACK ALOUD → confirm → compose sheet.
    /// The read-back is mandatory and deterministic — client-spoken, never
    /// trusted to the model's own phrasing.
    private func beginDraftFlow() async {
        guard let draft = pendingDraft else { return }
        pendingDraft = nil

        guard MessageComposeView.canSend else {
            await voiceLoop.announce("This device can't send text messages, so I can't set that up.")
            return
        }

        switch await contacts.resolve(name: draft.recipientName) {
        case .denied:
            await voiceLoop.announce(
                "I need contacts access to text people. You can enable it for Otto in Settings."
            )
            appendNotice("Contacts access is off — enable it for Otto in Settings.")
        case .none:
            await voiceLoop.announce("I don't have \(draft.recipientName) in your contacts.")
        case .matches(let candidates):
            if candidates.count == 1, let only = candidates.first {
                await readBackAndConfirm(candidate: only, body: draft.body)
            } else {
                draftStage = .choosingContact(draftBody: draft.body, candidates: candidates)
                let names = candidates.map(\.displayName).joined(separator: ", ")
                await voiceLoop.armUtteranceCapture()
                await voiceLoop.announce(
                    "I have \(candidates.count) matches: \(names). Which one?"
                )
            }
        }
    }

    private func readBackAndConfirm(candidate: ContactResolver.Candidate, body: String) async {
        let request = ComposeRequest(
            recipientName: candidate.displayName,
            recipients: [candidate.phoneNumber],
            body: body
        )
        draftStage = .confirming(request)
        await voiceLoop.armUtteranceCapture()
        await voiceLoop.announce("To \(candidate.displayName): \(body). Send it?")
    }

    private static let affirmatives: Set<String> = [
        "yes", "yeah", "yep", "sure", "send", "send it", "confirm", "do it", "go ahead", "ok", "okay",
    ]
    private static let negatives: Set<String> = [
        "no", "nope", "cancel", "don't", "do not", "stop", "never mind", "nevermind", "discard",
    ]
    private static let ordinals = ["first", "second", "third", "fourth", "fifth"]

    /// A spoken (captured) or typed reply while the draft flow is active.
    private func handleDraftReply(_ text: String) async {
        let reply = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)

        switch draftStage {
        case .idle:
            return
        case .choosingContact(let body, let candidates):
            if Self.negatives.contains(reply) {
                resetDraftFlow()
                await voiceLoop.announce("Cancelled.")
                return
            }
            if let picked = Self.pickCandidate(from: candidates, reply: reply) {
                await readBackAndConfirm(candidate: picked, body: body)
            } else {
                resetDraftFlow()
                await voiceLoop.announce("I couldn't tell which one. Cancelled.")
            }
        case .confirming(let request):
            if Self.affirmatives.contains(reply) {
                resetDraftFlow()
                composeRequest = request
            } else if Self.negatives.contains(reply) {
                resetDraftFlow()
                await voiceLoop.announce("Cancelled.")
            } else {
                // Anything ambiguous must not send. Cancelling beats guessing.
                resetDraftFlow()
                await voiceLoop.announce("That wasn't a yes, so I've discarded the draft.")
            }
        }
    }

    private static func pickCandidate(
        from candidates: [ContactResolver.Candidate],
        reply: String
    ) -> ContactResolver.Candidate? {
        for (index, ordinal) in ordinals.enumerated() where reply.contains(ordinal) {
            if index < candidates.count {
                return candidates[index]
            }
        }
        return candidates.first { candidate in
            let name = candidate.displayName.lowercased()
            return name.contains(reply) || reply.contains(name)
                || name.split(separator: " ").contains { reply.contains($0) }
        }
    }

    private func resetDraftFlow() {
        draftStage = .idle
        pendingDraft = nil
        Task { await self.voiceLoop.disarmUtteranceCapture() }
    }

    private func handleLevel(_ db: Float) {
        lastLevelDb = db
        // Speech at arm's length spans roughly -58dB (quiet) to -20dB (loud).
        let normalized = max(0, min(1, (db + 58) / 38))
        micBars.removeFirst()
        micBars.append(normalized)
    }

    private func refreshSnapshot() {
        Task { self.debugSnapshot = await self.voiceLoop.debugSnapshot() }
    }
}
