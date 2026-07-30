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

/// A lossless, `Sendable` representation of an arbitrary JSON value.
///
/// Backs the two Zod fields with no fixed shape:
///   - `TurnEvent.data` — `z.unknown()`
///   - `Plan.constraints` — `z.record(z.string(), z.unknown())`
///
/// No `indirect`: `Array` and `Dictionary` are fixed-size structs pointing at heap
/// storage, so the recursive cases do not make this enum's layout unbounded.
enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    /// A JSON number that is integral and fits in `Int`.
    case int(Int)
    /// Any other JSON number: fractional, exponential, or out of `Int` range.
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: any Decoder) throws {
        // `singleValueContainer()` throws; the container's decode requirements are
        // non-mutating, so `let`.
        let container = try decoder.singleValueContainer()

        // `SingleValueDecodingContainer.decodeNil()` does NOT throw — `try` would warn.
        if container.decodeNil() {
            self = .null
            return
        }

        // Bool before the numeric cases, and Int before Double, so integral values
        // keep full precision and re-encode without a decimal point.
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
            return
        }
        if let value = try? container.decode(Int.self) {
            self = .int(value)
            return
        }
        if let value = try? container.decode(Double.self) {
            self = .double(value)
            return
        }
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
            return
        }
        if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
            return
        }

        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: container.codingPath,
                debugDescription: "Not a representable JSON value."
            )
        )
    }

    func encode(to encoder: any Encoder) throws {
        // `Encoder.singleValueContainer()` does NOT throw; `encode` is mutating.
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            // `SingleValueEncodingContainer.encodeNil()` DOES throw.
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    func hash(into hasher: inout Hasher) {
        switch self {
        case .null:
            hasher.combine(0)
        case .bool(let value):
            hasher.combine(1)
            hasher.combine(value)
        case .int(let value):
            hasher.combine(2)
            hasher.combine(value)
        case .double(let value):
            hasher.combine(3)
            hasher.combine(value)
        case .string(let value):
            hasher.combine(4)
            hasher.combine(value)
        case .array(let value):
            hasher.combine(5)
            hasher.combine(value)
        case .object(let value):
            hasher.combine(6)
            hasher.combine(value)
        }
    }

    /// The wrapped string, when this value is a JSON string.
    ///
    /// Used by the debug console to pull token text out of `TurnEvent.data`.
    var stringValue: String? {
        switch self {
        case .string(let value):
            return value
        default:
            return nil
        }
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let value):
            return value
        default:
            return nil
        }
    }

    /// `Int(exactly:)` returns nil for fractional, out-of-range, and NaN values,
    /// so this never traps.
    var intValue: Int? {
        switch self {
        case .int(let value):
            return value
        case .double(let value):
            return Int(exactly: value)
        default:
            return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .int(let value):
            return Double(value)
        case .double(let value):
            return value
        default:
            return nil
        }
    }

    var arrayValue: [JSONValue]? {
        switch self {
        case .array(let value):
            return value
        default:
            return nil
        }
    }

    var objectValue: [String: JSONValue]? {
        switch self {
        case .object(let value):
            return value
        default:
            return nil
        }
    }
}
