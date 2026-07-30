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

    /// The permanently visible composer. Voice is the default, never a
    /// requirement — this field must always work.
    var composerText = ""

    /// Newest-last normalized mic levels (0…1), fixed width for stable bars.
    private(set) var micBars: [Float] = ConversationModel.silentBars
    private(set) var lastLevelDb: Float = -120

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
    private static let barCount = 36
    private static var silentBars: [Float] { Array(repeating: 0, count: barCount) }

    private let auth: any AuthProvider
    private let voiceLoop: VoiceLoop
    private var activated = false
    private var ottoTurnOpen = false
    private var eventTask: Task<Void, Never>?
    private var levelTask: Task<Void, Never>?

    init(auth: any AuthProvider) {
        self.auth = auth
        self.voiceLoop = VoiceLoop(auth: auth)
        self.bargeThresholdDb =
            (UserDefaults.standard.object(forKey: Self.bargeThresholdKey) as? Float) ?? -30
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
        Task { await self.voiceLoop.setBargeThreshold(threshold) }
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
        Task {
            guard await self.prepareForTurn() else { return }
            await self.voiceLoop.submitText(text)
        }
    }

    func toggleOverlay() {
        overlayVisible.toggle()
        if overlayVisible {
            refreshSnapshot()
        }
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
