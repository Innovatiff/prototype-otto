import Foundation

/// Turns a token stream into speakable units — the biggest lever on perceived
/// latency: the speaker starts on the first unit while the model is still
/// generating the rest.
///
/// A speakable unit is:
///   - a sentence ending in `.` `!` or `?`
///   - or a clause ending in `,` `;` or `:` that is at least 5 words long
///   - or 12+ words with no qualifying boundary (a long run must not block audio)
///
/// Never splits on decimals (3.14), thousands separators (1,000), clock times
/// (3:30), single-letter initials (J. K.), known abbreviations (Dr., a.m.),
/// or ellipses. A trailing digit-period holds while the stream is open — the
/// next token might make it "3.5".
///
/// One instance per turn; not thread-safe on its own — VoiceLoop (an actor)
/// owns it. Segmentation behavior is pinned by OttoTests/ClauseBufferVectors
/// .json, shared with the reference implementation that validated the rules.
final class ClauseBuffer {

    /// Speakable units, in order. Single consumer (the Speaker).
    let units: AsyncStream<String>

    private let continuation: AsyncStream<String>.Continuation
    private var pending: [Character] = []
    private var finished = false

    private static let sentenceEnders: Set<Character> = [".", "!", "?"]
    private static let clauseEnders: Set<Character> = [",", ";", ":"]
    private static let closers: Set<Character> = ["\"", "'", "”", "’", ")", "]", "}"]
    private static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "vs", "etc",
        "e.g", "i.e", "a.m", "p.m",
    ]
    private static let minClauseWords = 5
    private static let overflowWords = 12

    init() {
        (units, continuation) = AsyncStream.makeStream(of: String.self)
    }

    /// Appends a token and emits every unit that is now complete.
    func ingest(_ token: String) {
        guard !finished else { return }
        pending.append(contentsOf: token)
        while let unit = extractNext(streamOpen: true) {
            continuation.yield(unit)
        }
    }

    /// Emits any remaining complete units, flushes the tail, ends the stream.
    func finish() {
        guard !finished else { return }
        finished = true
        while let unit = extractNext(streamOpen: false) {
            continuation.yield(unit)
        }
        let rest = String(pending).trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty {
            continuation.yield(rest)
        }
        pending = []
        continuation.finish()
    }

    /// Ends the stream discarding whatever is buffered (barge-in path).
    func cancel() {
        guard !finished else { return }
        finished = true
        pending = []
        continuation.finish()
    }

    // MARK: - Segmentation

    private func extractNext(streamOpen: Bool) -> String? {
        // 1. Earliest qualifying sentence or clause boundary.
        for index in pending.indices {
            let character = pending[index]
            guard Self.sentenceEnders.contains(character) || Self.clauseEnders.contains(character) else {
                continue
            }
            guard let end = boundaryEnd(at: index, streamOpen: streamOpen) else {
                continue
            }
            let unit = String(pending[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            pending = Array(pending[end...].drop(while: { $0.isWhitespace }))
            return unit.isEmpty ? nil : unit
        }

        // 2. Overflow: 12+ complete words with no boundary must not block audio.
        guard let lastSpace = pending.lastIndex(where: { $0.isWhitespace }), lastSpace > 0 else {
            return nil
        }
        let complete = pending[..<lastSpace]
        guard wordCount(of: complete) >= Self.overflowWords else {
            return nil
        }
        let unit = String(complete).trimmingCharacters(in: .whitespacesAndNewlines)
        pending = Array(pending[lastSpace...].drop(while: { $0.isWhitespace }))
        return unit
    }

    /// Index just past the ender plus any closing quotes/brackets, or nil if
    /// this ender is not a valid boundary.
    private func boundaryEnd(at index: Int, streamOpen: Bool) -> Int? {
        let character = pending[index]
        var end = index + 1
        while end < pending.count, Self.closers.contains(pending[end]) {
            end += 1
        }
        let atEnd = end >= pending.count
        let followedBySpace = !atEnd && pending[end].isWhitespace

        if Self.sentenceEnders.contains(character) {
            if character == "." {
                let previous: Character? = index > 0 ? pending[index - 1] : nil
                let next: Character? = index + 1 < pending.count ? pending[index + 1] : nil
                // Ellipsis runs are never boundaries.
                if previous == "." || next == "." {
                    return nil
                }
                // Decimal point; and a trailing "3." might become "3.5" — hold.
                if let previous, isAsciiDigit(previous) {
                    if let next, isAsciiDigit(next) {
                        return nil
                    }
                    if atEnd && streamOpen {
                        return nil
                    }
                }
                let word = wordBefore(index)
                // Single-letter initials (J. K. Rowling) and abbreviations.
                if word.count == 1 {
                    return nil
                }
                if Self.abbreviations.contains(word) {
                    return nil
                }
            }
            return (atEnd || followedBySpace) ? end : nil
        }

        // Clause enders.
        let previous: Character? = index > 0 ? pending[index - 1] : nil
        let next: Character? = index + 1 < pending.count ? pending[index + 1] : nil
        // 1,000 and 3:30 are not boundaries.
        if let previous, let next, isAsciiDigit(previous), isAsciiDigit(next) {
            return nil
        }
        guard atEnd || followedBySpace else {
            return nil
        }
        guard wordCount(of: pending[..<end]) >= Self.minClauseWords else {
            return nil
        }
        return end
    }

    /// The word immediately before `index`, lowercased, leading non-letters
    /// stripped, internal periods kept ("a.m", "(Dr" -> "dr").
    private func wordBefore(_ index: Int) -> String {
        var start = index
        while start > 0, !pending[start - 1].isWhitespace {
            start -= 1
        }
        let lowered = String(pending[start..<index]).lowercased()
        let letters = lowered.drop(while: { !($0 >= "a" && $0 <= "z") })
        return String(letters)
    }

    private func wordCount(of slice: ArraySlice<Character>) -> Int {
        var count = 0
        var inWord = false
        for character in slice {
            if character.isWhitespace {
                inWord = false
            } else if !inWord {
                inWord = true
                count += 1
            }
        }
        return count
    }

    private func isAsciiDigit(_ character: Character) -> Bool {
        character >= "0" && character <= "9"
    }
}
