import Foundation

/// Everything the runtime says that is NOT verbatim plan text, built
/// deterministically — no model anywhere near it. Cue text itself always
/// comes from the Plan unchanged.
enum GuidancePhrases {

    /// "Upper A. 6 steps, about 45 minutes."
    static func sessionIntro(title: String, stepCount: Int, minutes: Int) -> String {
        let steps = stepCount == 1 ? "1 step" : "\(stepCount) steps"
        return "\(title). \(steps), about \(minutes) minutes."
    }

    /// "Upper A, picking up at step 4 of 6."
    static func resumeIntro(title: String, stepNumber: Int, total: Int) -> String {
        "\(title), picking up at step \(stepNumber) of \(total)."
    }

    /// "3 sets of 8 at 20 kilos." / "8 reps." — nil when the target has
    /// nothing announceable (timers announce themselves).
    static func targetLine(_ target: StepTarget?) -> String? {
        guard let target else { return nil }
        let load = target.load.map { " at \(loadText($0))" } ?? ""
        if let sets = target.sets, let reps = target.reps {
            return "\(sets) sets of \(reps)\(load)."
        }
        if let reps = target.reps {
            return "\(reps) reps\(load)."
        }
        return nil
    }

    static func loadText(_ kg: Double) -> String {
        kg == kg.rounded()
            ? "\(Int(kg)) kilos"
            : String(format: "%.1f kilos", kg)
    }

    /// "Set 2 of 3." — or "Last set." when it is.
    static func setLine(current: Int, total: Int) -> String {
        current >= total ? "Last set." : "Set \(current) of \(total)."
    }

    /// "1 minute 30 left." / "45 seconds left."
    static func remainingLine(seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds.rounded()))
        if whole >= 60 {
            let minutes = whole / 60
            let rest = whole % 60
            let minuteWord = minutes == 1 ? "1 minute" : "\(minutes) minutes"
            return rest == 0 ? "\(minuteWord) left." : "\(minuteWord) \(rest) left."
        }
        return whole == 1 ? "1 second left." : "\(whole) seconds left."
    }

    /// Checklist convention: one item per sentence (or line) of the cue.
    /// The plan generator writes checklist cues that way; a cue that
    /// doesn't split cleanly becomes a single item.
    static func checklistItems(from cue: String) -> [String] {
        let lines = cue
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let sentences = lines.flatMap { line in
            line.components(separatedBy: ". ").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
        }
        .filter { !$0.isEmpty }
        .map { $0.hasSuffix(".") || $0.hasSuffix("!") || $0.hasSuffix("?") ? $0 : "\($0)." }
        return sentences.isEmpty ? [cue] : sentences
    }
}

enum GuidanceMath {

    /// Applies a schedule entry's progression overrides to a template step.
    /// Loads round to the nearest 0.5 kg (plates exist); reps and sets
    /// never drop below 1. Cue text is untouched — always verbatim.
    static func resolved(step: Step, progression: Progression?) -> Step {
        guard let progression, let target = step.target else { return step }
        var next = target
        if let multiplier = progression.loadMultiplier, let load = target.load {
            next.load = (load * multiplier * 2).rounded() / 2
        }
        if let repsDelta = progression.repsDelta, let reps = target.reps {
            next.reps = max(1, reps + repsDelta)
        }
        if let setsDelta = progression.setsDelta, let sets = target.sets {
            next.sets = max(1, sets + setsDelta)
        }
        var resolved = step
        resolved.target = next
        return resolved
    }
}
