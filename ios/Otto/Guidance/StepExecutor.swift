import Foundation

/// The fixed guidance vocabulary, classified ON DEVICE (Step 5 builds the
/// classifier; executors consume the result). Never a network round trip.
enum VoiceCommand: Equatable, Sendable {
    /// next / done / finished — complete the current unit of work.
    case next
    /// repeat / say that again.
    case repeatCue
    /// how much longer / time left.
    case timeLeft
    case skip
    case pause
    case resume
    case back
    /// I'm done / stop — end the session.
    case stop
    /// "used 135 pounds" — the raw value, logged by the session.
    case logValue(String)
}

/// What an executor did with a command.
enum ExecutorResult: Equatable, Sendable {
    /// Consumed — nothing further to do.
    case handled
    /// The step is finished; the session advances.
    case completed
    /// A session-level command (skip, back, stop, pause bookkeeping,
    /// logging) — the conductor acts on it.
    case passToSession
}

/// How executors reach the world: verbatim speech, cached clips, and the
/// auto-advance signal (timers complete without a voice command). Step 3
/// wires this to the Speaker; tests record it.
protocol GuidanceOutputting: Sendable {
    func speak(_ text: String) async
    func play(_ clip: CachedClip) async
    /// An executor finished on its own (timer at zero) — advance the step.
    func stepCompleted() async
    /// A countdown is running toward this instant — the conductor arms a
    /// local-notification backstop so even a TERMINATED app still alerts.
    func timerArmed(deadline: Date) async
    /// The countdown ended in-app (zero, paused, cancelled, done early) —
    /// the backstop is cancelled.
    func timerCleared() async
}

/// Backstops are optional plumbing; recorders and simple outputs need not
/// care.
extension GuidanceOutputting {
    func timerArmed(deadline: Date) async {}
    func timerCleared() async {}
}

/// One executor per step type. Same protocol, different completion
/// behavior. Executors DRIVE the GuidanceSession via the conductor — they
/// never own session state. AnyObject so the conductor can identity-check
/// that a completion still belongs to the current step.
protocol StepExecutor: AnyObject, Sendable {
    func begin(_ step: Step) async
    func handleVoiceCommand(_ cmd: VoiceCommand) async -> ExecutorResult
    func cancel() async
    /// One short spoken line locating the user in the step — the off-script
    /// return anchor: "Set 2 of 3, 8 reps." Nil where position means nothing.
    func statusLine() async -> String?
}

extension StepExecutor {
    func statusLine() async -> String? { nil }
}

enum StepExecutors {
    /// The runtime's dispatch: step type → executor. Steps arrive already
    /// RESOLVED (progression overrides applied) — see GuidanceMath.
    /// `restSeconds` overrides the between-sets interval (tests);
    /// `reference` is last session's logged value for this step.
    static func make(
        for step: Step,
        output: any GuidanceOutputting,
        restSeconds: TimeInterval? = nil,
        reference: String? = nil
    ) -> any StepExecutor {
        switch step.type {
        case .timed:
            return TimedExecutor(output: output)
        case .counted:
            return CountedExecutor(output: output, restSeconds: restSeconds, reference: reference)
        case .checklist:
            return ChecklistExecutor(output: output)
        case .prompt:
            return PromptExecutor(output: output)
        }
    }
}
