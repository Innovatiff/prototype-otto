import Foundation

/// What the guided-session UI (Step 9) renders from. Lossless, single
/// consumer, same pattern as VoiceLoop's event stream.
enum GuidanceEvent: Sendable {
    case began(sessionTitle: String, resumed: Bool)
    case stepChanged(index: Int, total: Int, step: Step)
    case resting
    case paused(Bool)
    case finished(early: Bool, snapshot: GuidanceSnapshot)
}

/// Per-step output token: executors reach the conductor through one of
/// these, stamped with the step's generation — so a completion signal from
/// a stale step (timer racing a spoken "done") can never advance twice.
private struct StepOutput: GuidanceOutputting {
    let conductor: GuidanceConductor
    let generation: Int

    func speak(_ text: String) async { await conductor.speakText(text) }
    func play(_ clip: CachedClip) async { await conductor.playClip(clip) }
    func stepCompleted() async { await conductor.stepCompleted(generation: generation) }
    func timerArmed(deadline: Date) async { await conductor.timerArmed(deadline: deadline) }
    func timerCleared() async { await conductor.timerCleared() }
}

/// The conductor: ties the state machine, the executors, and the voice
/// together. THE SESSION DRIVES THE SPEAKER — cues verbatim from the plan,
/// spoken once; clips for everything repeated; silence in between, on
/// purpose. Zero LLM calls anywhere in this file.
actor GuidanceConductor {

    static let defaultInterStepRest: TimeInterval = 90

    private let session: GuidanceSession
    private let template: Session
    private let progression: Progression?
    private let speakLine: @Sendable (String) async -> Void
    private let playClipLine: @Sendable (CachedClip) async -> Void
    /// Local-notification backstop for running timers; nil in tests that
    /// don't care.
    private let backstop: (any GuidanceBackstopping)?
    /// Test override for every rest (between sets and between steps).
    private let restOverride: TimeInterval?
    private let resumed: Bool

    private var executor: (any StepExecutor)?
    private var interStepRest: TimedExecutor?
    private var eventContinuation: AsyncStream<GuidanceEvent>.Continuation?
    /// Bumped on every step change and advance — stale completion signals
    /// compare against it and die.
    private var stepGeneration = 0

    init(
        planId: String,
        template: Session,
        progression: Progression?,
        store: GuidanceStore,
        resumeFrom: GuidanceSnapshot? = nil,
        backstop: (any GuidanceBackstopping)? = nil,
        restOverride: TimeInterval? = nil,
        speak: @escaping @Sendable (String) async -> Void,
        play: @escaping @Sendable (CachedClip) async -> Void
    ) {
        self.session = GuidanceSession(
            planId: planId, session: template, store: store, resumeFrom: resumeFrom
        )
        self.template = template
        self.progression = progression
        self.speakLine = speak
        self.playClipLine = play
        self.backstop = backstop
        self.restOverride = restOverride
        self.resumed = (resumeFrom?.currentStepIndex ?? 0) > 0
    }

    /// The session's persisted truth — Step 8 writes the SessionRecord
    /// from this after `finished`.
    func currentSnapshot() async -> GuidanceSnapshot {
        await session.currentSnapshot
    }

    /// Lossless event stream for the guidance UI. Single consumer.
    func events() -> AsyncStream<GuidanceEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: GuidanceEvent.self)
        eventContinuation = continuation
        return stream
    }

    // MARK: - Lifecycle

    func start() async {
        guard await session.start() else { return }
        emit(.began(sessionTitle: template.title, resumed: resumed))
        if resumed {
            let number = await session.currentStepIndex + 1
            await speakLine(
                GuidancePhrases.resumeIntro(
                    title: template.title, stepNumber: number, total: template.steps.count
                )
            )
        } else {
            await speakLine(
                GuidancePhrases.sessionIntro(
                    title: template.title,
                    stepCount: template.steps.count,
                    minutes: template.estimatedMinutes
                )
            )
        }
        guard await session.announcementFinished() else { return }
        if await session.state == .finished {
            await finishSession(early: false)
        } else {
            await beginCurrentStep()
        }
    }

    /// UI taps route through here too — the "Done" button is `.next`.
    func handle(_ cmd: VoiceCommand) async {
        // During a between-step rest there is no executor; the rest timer
        // answers what it can, everything else is session-level.
        if let interStepRest {
            switch cmd {
            case .next:
                await interStepRest.cancel()
                self.interStepRest = nil
                if await session.restFinished() {
                    await beginCurrentStep()
                }
                return
            case .timeLeft, .repeatCue:
                _ = await interStepRest.handleVoiceCommand(.timeLeft)
                return
            default:
                break
            }
        }
        if let current = executor {
            let result = await current.handleVoiceCommand(cmd)
            // The await can interleave with a timer's own completion; only
            // act if this executor is still the one on stage.
            guard current === executor else { return }
            switch result {
            case .handled:
                return
            case .completed:
                await advanceAfterCompletion()
                return
            case .passToSession:
                break
            }
        }
        await handleSessionCommand(cmd)
    }

    // MARK: - Executor plumbing (reached via StepOutput tokens)

    func speakText(_ text: String) async {
        await speakLine(text)
    }

    func playClip(_ clip: CachedClip) async {
        await playClipLine(clip)
    }

    /// An executor finished on its own — a timer hit zero. Only the
    /// current step's generation may advance.
    func stepCompleted(generation: Int) async {
        guard generation == stepGeneration else { return }
        await advanceAfterCompletion()
    }

    /// A countdown started (or resumed): arm the terminated-app backstop.
    func timerArmed(deadline: Date) async {
        let title = await session.currentStep?.title ?? template.title
        await backstop?.arm(
            fireIn: deadline.timeIntervalSinceNow,
            stepTitle: title
        )
    }

    /// The countdown ended in-app — the backstop must not fire.
    func timerCleared() async {
        await backstop?.cancel()
    }

    // MARK: - Advancement

    private func beginCurrentStep() async {
        guard let raw = await session.currentStep else {
            await finishSession(early: false)
            return
        }
        let step = GuidanceMath.resolved(step: raw, progression: progression)
        let progress = await session.progress
        emit(.stepChanged(index: progress.index, total: progress.total, step: step))
        stepGeneration += 1
        let output = StepOutput(conductor: self, generation: stepGeneration)
        let next = StepExecutors.make(for: step, output: output, restSeconds: restOverride)
        executor = next
        await next.begin(step)
    }

    private func advanceAfterCompletion() async {
        stepGeneration += 1
        let finished = await session.currentStep
        if let executor {
            await executor.cancel()
        }
        executor = nil
        guard await session.beginCompleting() else { return }

        // A rest between steps only after counted work — you rest after the
        // last set of squats before the bench, but a cooking prompt flows
        // straight on. Never after the final step.
        let progress = await session.progress
        let isLast = progress.index + 1 >= progress.total
        let restAfter = finished?.type == .counted && !isLast

        guard await session.advance(throughRest: restAfter) else { return }
        if await session.state == .finished {
            await finishSession(early: false)
            return
        }
        if restAfter {
            emit(.resting)
            await playClipLine(.rest)
            let seconds =
                restOverride
                ?? finished?.target?.durationSec.map(TimeInterval.init)
                ?? Self.defaultInterStepRest
            let output = StepOutput(conductor: self, generation: stepGeneration)
            let timer = TimedExecutor(output: output) { [weak self] in
                await self?.interStepRestEnded()
            }
            interStepRest = timer
            await timer.startCountdown(seconds: seconds)
        } else {
            await beginCurrentStep()
        }
    }

    private func interStepRestEnded() async {
        // A rest that was cancelled (skipped, backed out of, stopped) may
        // still deliver a late signal — drop it.
        guard interStepRest != nil else { return }
        interStepRest = nil
        guard await session.restFinished() else { return }
        await beginCurrentStep()
    }

    // MARK: - Off-script questions (Step 6)

    /// Freezes the session for an off-script answer — timers stop, nothing
    /// is lost, no ceremony spoken. Returns the position line ("Set 2 of 3,
    /// 8 reps.") for the server's context; the same line anchors the return.
    func suspendForQuestion() async -> String? {
        _ = await session.pause()
        await freezeTimers()
        emit(.paused(true))
        return await positionLine()
    }

    /// Back from the answer: "Back to it — set 2 of 3, 8 reps." spoken
    /// while the clock is still frozen, then everything restarts exactly
    /// where it stopped.
    func resumeFromQuestion() async {
        _ = await session.resume()
        await playClipLine(.backToIt)
        if let line = await positionLine() {
            await speakLine(line)
        }
        await unfreezeTimers()
        emit(.paused(false))
    }

    private func positionLine() async -> String? {
        if let interStepRest, let remaining = await interStepRest.remainingSeconds {
            return GuidancePhrases.remainingLine(seconds: remaining)
        }
        return await executor?.statusLine()
    }

    private func freezeTimers() async {
        _ = await interStepRest?.handleVoiceCommand(.pause)
        _ = await executor?.handleVoiceCommand(.pause)
    }

    private func unfreezeTimers() async {
        _ = await interStepRest?.handleVoiceCommand(.resume)
        _ = await executor?.handleVoiceCommand(.resume)
    }

    // MARK: - Session-level commands

    private func handleSessionCommand(_ cmd: VoiceCommand) async {
        switch cmd {
        case .skip:
            await executor?.cancel()
            executor = nil
            if await session.skip() {
                await playClipLine(.skipped)
                if await session.state == .finished {
                    await finishSession(early: false)
                } else {
                    await beginCurrentStep()
                }
            }
        case .back:
            await executor?.cancel()
            executor = nil
            await interStepRest?.cancel()
            interStepRest = nil
            if await session.back() {
                await playClipLine(.goingBack)
                await beginCurrentStep()
            } else {
                await playClipLine(.firstStepAlready)
            }
        case .pause:
            _ = await interStepRest?.handleVoiceCommand(.pause)
            if await session.pause() {
                await playClipLine(.paused)
                emit(.paused(true))
            }
        case .resume:
            _ = await interStepRest?.handleVoiceCommand(.resume)
            if await session.resume() {
                await playClipLine(.resumed)
                emit(.paused(false))
            }
        case .stop:
            await executor?.cancel()
            executor = nil
            await interStepRest?.cancel()
            interStepRest = nil
            if await session.endEarly() {
                await finishSession(early: true)
            }
        case .logValue(let raw):
            await session.log(value: raw, forStepId: nil)
            await playClipLine(.logged)
        case .next, .repeatCue, .timeLeft:
            // No executor to answer (announcing, edge states) — silence is
            // correct; do not fill it.
            break
        }
    }

    private func finishSession(early: Bool) async {
        // However the session ends, no backstop may outlive it.
        await backstop?.cancel()
        await playClipLine(early ? .stoppedEarly : .sessionDone)
        emit(.finished(early: early, snapshot: await session.currentSnapshot))
        eventContinuation?.finish()
        eventContinuation = nil
    }

    private func emit(_ event: GuidanceEvent) {
        eventContinuation?.yield(event)
    }
}
