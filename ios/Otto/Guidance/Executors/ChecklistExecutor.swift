import Foundation

/// Prep lists, packing, multi-item steps. Items are read ONE AT A TIME —
/// never the whole list at once. "done"/"next" checks the current item and
/// reads the next; the step completes when the last item is checked.
actor ChecklistExecutor: StepExecutor {

    private let output: any GuidanceOutputting
    private var items: [String] = []
    private var index = 0

    init(output: any GuidanceOutputting) {
        self.output = output
    }

    func begin(_ step: Step) async {
        items = GuidancePhrases.checklistItems(from: step.cue)
        index = 0
        if let first = items.first {
            await output.speak(first)
        }
    }

    func handleVoiceCommand(_ cmd: VoiceCommand) async -> ExecutorResult {
        switch cmd {
        case .next:
            index += 1
            guard index < items.count else { return .completed }
            await output.speak(items[index])
            return .handled
        case .repeatCue:
            if index < items.count {
                await output.speak(items[index])
            }
            return .handled
        case .timeLeft:
            await output.speak("Item \(min(index + 1, items.count)) of \(items.count).")
            return .handled
        case .pause, .resume:
            // Nothing ticking — the session records the pause.
            return .passToSession
        case .skip, .back, .stop, .logValue:
            return .passToSession
        }
    }

    func cancel() async {
        items = []
        index = 0
    }

    func statusLine() async -> String? {
        guard !items.isEmpty else { return nil }
        return "Item \(min(index + 1, items.count)) of \(items.count)."
    }
}
