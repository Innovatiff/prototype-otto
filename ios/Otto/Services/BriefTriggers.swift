import Foundation

/// Deterministic client-side detection of brief requests. These utterances
/// must never become normal server turns — the brief needs the on-device
/// calendar payload — so the voice loop checks here before running a turn.
enum BriefTriggers {

    /// Whole-utterance matches.
    private static let exactPhrases: Set<String> = [
        "brief me",
        "morning brief",
        "daily brief",
        "run my brief",
        "the brief",
        "get me ready",
        "get me ready for today",
        "get me ready for the day",
        "whats expected today",
        "whats expected of me today",
        "whats my day",
        "whats my day look like",
        "whats my day looking like",
        "hows my day looking",
        "ready for today",
    ]

    /// Substrings distinctive enough to trigger from inside a sentence.
    private static let containedPhrases: [String] = [
        "brief me",
        "morning brief",
        "daily brief",
        "get me ready for today",
        "whats expected today",
        "whats my day look",
    ]

    static func matches(_ utterance: String) -> Bool {
        let normalized = normalize(utterance)
        guard !normalized.isEmpty else { return false }
        if exactPhrases.contains(normalized) {
            return true
        }
        return containedPhrases.contains { normalized.contains($0) }
    }

    /// Lowercased, punctuation/apostrophes stripped, whitespace collapsed.
    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted)
            .joined()
            .split(separator: " ")
            .joined(separator: " ")
    }
}
