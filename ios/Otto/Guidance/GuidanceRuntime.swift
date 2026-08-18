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
    /// The finished session's truth — Step 8 writes the SessionRecord from
    /// this.
    private(set) var lastSnapshot: GuidanceSnapshot?

    var isActive: Bool { conductor != nil }

    // MARK: - Plumbing

    private let voiceLoop: VoiceLoop
    private let store = GuidanceStore()
    private let backstop = GuidanceBackstop()
    private var conductor: GuidanceConductor?
    private var eventsTask: Task<Void, Never>?

    init(voiceLoop: VoiceLoop) {
        self.voiceLoop = voiceLoop
    }

    /// A fresh in-progress snapshot from a killed app, if one exists — the
    /// caller offers "Pick up where you left off?" and passes it to start.
    func pendingResume() -> GuidanceSnapshot? {
        store.pendingResume()
    }

    // MARK: - Lifecycle

    /// Starts (or resumes) a session: audio held open, screen kept awake,
    /// mic hot, conductor running. One session at a time.
    func start(
        planId: String,
        template: Session,
        progression: Progression?,
        resumeFrom: GuidanceSnapshot? = nil
    ) async {
        guard conductor == nil else { return }
        let conductor = GuidanceConductor(
            planId: planId,
            template: template,
            progression: progression,
            store: store,
            resumeFrom: resumeFrom,
            backstop: backstop,
            speak: { [voiceLoop] text in await voiceLoop.announce(text) },
            play: { [voiceLoop] clip in await voiceLoop.playClip(clip) }
        )
        self.conductor = conductor
        phase = .running
        sessionTitle = template.title
        totalSteps = template.steps.count
        stepIndex = resumeFrom?.currentStepIndex ?? 0
        currentStep = nil
        resting = false
        isPaused = false

        let events = await conductor.events()
        eventsTask = Task {
            for await event in events {
                self.apply(event)
            }
        }

        GuidanceScreenLock.keepAwake(true)
        await voiceLoop.setGuidanceHold(true)
        await voiceLoop.startGuidanceListening()
        await conductor.start()
    }

    /// Every guidance utterance lands here. Commands classify ON DEVICE and
    /// act instantly; anything else is off-script (Step 6 escalates it with
    /// the current step as context — for now it stays unanswered, which is
    /// silence, which is correct).
    func handleUtterance(_ text: String) async {
        guard let conductor else { return }
        if let command = GuidanceCommandClassifier.classify(text) {
            await conductor.handle(command)
        }
    }

    /// The UI's tap alternative to voice — the "Done" button is `.next`.
    func tap(_ command: VoiceCommand) {
        guard let conductor else { return }
        Task { await conductor.handle(command) }
    }

    // MARK: - Event application

    private func apply(_ event: GuidanceEvent) {
        switch event {
        case .began(let title, _):
            sessionTitle = title
        case .stepChanged(let index, let total, let step):
            withAnimation(.snappy) {
                stepIndex = index
                totalSteps = total
                currentStep = step
                resting = false
            }
        case .resting:
            withAnimation(.snappy) { resting = true }
        case .paused(let paused):
            isPaused = paused
        case .finished(let early, let snapshot):
            lastSnapshot = snapshot
            Task { await self.teardown(early: early) }
        }
    }

    private func teardown(early: Bool) async {
        eventsTask?.cancel()
        eventsTask = nil
        conductor = nil
        currentStep = nil
        resting = false
        isPaused = false
        phase = .finished(early: early)
        GuidanceScreenLock.keepAwake(false)
        await voiceLoop.stopGuidanceListening()
        await voiceLoop.setGuidanceHold(false)
        // Step 8: write the SessionRecord from lastSnapshot here.
    }

    /// The finished screen was dismissed; back to nothing.
    func reset() {
        if case .finished = phase {
            phase = .idle
            lastSnapshot = nil
        }
    }
}
