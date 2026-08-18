import Foundation

/// The fixed guidance vocabulary, classified ON DEVICE — a dictionary
/// lookup and two regexes, microseconds, no network. Anything that doesn't
/// match returns nil and becomes an off-script question (Step 6); exact
/// phrase matching keeps gym chatter from triggering commands.
enum GuidanceCommandClassifier {

    /// Full-utterance matches after normalization. Note the deliberate
    /// splits: "done" completes a step, "im done" ends the session;
    /// "finished" completes, "im finished" ends.
    private static let exact: [String: VoiceCommand] = [
        // next / done / finished → complete the current unit
        "next": .next, "done": .next, "finished": .next, "finish": .next,
        "next step": .next, "all done": .next, "thats done": .next, "check": .next,

        // repeat / say that again
        "repeat": .repeatCue, "repeat that": .repeatCue, "again": .repeatCue,
        "say that again": .repeatCue, "say it again": .repeatCue,
        "one more time": .repeatCue, "what was that": .repeatCue,

        // how much longer / time left
        "how much longer": .timeLeft, "time left": .timeLeft, "how long": .timeLeft,
        "how long left": .timeLeft, "how much time": .timeLeft,
        "whats left": .timeLeft, "time remaining": .timeLeft, "remaining": .timeLeft,

        // skip
        "skip": .skip, "skip it": .skip, "skip this": .skip,
        "skip this one": .skip, "skip that": .skip, "pass": .skip,

        // pause / hold on
        "pause": .pause, "hold on": .pause, "hold up": .pause,
        "wait": .pause, "hang on": .pause, "one second": .pause,

        // resume / continue
        "resume": .resume, "continue": .resume, "keep going": .resume,
        "go on": .resume, "go": .resume, "unpause": .resume, "lets go": .resume,

        // back
        "back": .back, "go back": .back, "previous": .back,
        "previous step": .back, "back one": .back, "go back one": .back,

        // I'm done / stop → end the session
        "stop": .stop, "im done": .stop, "i am done": .stop,
        "im finished": .stop, "i am finished": .stop,
        "end session": .stop, "end the session": .stop,
        "end workout": .stop, "end the workout": .stop,
        "stop the session": .stop, "stop the workout": .stop,
        "quit": .stop, "thats enough": .stop, "call it": .stop,
        "call it a day": .stop, "were done": .stop,

        // add weight (no number — a qualitative log Step 8 understands)
        "add weight": .logValue("add weight"),
        "added weight": .logValue("add weight"),
        "more weight": .logValue("add weight"),
    ]

    private static let leadingFillers: Set<String> = [
        "hey", "ok", "okay", "otto", "please", "uh", "um", "now",
    ]
    private static let trailingFillers: Set<String> = ["otto", "please", "now"]

    private static let questionStarters: Set<String> = [
        "how", "what", "whats", "can", "could", "should", "would", "will",
        "why", "where", "when", "is", "are", "do", "does", "am", "whos", "who",
    ]

    /// "135 pounds", "22.5 kilos" — unit canonicalized for Step 8's parser.
    private static let weightPattern =
        /(\d+(?:[.,]\d+)?)\s*(pounds|pound|lbs|lb|kilograms|kilogram|kilos|kilo|kgs|kg)\b/
    /// "used 135" with no unit — the plan's unit is implied.
    private static let bareUsedPattern = /^(?:i\s+)?used\s+(\d+(?:[.,]\d+)?)$/

    static func classify(_ utterance: String) -> VoiceCommand? {
        let text = normalize(utterance)
        guard !text.isEmpty else { return nil }

        // 1. Exact vocabulary — includes the question-shaped timeLeft
        //    phrases, so it runs before the question guard.
        if let command = exact[text] {
            return command
        }

        // 2. Questions are never commands — "can I do 20 pounds instead?"
        //    must reach the model, not the log.
        if let first = text.split(separator: " ").first,
           questionStarters.contains(String(first)) {
            return nil
        }

        // 3. Value logging: a weight with a log-verb, or nothing but the
        //    weight itself.
        if let match = text.firstMatch(of: weightPattern) {
            let number = String(match.1).replacingOccurrences(of: ",", with: ".")
            let unit = canonicalUnit(String(match.2))
            let value = "\(number) \(unit)"
            if text == "\(String(match.1)) \(String(match.2))" || containsLogVerb(text) {
                return .logValue(value)
            }
            return nil
        }
        if let match = text.firstMatch(of: bareUsedPattern) {
            return .logValue(String(match.1).replacingOccurrences(of: ",", with: "."))
        }

        return nil
    }

    /// The off-script gate: only question-shaped or Otto-addressed
    /// utterances escalate to the server. Gym chatter and grunts must never
    /// make Otto speak up uninvited — a dropped question costs a repeat; a
    /// false positive talks over someone's set.
    static func looksLikeQuestion(_ utterance: String) -> Bool {
        let raw = utterance.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !raw.isEmpty else { return false }
        if raw.hasSuffix("?") { return true }
        let tokens = raw
            .replacingOccurrences(of: ",", with: " ")
            .split(separator: " ")
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
        guard let first = tokens.first else { return false }
        if first == "otto" { return true }
        if first == "hey", tokens.count > 1, tokens[1] == "otto" { return true }
        return questionStarters.contains(first)
    }

    // MARK: - Pieces

    private static func canonicalUnit(_ raw: String) -> String {
        switch raw {
        case "pound", "pounds", "lb", "lbs": return "pounds"
        default: return "kilos"
        }
    }

    private static let logVerbs: Set<String> = [
        "used", "use", "did", "at", "with", "add", "added", "log", "logged",
        "make", "went", "was", "thats", "put",
    ]

    private static func containsLogVerb(_ text: String) -> Bool {
        text.split(separator: " ").contains { logVerbs.contains(String($0)) }
    }

    /// Lowercase, punctuation stripped (apostrophes vanish: "I'm" → "im"),
    /// whitespace collapsed, leading/trailing fillers dropped.
    static func normalize(_ utterance: String) -> String {
        let lowered = utterance.lowercased()
        var cleaned = ""
        for character in lowered {
            if character.isLetter || character.isNumber || character == " " {
                cleaned.append(character)
            } else if character == "." || character == "," {
                // Keep decimal separators inside numbers; drop sentence dots.
                if let last = cleaned.last, last.isNumber {
                    cleaned.append(character)
                } else {
                    cleaned.append(" ")
                }
            } else if character.isWhitespace {
                cleaned.append(" ")
            }
        }
        var tokens = cleaned
            .split(separator: " ")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".,")) }
            .filter { !$0.isEmpty }
        while let first = tokens.first, leadingFillers.contains(first) {
            tokens.removeFirst()
        }
        while let last = tokens.last, trailingFillers.contains(last) {
            tokens.removeLast()
        }
        return tokens.joined(separator: " ")
    }
}
