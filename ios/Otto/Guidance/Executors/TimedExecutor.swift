import Foundation

/// The countdown's arithmetic, pure and wall-clock based: a DEADLINE, not
/// a tick count, so backgrounding and pauses can't drift it (Step 4 relies
/// on this). The executor sleeps toward the deadline; this decides where
/// the announcements land.
struct TimedCore: Equatable, Sendable {
    let warningLead: TimeInterval
    private(set) var deadline: Date
    private(set) var pausedRemaining: TimeInterval?
    private(set) var warned: Bool

    /// A timer at or under `minimumForWarning` never warns — "Ten seconds"
    /// half a breath into an eight-second rest is noise, not guidance.
    init(
        seconds: TimeInterval,
        now: Date,
        warningLead: TimeInterval = 10,
        minimumForWarning: TimeInterval = 12
    ) {
        self.warningLead = warningLead
        self.deadline = now.addingTimeInterval(seconds)
        self.pausedRemaining = nil
        self.warned = seconds <= minimumForWarning
    }

    var isPaused: Bool { pausedRemaining != nil }

    func remaining(now: Date) -> TimeInterval {
        pausedRemaining ?? max(0, deadline.timeIntervalSince(now))
    }

    /// Seconds to sleep before the next announcement, and whether that
    /// announcement is the warning (true) or zero (false).
    func nextWakeup(now: Date) -> (delay: TimeInterval, isWarning: Bool) {
        let left = remaining(now: now)
        if !warned && left > warningLead {
            return (left - warningLead, true)
        }
        return (left, false)
    }

    mutating func markWarned() { warned = true }

    mutating func pause(now: Date) {
        guard pausedRemaining == nil else { return }
        pausedRemaining = remaining(now: now)
    }

    mutating func resume(now: Date) {
        guard let left = pausedRemaining else { return }
        deadline = now.addingTimeInterval(left)
        pausedRemaining = nil
    }
}

/// Rests, cooking timers, focus blocks, holds. Speaks the cue once, warns
/// at ten seconds, announces zero — both from cached clips — and
/// auto-advances. Also serves as the between-sets rest inside
/// CountedExecutor via `startCountdown`, where completion goes to the
/// owner instead of the session.
actor TimedExecutor: StepExecutor {

    /// A timed step without a duration still runs — a minute is a usable
    /// default; the generator normally always sets durationSec.
    static let fallbackSeconds: TimeInterval = 60

    private let output: any GuidanceOutputting
    private let onFinished: (@Sendable () async -> Void)?
    private var core: TimedCore?
    private var ticker: Task<Void, Never>?
    private var cue: String?

    init(output: any GuidanceOutputting, onFinished: (@Sendable () async -> Void)? = nil) {
        self.output = output
        self.onFinished = onFinished
    }

    func begin(_ step: Step) async {
        cue = step.cue
        await output.speak(step.cue)
        let seconds = step.target?.durationSec.map(TimeInterval.init) ?? Self.fallbackSeconds
        await startCountdown(seconds: seconds)
    }

    /// Direct entry for rests (no cue, no step). Injectable warning
    /// parameters keep the tests fast.
    func startCountdown(
        seconds: TimeInterval,
        warningLead: TimeInterval = 10,
        minimumForWarning: TimeInterval = 12
    ) async {
        ticker?.cancel()
        let fresh = TimedCore(
            seconds: seconds,
            now: Date(),
            warningLead: warningLead,
            minimumForWarning: minimumForWarning
        )
        core = fresh
        await output.timerArmed(deadline: fresh.deadline)
        runTicker()
    }

    func handleVoiceCommand(_ cmd: VoiceCommand) async -> ExecutorResult {
        switch cmd {
        case .next:
            // "done" on a timer ends it early, honestly — no zero clip.
            ticker?.cancel()
            core = nil
            await output.timerCleared()
            return .completed
        case .repeatCue:
            if let cue { await output.speak(cue) }
            return .handled
        case .timeLeft:
            if let core {
                await output.speak(GuidancePhrases.remainingLine(seconds: core.remaining(now: Date())))
            }
            return .handled
        case .pause:
            ticker?.cancel()
            core?.pause(now: Date())
            await output.timerCleared()
            return .passToSession
        case .resume:
            core?.resume(now: Date())
            if let core {
                await output.timerArmed(deadline: core.deadline)
            }
            runTicker()
            return .passToSession
        case .skip, .back, .stop, .logValue:
            return .passToSession
        }
    }

    func cancel() async {
        let hadTimer = core != nil
        ticker?.cancel()
        ticker = nil
        core = nil
        if hadTimer {
            await output.timerCleared()
        }
    }

    var remainingSeconds: TimeInterval? {
        core?.remaining(now: Date())
    }

    // MARK: - The countdown loop

    private func runTicker() {
        guard let core, !core.isPaused else { return }
        ticker?.cancel()
        ticker = Task { [weak self] in
            await self?.tick()
        }
    }

    private func tick() async {
        while !Task.isCancelled {
            guard let current = core, !current.isPaused else { return }
            let wakeup = current.nextWakeup(now: Date())
            if wakeup.delay > 0 {
                try? await Task.sleep(for: .seconds(wakeup.delay))
            }
            if Task.isCancelled { return }
            guard let after = core, !after.isPaused else { return }
            if wakeup.isWarning {
                // Sleep can overshoot; warn only while a warning still makes
                // sense — otherwise fall through to zero on the next lap.
                if after.remaining(now: Date()) > min(1, after.warningLead / 4) {
                    await output.play(.tenSeconds)
                }
                core?.markWarned()
                continue
            }
            break
        }
        if Task.isCancelled { return }
        core = nil
        // Completed in-app: the notification backstop must not fire too.
        await output.timerCleared()
        await output.play(.timeUp)
        if let onFinished {
            await onFinished()
        } else {
            await output.stepCompleted()
        }
    }
}
