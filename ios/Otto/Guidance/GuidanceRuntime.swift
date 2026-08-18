import Foundation
import Observation
import SwiftUI

/// Owns a running guided session on behalf of the app: the conductor, the
/// audio hold, the mic, the screen wake, and the on-device command routing.
/// Step 9's screen renders this model; until then it is the complete,
/// headless runtime.
@MainActor
@Observable
final class GuidanceRuntime {

    enum Phase: Equatable {
        case idle
        case running
        case finished(early: Bool)
    }

    // MARK: - Published state (Step 9 renders these)

    private(set) var phase: Phase = .idle
    private(set) var sessionTitle = ""
    private(set) var currentStep: Step?
    private(set) var stepIndex = 0
    private(set) var totalSteps = 0
    private(set) var resting = false
    private(set) var isPaused = false
    /// An off-script answer is in flight; the session is suspended under it.
    private(set) var answeringQuestion = false
    /// The running countdown for the ring, polled ~2×/second while active.
    private(set) var timer: GuidanceTimerSnapshot?
    /// "Set 2 of 3, 8 reps." / "Rest" — the position line as text.
    private(set) var statusText: String?
    /// Previewed small at the bottom, low contrast.
    private(set) var nextStepTitle: String?
    /// The finished session's truth — Step 8 writes the SessionRecord from
    /// this.
    private(set) var lastSnapshot: GuidanceSnapshot?

    var isActive: Bool { conductor != nil }

    // MARK: - Plumbing

    private let voiceLoop: VoiceLoop
    private let auth: any AuthProvider
    private let store = GuidanceStore()
    private let backstop = GuidanceBackstop()
    /// HealthKit is additive, never required — a denial changes nothing
    /// about the session except that no workout is saved.
    private let health = HealthService()
    /// Store-and-forward for session records — an offline session (basement
    /// gym, airplane mode) loses nothing; the record lands next time.
    private let outbox = RecordOutbox()
    private var conductor: GuidanceConductor?
    private var eventsTask: Task<Void, Never>?
    private var displayTask: Task<Void, Never>?
    private var workoutTracking = false
    private var activePlanId: String?
    private var activeScheduledDate: Date?
    private var activeTemplate: Session?

    init(voiceLoop: VoiceLoop, auth: any AuthProvider) {
        self.voiceLoop = voiceLoop
        self.auth = auth
    }

    /// A fresh in-progress snapshot from a killed app, if one exists — the
    /// caller offers "Pick up where you left off?" and passes it to start.
    func pendingResume() -> GuidanceSnapshot? {
        store.pendingResume()
    }

    /// The user declined the resume offer — never offer that session again.
    func clearPendingResume() {
        store.clear()
    }

    // MARK: - Lifecycle

    /// Starts (or resumes) a session: audio held open, screen kept awake,
    /// mic hot, conductor running. One session at a time. Fitness sessions
    /// also open a Health workout — authorization requested here, in
    /// context, the first time one starts; never at launch.
    func start(
        planId: String,
        domain: String,
        template: Session,
        progression: Progression?,
        scheduledDate: Date? = nil,
        resumeFrom: GuidanceSnapshot? = nil
    ) async {
        guard conductor == nil else { return }
        activePlanId = planId
        activeScheduledDate = scheduledDate
        activeTemplate = template
        // The screen appears IMMEDIATELY — the network work below (outbox
        // flush, reference weights) happens under it, never in front of it.
        phase = .running
        sessionTitle = template.title
        totalSteps = template.steps.count
        stepIndex = resumeFrom?.currentStepIndex ?? 0
        currentStep = nil
        resting = false
        isPaused = false
        if domain == "fitness", HealthService.isAvailable {
            if await health.requestAuthorization() {
                await health.beginWorkout(at: Date())
                workoutTracking = true
            }
        }
        // Anything still queued from an offline session goes first; then
        // last session's logged values become this session's reference
        // weights ("Last time: 135 pounds."). Both best-effort — offline
        // just means no references today.
        await flushOutbox()
        var references: [String: String] = [:]
        if let client = makeClient(),
           let summary = try? await client.planSummary(planId: planId) {
            references = summary.latestLoggedValues
        }
        let conductor = GuidanceConductor(
            planId: planId,
            template: template,
            progression: progression,
            store: store,
            resumeFrom: resumeFrom,
            backstop: backstop,
            references: references,
            speak: { [voiceLoop] text in await voiceLoop.announce(text) },
            play: { [voiceLoop] clip in await voiceLoop.playClip(clip) }
        )
        self.conductor = conductor

        let events = await conductor.events()
        eventsTask = Task {
            for await event in events {
                self.apply(event)
            }
        }
        // The ring: poll the running countdown twice a second while active.
        displayTask = Task {
            var wasInFinalTen = false
            while !Task.isCancelled {
                if let current = self.conductor {
                    let display = await current.displayState()
                    self.timer = display.timer
                    if display.status != nil {
                        self.statusText = display.status
                    }
                    // A soft pulse as the clock crosses ten — the haptic
                    // twin of the "Ten seconds" clip.
                    let inFinalTen =
                        display.timer.map { $0.remaining <= 10 && !$0.isPaused } ?? false
                    if inFinalTen && !wasInFinalTen {
                        Haptics.warning()
                    }
                    wasInFinalTen = inFinalTen
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }

        GuidanceScreenLock.keepAwake(true)
        await voiceLoop.setGuidanceHold(true)
        await voiceLoop.startGuidanceListening()
        await conductor.start()
    }

    /// Every guidance utterance lands here. Commands classify ON DEVICE and
    /// act instantly. Question-shaped leftovers go off-script: suspend the
    /// session, ask the server with the step as context, resume on the
    /// answer's end. Plain chatter is dropped — silence is correct.
    func handleUtterance(_ text: String) async {
        guard let conductor else { return }
        guard !answeringQuestion else { return }
        if let command = GuidanceCommandClassifier.classify(text) {
            await conductor.handle(command)
            return
        }
        guard GuidanceCommandClassifier.looksLikeQuestion(text) else { return }
        await beginOffScript(question: text, conductor: conductor)
    }

    /// PAUSE the session state — do not lose position — then a normal
    /// server turn carrying the current step. "One sec." tells them they
    /// were heard before the round trip.
    private func beginOffScript(question: String, conductor: GuidanceConductor) async {
        guard let step = currentStep else { return }
        answeringQuestion = true
        await voiceLoop.playClip(.oneSec)
        let position = await conductor.suspendForQuestion()
        let context = GuidanceTurnContext(
            sessionTitle: sessionTitle,
            stepTitle: step.title,
            stepCue: step.cue,
            position: position
        )
        await voiceLoop.askDuringGuidance(question, context: context)
    }

    /// The answer finished speaking (ConversationModel forwards .ottoDone
    /// while a question is live): back to the step, clock intact.
    func answerFinished() async {
        guard answeringQuestion else { return }
        answeringQuestion = false
        await conductor?.resumeFromQuestion()
    }

    /// The UI's tap alternative to voice — the "Done" button is `.next`.
    /// Debounced: a double-tap on Done must complete ONE set, not two.
    func tap(_ command: VoiceCommand) {
        guard let conductor else { return }
        let now = Date()
        if let last = lastTap, last.command == command,
           now.timeIntervalSince(last.at) < 0.35 {
            return
        }
        lastTap = (command, now)
        Task { await conductor.handle(command) }
    }

    private var lastTap: (command: VoiceCommand, at: Date)?

    // MARK: - Event application

    private func apply(_ event: GuidanceEvent) {
        switch event {
        case .began(let title, _):
            sessionTitle = title
        case .stepChanged(let index, let total, let step):
            if index > 0 {
                Haptics.step()
            }
            withAnimation(.snappy) {
                stepIndex = index
                totalSteps = total
                currentStep = step
                resting = false
                timer = nil
                statusText = nil
                nextStepTitle = activeTemplate.flatMap { template in
                    index + 1 < template.steps.count ? template.steps[index + 1].title : nil
                }
            }
        case .resting:
            Haptics.tap()
            withAnimation(.snappy) { resting = true }
        case .paused(let paused):
            isPaused = paused
            if paused {
                Haptics.caution()
            } else {
                Haptics.tap()
            }
        case .finished(let early, let snapshot):
            lastSnapshot = snapshot
            Haptics.success()
            Task { await self.teardown(early: early) }
        }
    }

    private func teardown(early: Bool) async {
        eventsTask?.cancel()
        eventsTask = nil
        displayTask?.cancel()
        displayTask = nil
        conductor = nil
        currentStep = nil
        resting = false
        isPaused = false
        answeringQuestion = false
        timer = nil
        statusText = nil
        nextStepTitle = nil
        activeTemplate = nil
        phase = .finished(early: early)
        GuidanceScreenLock.keepAwake(false)
        await voiceLoop.stopGuidanceListening()
        await voiceLoop.setGuidanceHold(false)
        if workoutTracking {
            // Ending early still finishes the workout honestly — the
            // service itself discards anything under five minutes.
            workoutTracking = false
            await health.finishWorkout(at: Date())
        }
        // The SessionRecord: disk first, then the server — a record must
        // survive airplane mode and a force-quit alike.
        if let snapshot = lastSnapshot, let planId = activePlanId {
            let completedAt = Date()
            let upload = SessionRecordUpload(
                sessionId: snapshot.sessionId,
                scheduledDate: activeScheduledDate,
                startedAt: snapshot.startedAt,
                completedAt: completedAt,
                completedSteps: snapshot.completedSteps,
                skippedSteps: snapshot.skippedSteps,
                loggedValues: snapshot.loggedValues,
                durationSec: Int(max(0, completedAt.timeIntervalSince(snapshot.startedAt))),
                endedEarly: early
            )
            await outbox.append(PendingRecord(planId: planId, upload: upload))
            await flushOutbox()
        }
        activePlanId = nil
        activeScheduledDate = nil
    }

    private func flushOutbox() async {
        guard let client = makeClient() else { return }
        await outbox.flush { pending in
            (try? await client.storeSessionRecord(
                planId: pending.planId,
                upload: pending.upload
            )) != nil
        }
    }

    private func makeClient() -> APIClient? {
        let urlString =
            UserDefaults.standard.string(forKey: DebugModel.serverURLKey) ?? "http://localhost:8080"
        guard let url = URL(string: urlString), url.scheme != nil else { return nil }
        guard auth.currentUserId != nil else { return nil }
        return APIClient(baseURL: url, auth: auth)
    }

    /// The finished screen was dismissed; back to nothing.
    func reset() {
        if case .finished = phase {
            phase = .idle
            lastSnapshot = nil
        }
    }
}
