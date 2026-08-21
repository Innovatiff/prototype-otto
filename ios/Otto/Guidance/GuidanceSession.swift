import Foundation

/// The guided-session state machine. THE CORE PRINCIPLE: no LLM calls on
/// the happy path — the plan is complete and self-contained, and this actor
/// executes it deterministically, offline, for free.
///
///   notStarted → announcing → stepActive → stepCompleting
///                                  ↑              ├→ stepActive
///                                  │              ├→ resting ─┐
///                                  └──────────────┴───────────┘
///                                                 └→ finished
///
/// Pause is orthogonal (pausedAt on the snapshot), not a node: a paused
/// timer is still "in" its state. Every transition persists the snapshot;
/// a killed app resumes from disk. Step executors DRIVE this machine —
/// they never own state.
actor GuidanceSession {

    enum State: String, Sendable, Equatable {
        case notStarted
        case announcing
        case stepActive
        case stepCompleting
        case resting
        case finished
    }

    private(set) var state: State = .notStarted
    private let session: Session
    private let store: GuidanceStore
    private var snapshot: GuidanceSnapshot

    /// Fresh session, or a resumed one when `resumeFrom` carries a snapshot
    /// for this same plan session — a mismatched snapshot is ignored.
    init(
        planId: String,
        session: Session,
        store: GuidanceStore,
        resumeFrom: GuidanceSnapshot? = nil
    ) {
        self.session = session
        self.store = store
        if let resumeFrom,
           resumeFrom.planId == planId,
           resumeFrom.sessionId == session.id {
            self.snapshot = resumeFrom
            self.snapshot.pausedAt = nil
        } else {
            self.snapshot = GuidanceSnapshot(
                planId: planId,
                sessionId: session.id,
                sessionTitle: session.title,
                totalSteps: session.steps.count,
                currentStepIndex: 0,
                startedAt: Date(),
                updatedAt: Date(),
                completedSteps: [],
                skippedSteps: [],
                loggedValues: [:],
                pausedAt: nil,
                // Walkthroughs have no plan to reload — the snapshot IS the
                // session, so a killed app can still offer the resume.
                template: WalkthroughRun.isWalkthrough(planId) ? session : nil
            )
        }
    }

    // MARK: - Reads

    var currentStep: Step? {
        let index = snapshot.currentStepIndex
        guard index >= 0, index < session.steps.count else { return nil }
        return session.steps[index]
    }

    var currentStepIndex: Int { snapshot.currentStepIndex }
    var isPaused: Bool { snapshot.pausedAt != nil }
    /// The persisted truth — Step 8's SessionRecord is written from this.
    var currentSnapshot: GuidanceSnapshot { snapshot }

    var progress: (index: Int, total: Int) {
        (snapshot.currentStepIndex, session.steps.count)
    }

    // MARK: - Transitions (each validates, mutates, persists)

    /// notStarted → announcing. False anywhere else. A resumed session
    /// keeps its original startedAt — only the heartbeat refreshes.
    @discardableResult
    func start() -> Bool {
        guard state == .notStarted else { return false }
        state = .announcing
        persist()
        return true
    }

    /// announcing → stepActive at the current index — or straight to
    /// finished when a resumed snapshot had already passed the last step.
    @discardableResult
    func announcementFinished() -> Bool {
        guard state == .announcing else { return false }
        if snapshot.currentStepIndex >= session.steps.count {
            finish()
        } else {
            state = .stepActive
            persist()
        }
        return true
    }

    /// stepActive → stepCompleting: the step's completion signal fired
    /// (voice "done", timer at zero, checklist finished).
    @discardableResult
    func beginCompleting() -> Bool {
        guard state == .stepActive else { return false }
        state = .stepCompleting
        persist()
        return true
    }

    /// stepCompleting → resting | stepActive | finished. Marks the current
    /// step completed and moves the index forward — so a kill during the
    /// rest resumes on the NEXT step, which is where the user actually is.
    @discardableResult
    func advance(throughRest: Bool) -> Bool {
        guard state == .stepCompleting, let step = currentStep else { return false }
        if !snapshot.completedSteps.contains(step.id) {
            snapshot.completedSteps.append(step.id)
        }
        snapshot.currentStepIndex += 1
        if snapshot.currentStepIndex >= session.steps.count {
            finish()
        } else {
            state = throughRest ? .resting : .stepActive
            persist()
        }
        return true
    }

    /// resting → stepActive: the rest timer completed.
    @discardableResult
    func restFinished() -> Bool {
        guard state == .resting else { return false }
        state = .stepActive
        persist()
        return true
    }

    /// stepActive → next step (or finished), current step marked skipped.
    /// Skips take no rest — the user is bailing, not recovering.
    @discardableResult
    func skip() -> Bool {
        guard state == .stepActive, let step = currentStep else { return false }
        if !snapshot.skippedSteps.contains(step.id) {
            snapshot.skippedSteps.append(step.id)
        }
        snapshot.currentStepIndex += 1
        if snapshot.currentStepIndex >= session.steps.count {
            finish()
        } else {
            state = .stepActive
            persist()
        }
        return true
    }

    /// stepActive | resting → the previous step, un-marking it so redoing
    /// it counts it once. False on the first step.
    @discardableResult
    func back() -> Bool {
        guard state == .stepActive || state == .resting else { return false }
        guard snapshot.currentStepIndex > 0 else { return false }
        snapshot.currentStepIndex -= 1
        if let step = currentStep {
            snapshot.completedSteps.removeAll { $0 == step.id }
            snapshot.skippedSteps.removeAll { $0 == step.id }
        }
        state = .stepActive
        persist()
        return true
    }

    /// Orthogonal pause: valid in any live state, recorded on the snapshot
    /// so timers (Step 2) know to freeze and resume knows it was deliberate.
    @discardableResult
    func pause() -> Bool {
        guard state != .notStarted, state != .finished, snapshot.pausedAt == nil else {
            return false
        }
        snapshot.pausedAt = Date()
        persist()
        return true
    }

    @discardableResult
    func resume() -> Bool {
        guard snapshot.pausedAt != nil else { return false }
        snapshot.pausedAt = nil
        persist()
        return true
    }

    /// "used 135 pounds" — recorded verbatim. Default target: the current
    /// step, except during a rest, when the number they call out is about
    /// the set they just finished, not the upcoming one.
    func log(value: String, forStepId stepId: String? = nil) {
        let id = stepId ?? defaultLogTarget?.id
        guard let id else { return }
        snapshot.loggedValues[id] = value
        persist()
    }

    private var defaultLogTarget: Step? {
        if state == .resting, snapshot.currentStepIndex > 0 {
            return session.steps[snapshot.currentStepIndex - 1]
        }
        return currentStep
    }

    /// "I'm done" / stop — ends the session from any live state. The
    /// snapshot survives in memory for the SessionRecord; the file is gone
    /// so a dead session is never offered as a resume.
    @discardableResult
    func endEarly() -> Bool {
        guard state != .notStarted, state != .finished else { return false }
        finish()
        return true
    }

    // MARK: - Plumbing

    private func finish() {
        state = .finished
        snapshot.pausedAt = nil
        snapshot.updatedAt = Date()
        store.clear()
    }

    private func persist() {
        snapshot.updatedAt = Date()
        store.save(snapshot)
    }
}
