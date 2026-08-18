import Foundation

/// Instructions with no measurable target — "pat the salmon dry." Speaks
/// the cue verbatim, once, then waits for "next". No timer, no counter,
/// and the silence in between is correct.
actor PromptExecutor: StepExecutor {

    private let output: any GuidanceOutputting
    private var cue: String?

    init(output: any GuidanceOutputting) {
        self.output = output
    }

    func begin(_ step: Step) async {
        cue = step.cue
        await output.speak(step.cue)
    }

    func handleVoiceCommand(_ cmd: VoiceCommand) async -> ExecutorResult {
        switch cmd {
        case .next:
            return .completed
        case .repeatCue:
            if let cue { await output.speak(cue) }
            return .handled
        case .timeLeft:
            // Nothing is counting; saying so beats silence.
            await output.speak("No timer on this one.")
            return .handled
        case .pause, .resume, .skip, .back, .stop, .logValue:
            return .passToSession
        }
    }

    func cancel() async {
        cue = nil
    }
}
