// GENERATED FROM shared/schemas — DO NOT EDIT
//
// Support file — shared/codegen/swift.ts
// Regenerate with `npm run codegen`.
//
// Requires this app-target build setting:
//   SWIFT_DEFAULT_ACTOR_ISOLATION = nonisolated
//
// Under MainActor-by-default isolation these Codable conformances cannot
// compile: a main-actor-isolated initializer cannot satisfy the nonisolated
// `init(from:)` requirement.

import Foundation

/// The single JSON coding configuration shared by every generated Otto model.
///
/// Every schema field built from `isoDateTime` (`z.string().datetime({ offset: true })`)
/// decodes into a Swift `Date` through the strategies defined here. Because the
/// strategies live on the `JSONDecoder`/`JSONEncoder`, they apply to `Date` at any
/// nesting depth — including `Trigger.at` inside `OttoTask`, and `ListItem.addedAt`
/// inside `[ListItem]`.
///
/// `ScheduledSession.timeOfDay` ("08:00") is a wall-clock string, not an instant,
/// and stays a Swift `String`.
enum OttoCoding {

    // Canonical wire format: 2026-07-30T14:00:00.123Z
    //
    // RFC 3339, UTC, three fractional digits. Byte-for-byte what JavaScript's
    // Date.prototype.toISOString() produces, and accepted by the server's
    // z.string().datetime({ offset: true }).

    /// Primary parser.
    ///
    /// `Date.ISO8601FormatStyle` is a `Sendable` struct, so these `static let`s are
    /// concurrency-safe under Swift 6. `ISO8601DateFormatter` is a non-Sendable
    /// class and would not be.
    ///
    /// `includingFractionalSeconds` constrains FORMATTING only. As of Swift 6.2 the
    /// parser accepts fractional seconds either way (and keeps their precision), so
    /// on iOS 26 this parser alone handles both `...00Z` and `...00.123Z`.
    ///
    /// A zone designator is REQUIRED — `timeZone` is passed as the default but is
    /// always overridden by the `Z` or numeric offset in the string, which is what
    /// determines the instant. The server's `.datetime({ offset: true })` guarantees
    /// a designator is present.
    private static let parser = Date.ISO8601FormatStyle(
        includingFractionalSeconds: false,
        timeZone: TimeZone.gmt
    )

    /// Formats the canonical wire form, and parses on Foundation versions before
    /// Swift 6.2 where a parser had to match the input's fractional seconds exactly.
    private static let fractionalParser = Date.ISO8601FormatStyle(
        includingFractionalSeconds: true,
        timeZone: TimeZone.gmt
    )

    /// Parses any ISO-8601 instant the server or an iOS client emits.
    ///
    ///     2026-07-30T14:00:00Z
    ///     2026-07-30T10:00:00-04:00
    ///     2026-07-30T10:00:00.123-04:00
    ///     2026-07-30T14:00:00.123456Z
    static func date(fromISO8601 string: String) -> Date? {
        if let date = try? OttoCoding.parser.parse(string) {
            return date
        }
        if let date = try? OttoCoding.fractionalParser.parse(string) {
            return date
        }
        return nil
    }

    /// Renders `date` in the canonical wire form.
    static func iso8601String(from date: Date) -> String {
        return OttoCoding.fractionalParser.format(date)
    }

    /// The `.custom` payload is `@Sendable`; this closure captures nothing and
    /// reaches the parsers through `OttoCoding`'s own Sendable statics.
    static let dateDecodingStrategy: JSONDecoder.DateDecodingStrategy =
        .custom { (decoder: any Decoder) throws -> Date in
            // `singleValueContainer()` throws; `decode` is non-mutating, so `let`.
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let date = OttoCoding.date(fromISO8601: raw) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected an ISO-8601 date-time string, found \(raw.debugDescription)."
                )
            }
            return date
        }

    static let dateEncodingStrategy: JSONEncoder.DateEncodingStrategy =
        .custom { (date: Date, encoder: any Encoder) throws -> Void in
            // `Encoder.singleValueContainer()` does NOT throw — no `try`.
            // `encode` is mutating, so `var`.
            var container = encoder.singleValueContainer()
            try container.encode(OttoCoding.iso8601String(from: date))
        }

    /// Never set `keyEncodingStrategy`/`keyDecodingStrategy`: the wire keys are
    /// already lowerCamelCase and any conversion would break the Zod contract.
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = OttoCoding.dateDecodingStrategy
        return decoder
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = OttoCoding.dateEncodingStrategy
        return encoder
    }

    /// Shared coders. These are reference types: never mutate their properties.
    /// Use `makeDecoder()`/`makeEncoder()` if you need a configured copy.
    static let decoder: JSONDecoder = OttoCoding.makeDecoder()
    static let encoder: JSONEncoder = OttoCoding.makeEncoder()
}
