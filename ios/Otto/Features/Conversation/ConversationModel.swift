import Foundation
import Observation
import SwiftUI

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

    // MARK: - Calendar confirmation

    /// A resolved calendar change awaiting the user's confirmation.
    enum ProposedCalendarChange: Equatable {
        case create(EventDraft)
        case move(original: CalendarEvent, newStart: Date, newEnd: Date)
    }

    enum CalendarStage: Equatable {
        case idle
        case confirming(ProposedCalendarChange)
    }

    private(set) var calendarStage: CalendarStage = .idle
    private var pendingCalendarProposal: CalendarProposal?

    // MARK: - Plan generation

    /// Generation takes 30-60 seconds; these drive the on-screen progress
    /// text ("Designing your week…"). Never a spinner.
    enum PlanPhase: Equatable {
        case idle
        case designing
        case scheduling
    }

    private(set) var planPhase: PlanPhase = .idle
    /// The freshly generated plan — the full detail on screen while the
    /// voice speaks only a summary. Never read aloud.
    private(set) var planCard: Plan?

    // MARK: - Plan calendar scheduling

    /// After a NEW plan lands and Otto's summary finishes, the device offers
    /// to put the sessions on the calendar — a confirmation card plus a
    /// spoken yes/no, writes verified by read-back, ids reported to the
    /// server so adaptation can move them.
    enum PlanScheduleStage: Equatable {
        case idle
        case offering
    }

    private(set) var planScheduleStage: PlanScheduleStage = .idle
    private(set) var planScheduleDrafts: [PlanScheduling.SessionEvent] = []
    private var planToSchedule: Plan?
    private var pendingPlanOffer: Plan?

    // MARK: - Guided sessions

    /// A killed-mid-session snapshot awaiting the spoken resume offer's
    /// yes/no ("You were 4 steps into Upper A. Pick up where you left off?").
    private var pendingGuidanceResume: GuidanceSnapshot?

    /// The stage's "up next" chip: today's (or the next) session on the
    /// active plan, one tap from starting. Nil when there's nothing to run.
    private(set) var upNextLabel: String?
    private var upNextPlan: Plan?

    /// Best-effort; offline or planless just means no chip.
    func refreshUpNext() async {
        guard auth.currentUserId != nil else {
            upNextLabel = nil
            upNextPlan = nil
            return
        }
        await plansModel.load()
        guard let active = plansModel.activePlans.first else {
            upNextLabel = nil
            upNextPlan = nil
            return
        }
        await plansModel.loadDetail(id: active.id)
        guard let plan = plansModel.details[active.id],
              let next = PlanScheduling.nextOccurrence(in: plan, now: Date())
        else {
            upNextLabel = nil
            upNextPlan = nil
            return
        }
        upNextPlan = plan
        let label =
            Foundation.Calendar.current.isDateInToday(next.date)
            ? "\(next.session.title) · today"
            : "\(next.session.title) · \(next.date.formatted(.dateTime.weekday(.wide)))"
        withAnimation(.snappy) { upNextLabel = label }
    }

    func startUpNext() {
        guard let plan = upNextPlan else { return }
        Task { await self.startSession(with: plan) }
    }

    /// "Start my workout" — resolve the active plan's next occurrence and
    /// hand it to the runtime. Every failure is spoken; announce's tail
    /// returns the mic to conversation listening.
    func startTodaysSession() async {
        guard guidance.phase == .idle else { return }
        guard await prepareForTurn() else { return }
        await plansModel.load()
        guard let active = plansModel.activePlans.first else {
            await voiceLoop.announce("You don't have an active plan yet. Ask me to build one first.")
            return
        }
        await plansModel.loadDetail(id: active.id)
        guard let plan = plansModel.details[active.id] else {
            await voiceLoop.announce("I couldn't load your plan. Try again in a moment.")
            return
        }
        await startSession(with: plan)
    }

    /// The hub's "Start" button lands here with the full plan in hand.
    func startSession(with plan: Plan) async {
        guard guidance.phase == .idle else { return }
        guard await prepareForTurn() else { return }
        guard let occurrence = PlanScheduling.nextOccurrence(in: plan, now: Date()) else {
            await voiceLoop.announce("There's nothing left to run on that plan.")
            return
        }
        // The one canonical start haptic — every entry point funnels here.
        Haptics.press()
        await guidance.start(
            planId: plan.id,
            domain: plan.meta.domain,
            template: occurrence.session,
            progression: occurrence.entry.progression,
            scheduledDate: occurrence.date
        )
    }

    private func handleGuidanceResumeReply(_ text: String) async {
        guard let snapshot = pendingGuidanceResume else { return }
        pendingGuidanceResume = nil
        let reply = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)
        guard Self.affirmatives.contains(reply) else {
            guidance.clearPendingResume()
            await voiceLoop.announce("Okay — starting fresh next time.")
            return
        }
        guard await prepareForTurn() else { return }
        await plansModel.load()
        await plansModel.loadDetail(id: snapshot.planId)
        guard let plan = plansModel.details[snapshot.planId],
              let template = plan.sessions.first(where: { $0.id == snapshot.sessionId })
        else {
            await voiceLoop.announce("I couldn't load that plan, so I'll leave it be.")
            return
        }
        Haptics.press()
        await guidance.start(
            planId: plan.id,
            domain: plan.meta.domain,
            template: template,
            progression: nil,
            resumeFrom: snapshot
        )
    }

    // MARK: - The morning brief

    /// The structured half of the brief — the resting card after the tour.
    private(set) var briefCard: BriefCard?
    private(set) var briefRunning = false
    /// The chapter currently on stage during the spoken tour, nil outside it.
    private(set) var briefChapter: BriefChapter?
    /// Increments per chapter — gives each slide its own transition identity.
    private(set) var briefChapterIndex = 0
    /// The card data the chapter visuals draw from while the tour plays.
    private(set) var briefTourCard: BriefCard?
    private var briefTourToken = UUID()
    let calendarService: CalendarService

    private static let briefEnabledKey = "otto.brief.enabled"
    private static let briefHourKey = "otto.brief.hour"
    private static let briefMinuteKey = "otto.brief.minute"

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
    /// The guided-session runtime — headless until Step 9's screen renders
    /// it. Guidance utterances route here for on-device classification.
    let guidance: GuidanceRuntime
    /// Created with the model at app start so its notification delegate is
    /// installed before any reminder can fire in the foreground.
    private let reminders = ReminderScheduler()
    /// FCM registration and push-response reporting (automation deliveries).
    private let pushService: PushService
    /// The task screen's state — task events upsert into it live so
    /// voice-added items animate in while the screen is open.
    private let tasksModel: TasksModel
    /// The plans pane's state — plan_ready events upsert into it live.
    private let plansModel: PlansModel
    private var activated = false
    private var ottoTurnOpen = false
    private var eventTask: Task<Void, Never>?
    private var levelTask: Task<Void, Never>?

    init(
        auth: any AuthProvider,
        tasksModel: TasksModel,
        plansModel: PlansModel,
        calendarService: CalendarService = CalendarService()
    ) {
        self.auth = auth
        self.tasksModel = tasksModel
        self.plansModel = plansModel
        self.calendarService = calendarService
        self.pushService = PushService(auth: auth)
        let voiceLoop = VoiceLoop(auth: auth)
        self.voiceLoop = voiceLoop
        self.guidance = GuidanceRuntime(voiceLoop: voiceLoop, auth: auth)
        self.bargeThresholdDb =
            (UserDefaults.standard.object(forKey: Self.bargeThresholdKey) as? Float) ?? -30
        self.sessionId = UserDefaults.standard.string(forKey: Self.sessionKey)
        self.signedIn = auth.currentUserId != nil
        // Wired HERE, not in activate(): a push tap that cold-launches the
        // app reaches the notification delegate before the first frame's
        // .task runs — the handler must already exist or the open report
        // and deep link are silently dropped.
        reminders.onAutomationResponse = { [weak self] push, action in
            guard let self else { return }
            Task { await self.pushService.report(push, action: action) }
            if action == .opened {
                self.handleDeepLink(push.deepLink)
            }
        }
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

        // Tapping a brief notification runs the brief; re-assert the weekday
        // schedule so edits to wake time survive reinstalls.
        reminders.onBriefNotificationTapped = { [weak self] in
            guard let self else { return }
            Task { await self.runBrief() }
        }
        pushService.start()
        // A push tap that launched the app parked its deep link; replay it
        // now that the loop is live.
        if let parked = pendingDeepLink {
            pendingDeepLink = nil
            handleDeepLink(parked)
        }
        refreshCalendarContext()
        if UserDefaults.standard.bool(forKey: Self.briefEnabledKey) {
            let (hour, minute) = storedWakeTime()
            Task { _ = await self.reminders.scheduleBrief(hour: hour, minute: minute) }
        }

        // Killed mid-session? Offer to pick up exactly where they left off.
        // The mic must be LIVE for the answer — the offer opens the
        // conversation, speaks, and listens; the armed capture claims the
        // yes/no before it can become a server turn.
        if let snapshot = guidance.pendingResume() {
            pendingGuidanceResume = snapshot
            Task {
                Haptics.press()
                await self.voiceLoop.armUtteranceCapture()
                await self.voiceLoop.startConversation()
                await self.voiceLoop.announce(snapshot.resumeOfferLine)
            }
        } else {
            maybeGreetOnOpen()
        }

        Task { await self.refreshUpNext() }
    }

    // MARK: - The greeting

    /// The moment the app opens, Otto says hello — once per genuine
    /// arrival, never on every backgrounding bounce, and never over a
    /// resume offer or a push-tapped brief.
    static let lastGreetingKey = "otto.greeting.lastAt"
    /// Re-greet only after this long away.
    nonisolated static let greetingGap: TimeInterval = 4 * 60 * 60

    /// "Good morning." / "Good afternoon." / "Good evening." — local time.
    nonisolated static func greeting(for date: Date, calendar: Calendar = .current) -> String {
        let hour = calendar.component(.hour, from: date)
        switch hour {
        case 5..<12: return "Good morning."
        case 12..<18: return "Good afternoon."
        default: return "Good evening."
        }
    }

    private func maybeGreetOnOpen() {
        guard signedIn, pendingDeepLink == nil else { return }
        let defaults = UserDefaults.standard
        let last = defaults.object(forKey: Self.lastGreetingKey) as? Date
        if let last, Date().timeIntervalSince(last) < Self.greetingGap {
            return
        }
        defaults.set(Date(), forKey: Self.lastGreetingKey)
        let line = Self.greeting(for: Date())
        Task {
            await self.voiceLoop.announce(line)
        }
    }

    func storedWakeTime() -> (hour: Int, minute: Int) {
        let defaults = UserDefaults.standard
        let hour = defaults.object(forKey: Self.briefHourKey) as? Int ?? 7
        let minute = defaults.object(forKey: Self.briefMinuteKey) as? Int ?? 30
        return (hour, minute)
    }

    /// The settings surface calls this; scheduling requests notification
    /// permission in context on enable.
    func setBriefSchedule(enabled: Bool, hour: Int, minute: Int) {
        let defaults = UserDefaults.standard
        defaults.set(enabled, forKey: Self.briefEnabledKey)
        defaults.set(hour, forKey: Self.briefHourKey)
        defaults.set(minute, forKey: Self.briefMinuteKey)
        Task {
            if enabled {
                let scheduled = await self.reminders.scheduleBrief(hour: hour, minute: minute)
                if !scheduled {
                    self.appendNotice(
                        "Notifications are off, so the scheduled brief can't ring. Enable them for Otto in Settings."
                    )
                }
            } else {
                await self.reminders.cancelBrief()
            }
        }
    }

    var briefScheduleEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.briefEnabledKey)
    }

    /// Re-reads auth state — called on appear and whenever the settings
    /// sheet closes (sign in/out happens in there).
    func refreshAccount() {
        signedIn = auth.currentUserId != nil
        // A fresh sign-in is the moment the token upload can finally land.
        Task { await pushService.uploadTokenIfNeeded() }
    }

    /// Where an automation push's tap lands. The brief plays; everything
    /// else just opens the app, which is already the right screen.
    func handleDeepLink(_ deepLink: String) {
        // A cold-launch tap can land before activate(): park the link and
        // let activation replay it once the voice loop is actually up.
        guard activated else {
            pendingDeepLink = deepLink
            return
        }
        if deepLink == "otto://brief" {
            Task { await runBrief() }
        }
    }

    private var pendingDeepLink: String?

    // MARK: - Intents

    /// Mic button: idle starts the voice conversation; any other state stops
    /// everything (including speech from a typed turn).
    func toggleVoice() {
        if state == .idle {
            // The stop glyph shows through the whole brief tour, and the
            // state dips to idle between chapters — a tap in that instant
            // means "stop the brief", never "start talking".
            if briefTourCard != nil {
                cancelBriefTour()
                return
            }
            Task {
                guard await self.prepareForTurn() else { return }
                await self.voiceLoop.startConversation()
            }
        } else {
            cancelBriefTour()
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

    /// The hub's "Adapt this plan" entry: adaptation is conversational, so
    /// just open the mic — ACTIVE PLANS context and the adapt_plan tool do
    /// the rest when the user says what changed.
    func beginPlanAdaptation() {
        guard state == .idle else { return }
        toggleVoice()
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
        cancelBriefTour()
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
                refreshCalendarContext()
            }
            if newState == .listening || newState == .idle {
                // A barge-in or stop cancels the turn stream; a generation
                // still in flight will never deliver, so clear its progress.
                planPhase = .idle
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
            if guidance.answeringQuestion {
                // An off-script answer just finished — return to the step.
                Task { await self.guidance.answerFinished() }
            } else if pendingDraft != nil {
                // Start the read-back flow only after Otto's own words finish.
                Task { await self.beginDraftFlow() }
            } else if pendingCalendarProposal != nil {
                Task { await self.beginCalendarFlow() }
            } else if pendingPlanOffer != nil {
                Task { await self.beginPlanScheduleFlow() }
            }
        case .draft(let recipientName, let body):
            Haptics.tap()
            pendingDraft = (recipientName, body)
        case .calendarProposal(let proposal):
            Haptics.tap()
            pendingCalendarProposal = proposal
        case .capturedUtterance(let text):
            Task { await self.handleCapturedReply(text) }
        case .briefRequested:
            Task { await self.runBrief() }
        case .guidanceUtterance(let text):
            Task { await self.guidance.handleUtterance(text) }
        case .guidanceStartRequested:
            Task { await self.startTodaysSession() }
        case .planProgress(let stage):
            withAnimation(.snappy) {
                planPhase = stage == .designing ? .designing : .scheduling
            }
        case .planReady(let plan):
            planPhase = .idle
            Haptics.success()
            withAnimation(.snappy) { planCard = plan }
            plansModel.apply(plan)
            // Offer calendar scheduling for NEW plans only — an adapted
            // version may already be scheduled (its links carried over).
            if plan.meta.version == 1 {
                pendingPlanOffer = plan
            }
            Task { await self.refreshUpNext() }
        case .planFailed:
            planPhase = .idle
        case .task(let task):
            Haptics.tap()
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

    /// Routes a captured utterance to whichever confirmation flow is live.
    private func handleCapturedReply(_ text: String) async {
        if draftStage != .idle {
            await handleDraftReply(text)
        } else if calendarStage != .idle {
            await handleCalendarReply(text)
        } else if planScheduleStage != .idle {
            await handlePlanScheduleReply(text)
        } else if pendingGuidanceResume != nil {
            await handleGuidanceResumeReply(text)
        }
    }

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

    // MARK: - Calendar flow (propose → confirm → write → READ BACK)

    private static func speakable(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().hour().minute())
    }

    private func beginCalendarFlow() async {
        guard let proposal = pendingCalendarProposal else { return }
        pendingCalendarProposal = nil

        switch proposal {
        case .create(let draft):
            calendarStage = .confirming(.create(draft))
            await voiceLoop.armUtteranceCapture()
            await voiceLoop.announce(
                "Add \(draft.title), \(Self.speakable(draft.startsAt)). Confirm?"
            )
        case .move(let eventTitle, let newStartsAt, let newEndsAt):
            // Resolve the named event on-device, soonest match first.
            let searchStart = Date().addingTimeInterval(-3600)
            let searchEnd = Date().addingTimeInterval(45 * 86_400)
            let events: [CalendarEvent]
            do {
                events = try await calendarService.events(from: searchStart, to: searchEnd)
            } catch {
                appendNotice(error.localizedDescription)
                await voiceLoop.announce("I can't reach the calendar to find it.")
                return
            }
            guard let original = CalendarService.matchEvent(events, title: eventTitle) else {
                await voiceLoop.announce("I don't see \(eventTitle) on the calendar.")
                return
            }
            let duration = original.endsAt.timeIntervalSince(original.startsAt)
            let newEnd = newEndsAt ?? newStartsAt.addingTimeInterval(max(60, duration))
            calendarStage = .confirming(.move(original: original, newStart: newStartsAt, newEnd: newEnd))
            await voiceLoop.armUtteranceCapture()
            await voiceLoop.announce(
                "Move \(original.title) from \(Self.speakable(original.startsAt)) " +
                    "to \(Self.speakable(newStartsAt)). Confirm?"
            )
        }
    }

    private func handleCalendarReply(_ text: String) async {
        let reply = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)
        guard case .confirming(let change) = calendarStage else { return }
        if Self.affirmatives.contains(reply) {
            calendarStage = .idle
            await performCalendarWrite(change)
        } else if Self.negatives.contains(reply) {
            calendarStage = .idle
            await voiceLoop.announce("Cancelled. The calendar is untouched.")
        } else {
            calendarStage = .idle
            await voiceLoop.announce("That wasn't a yes, so I left the calendar alone.")
        }
    }

    /// Tapped confirmation on the calendar card.
    func confirmCalendarTapped() {
        if case .confirming(let change) = calendarStage {
            calendarStage = .idle
            Task { await self.performCalendarWrite(change) }
        }
    }

    func cancelCalendarTapped() {
        calendarStage = .idle
        Task { await self.voiceLoop.disarmUtteranceCapture() }
        appendNotice("Calendar change discarded.")
    }

    /// The write, then the READ-BACK. Success is only ever reported from
    /// what the calendar actually returns; an unverified write is a failure.
    private func performCalendarWrite(_ change: ProposedCalendarChange) async {
        switch change {
        case .create(let draft):
            do {
                let id = try await calendarService.createEvent(draft)
                if let readBack = try await calendarService.event(withId: id) {
                    await voiceLoop.announce(
                        "Done. \(readBack.title) is on the calendar, \(Self.speakable(readBack.startsAt))."
                    )
                } else {
                    await voiceLoop.announce("The write didn't take. Check the calendar.")
                }
            } catch {
                await voiceLoop.announce("The calendar write failed. \(error.localizedDescription)")
            }
        case .move(let original, let newStart, let newEnd):
            do {
                try await calendarService.moveEvent(id: original.id, newStart: newStart, newEnd: newEnd)
                if let readBack = try await calendarService.event(withId: original.id),
                   abs(readBack.startsAt.timeIntervalSince(newStart)) < 60 {
                    await voiceLoop.announce(
                        "Done. \(readBack.title) is now \(Self.speakable(readBack.startsAt))."
                    )
                } else {
                    await voiceLoop.announce("The move didn't take. Check the calendar.")
                }
            } catch {
                await voiceLoop.announce("The move failed. \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Plan scheduling flow (offer → confirm → write → READ BACK)

    private func beginPlanScheduleFlow() async {
        guard let plan = pendingPlanOffer else { return }
        pendingPlanOffer = nil
        let drafts = PlanScheduling.drafts(for: plan, now: Date())
        guard !drafts.isEmpty else { return }
        planToSchedule = plan
        planScheduleDrafts = drafts
        withAnimation(.snappy) { planScheduleStage = .offering }
        await voiceLoop.armUtteranceCapture()
        await voiceLoop.announce(
            "Want these on your calendar? \(drafts.count) sessions over the plan."
        )
    }

    private func handlePlanScheduleReply(_ text: String) async {
        let reply = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)
        guard planScheduleStage == .offering else { return }
        if Self.affirmatives.contains(reply) {
            let plan = planToSchedule
            let drafts = planScheduleDrafts
            resetPlanScheduleFlow()
            if let plan {
                await performPlanScheduling(plan: plan, drafts: drafts)
            }
        } else {
            // Anything that isn't a yes leaves the calendar alone.
            resetPlanScheduleFlow()
            await voiceLoop.announce("Okay — calendar untouched.")
        }
    }

    /// Tapped confirmation on the scheduling card.
    func confirmPlanScheduleTapped() {
        guard planScheduleStage == .offering, let plan = planToSchedule else { return }
        let drafts = planScheduleDrafts
        resetPlanScheduleFlow()
        Task { await self.performPlanScheduling(plan: plan, drafts: drafts) }
    }

    func cancelPlanScheduleTapped() {
        resetPlanScheduleFlow()
        appendNotice("Sessions not added to the calendar.")
    }

    /// Writes every draft via EventKit, VERIFIES each by reading it back,
    /// speaks only from read-back values, then reports the verified ids to
    /// the server so they live on the plan.
    private func performPlanScheduling(plan: Plan, drafts: [PlanScheduling.SessionEvent]) async {
        var verified: [PlanCalendarEvent] = []
        var firstReadBack: CalendarEvent?
        var failures = 0

        for item in drafts {
            do {
                let id = try await calendarService.createEvent(item.draft)
                if let readBack = try await calendarService.event(withId: id),
                   abs(readBack.startsAt.timeIntervalSince(item.draft.startsAt)) < 60 {
                    verified.append(
                        PlanCalendarEvent(
                            sessionId: item.sessionId,
                            dayOffset: item.dayOffset,
                            eventId: id
                        )
                    )
                    if firstReadBack == nil { firstReadBack = readBack }
                } else {
                    failures += 1
                }
            } catch {
                // Denied permission fails the first write; don't hammer the
                // remaining drafts against the same wall.
                if verified.isEmpty {
                    appendNotice(error.localizedDescription)
                    await voiceLoop.announce("I can't reach the calendar, so nothing was added.")
                    return
                }
                failures += 1
            }
        }

        if let first = firstReadBack, failures == 0 {
            await voiceLoop.announce(
                "Done. \(verified.count) sessions on the calendar. " +
                    "First one \(Self.speakable(first.startsAt))."
            )
        } else if firstReadBack != nil {
            await voiceLoop.announce(
                "\(verified.count) of \(drafts.count) sessions made it. Check the calendar."
            )
        } else {
            await voiceLoop.announce("The writes didn't take. The calendar is unchanged.")
            return
        }

        guard let client = makeClient() else { return }
        do {
            try await client.storePlanCalendarEvents(planId: plan.id, events: verified)
        } catch {
            appendNotice("Couldn't record the calendar links: \(error.localizedDescription)")
        }
    }

    private func resetPlanScheduleFlow() {
        withAnimation(.snappy) { planScheduleStage = .idle }
        planScheduleDrafts = []
        planToSchedule = nil
        Task { await self.voiceLoop.disarmUtteranceCapture() }
    }

    // MARK: - Brief flow

    /// Gather the on-device calendar (permission in context), detect
    /// conflicts in Swift, POST /brief, render the card, speak the brief.
    func runBrief() async {
        guard !briefRunning else { return }
        guard await prepareForTurn() else { return }
        briefRunning = true
        defer { briefRunning = false }

        let dayStart = Foundation.Calendar.current.startOfDay(for: Date())
        let dayEnd =
            Foundation.Calendar.current.date(byAdding: .day, value: 1, to: dayStart)
            ?? dayStart.addingTimeInterval(86_400)

        var events: [CalendarEvent] = []
        do {
            events = try await calendarService.events(from: dayStart, to: dayEnd)
        } catch {
            // Denied or unavailable: the brief still runs without calendar.
            appendNotice(error.localizedDescription)
        }
        let conflicts = CalendarService.conflicts(in: events)

        guard let client = makeClient() else { return }
        do {
            let response = try await client.morningBrief(
                BriefRequest(
                    events: events,
                    conflicts: conflicts,
                    timezone: TimeZone.current.identifier
                )
            )
            if let chapters = response.chapters, !chapters.isEmpty {
                await playBriefTour(chapters: chapters, card: response.card)
            } else {
                // Older server shape: the full card up for the whole read.
                withAnimation(.snappy) { briefCard = response.card }
                await voiceLoop.announce(response.spoken)
            }
        } catch {
            appendNotice("Brief failed: \(error.localizedDescription)")
            await voiceLoop.announce("I couldn't put the brief together. Try again in a minute.")
        }
    }

    /// The synced tour: each chapter's visual slides in, its sentences play,
    /// the next slides over it. A mic tap or typed turn cancels between
    /// chapters; the full-day card is what rests on stage at the end.
    private func playBriefTour(chapters: [BriefChapter], card: BriefCard) async {
        let token = UUID()
        briefTourToken = token
        briefTourCard = card
        for (index, chapter) in chapters.enumerated() {
            guard briefTourToken == token else { return }
            withAnimation(.spring(duration: 0.55, bounce: 0.18)) {
                briefChapter = chapter
                briefChapterIndex = index
            }
            Haptics.tick()
            await voiceLoop.announce(chapter.spoken)
        }
        guard briefTourToken == token else { return }
        withAnimation(.spring(duration: 0.5, bounce: 0.12)) {
            briefChapter = nil
            briefTourCard = nil
            briefCard = card
        }
    }

    /// Any new turn or stop tears the tour down — the next chapter's
    /// announce would fight whatever the user just started.
    private func cancelBriefTour() {
        briefTourToken = UUID()
        guard briefChapter != nil || briefTourCard != nil else { return }
        withAnimation(.snappy) {
            briefChapter = nil
            briefTourCard = nil
        }
    }

    func dismissBrief() {
        cancelBriefTour()
        withAnimation(.snappy) { briefCard = nil }
    }

    func dismissPlan() {
        withAnimation(.snappy) { planCard = nil }
    }

    /// Pushes today+tomorrow's events into the loop for ambient context.
    /// Silent by design: reads only when permission already exists, so this
    /// can run every turn without ever prompting.
    private func refreshCalendarContext() {
        Task {
            let dayStart = Foundation.Calendar.current.startOfDay(for: Date())
            let end =
                Foundation.Calendar.current.date(byAdding: .day, value: 2, to: dayStart)
                ?? dayStart.addingTimeInterval(2 * 86_400)
            let events = await self.calendarService.eventsIfAuthorized(from: dayStart, to: end)
            await self.voiceLoop.setCalendarContext(events)
        }
    }

    private func makeClient() -> APIClient? {
        let urlString =
            UserDefaults.standard.string(forKey: DebugModel.serverURLKey) ?? "http://localhost:8080"
        guard let url = URL(string: urlString), url.scheme != nil else { return nil }
        return APIClient(baseURL: url, auth: auth)
    }

    private var lastLevelPublish: TimeInterval = 0

    private func handleLevel(_ db: Float) {
        lastLevelDb = db
        // Levels arrive ~50×/second; publishing each one re-renders the
        // whole stage that often. ~24fps is indistinguishable to the eye
        // and cuts the SwiftUI invalidation load by half or more — and an
        // idle stage with no overlay needs no bars at all.
        guard state != .idle || overlayVisible else { return }
        let now = Date.timeIntervalSinceReferenceDate
        guard now - lastLevelPublish >= 0.042 else { return }
        lastLevelPublish = now
        // Speech at arm's length spans roughly -58dB (quiet) to -20dB (loud).
        let normalized = max(0, min(1, (db + 58) / 38))
        micBars.removeFirst()
        micBars.append(normalized)
    }

    private func refreshSnapshot() {
        Task { self.debugSnapshot = await self.voiceLoop.debugSnapshot() }
    }
}
