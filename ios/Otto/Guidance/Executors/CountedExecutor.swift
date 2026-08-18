import Foundation

/// Sets and reps. Announces the target once, waits for "done" (or tap) per
/// set, hands the between-sets interval to a TimedExecutor, and completes
/// after the last set. Silence between cues is correct.
actor CountedExecutor: StepExecutor {

    /// Rest between sets when the step doesn't carry one (for counted
    /// steps, target.durationSec IS the rest interval).
    static let defaultRestSeconds: TimeInterval = 90

    private let output: any GuidanceOutputting
    private let injectedRest: TimeInterval?
    private let restWarningMinimum: TimeInterval

    private var step: Step?
    private var currentSet = 1
    private var totalSets = 1
    private var rest: TimedExecutor?

    init(
        output: any GuidanceOutputting,
        restSeconds: TimeInterval? = nil,
        restWarningMinimum: TimeInterval = 12
    ) {
        self.output = output
        self.injectedRest = restSeconds
        self.restWarningMinimum = restWarningMinimum
    }

    func begin(_ step: Step) async {
        self.step = step
        currentSet = 1
        totalSets = max(1, step.target?.sets ?? 1)
        if let target = GuidancePhrases.targetLine(step.target) {
            await output.speak(target)
        }
        await output.speak(step.cue)
    }

    func handleVoiceCommand(_ cmd: VoiceCommand) async -> ExecutorResult {
        switch cmd {
        case .next:
            if rest != nil {
                // "done" mid-rest: they're ready — skip the rest of the rest.
                await endRestEarly()
                return .handled
            }
            if currentSet >= totalSets {
                await cancelRest()
                return .completed
            }
            currentSet += 1
            await startRest()
            return .handled
        case .repeatCue:
            if let step {
                if let target = GuidancePhrases.targetLine(step.target) {
                    await output.speak(target)
                }
                await output.speak(step.cue)
            }
            return .handled
        case .timeLeft:
            if let rest, let remaining = await rest.remainingSeconds {
                await output.speak(GuidancePhrases.remainingLine(seconds: remaining))
            } else {
                await output.speak(GuidancePhrases.setLine(current: currentSet, total: totalSets))
            }
            return .handled
        case .pause:
            _ = await rest?.handleVoiceCommand(.pause)
            return .passToSession
        case .resume:
            _ = await rest?.handleVoiceCommand(.resume)
            return .passToSession
        case .skip, .back, .stop, .logValue:
            return .passToSession
        }
    }

    func cancel() async {
        await cancelRest()
        step = nil
    }

    // MARK: - The between-sets rest

    private func startRest() async {
        let seconds =
            injectedRest
            ?? step?.target?.durationSec.map(TimeInterval.init)
            ?? Self.defaultRestSeconds
        let timer = TimedExecutor(output: output) { [weak self] in
            await self?.restFinished()
        }
        rest = timer
        await timer.startCountdown(seconds: seconds, minimumForWarning: restWarningMinimum)
    }

    /// The rest timer ran out ("Time." already played) — call the next set.
    /// The guard drops a late signal from a timer that was already
    /// cancelled by "done"-during-rest.
    private func restFinished() async {
        guard rest != nil else { return }
        rest = nil
        await output.speak(GuidancePhrases.setLine(current: currentSet, total: totalSets))
    }

    private func endRestEarly() async {
        await cancelRest()
        await output.speak(GuidancePhrases.setLine(current: currentSet, total: totalSets))
    }

    private func cancelRest() async {
        if let rest {
            await rest.cancel()
        }
        rest = nil
    }
}
