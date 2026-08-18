// GENERATED FROM shared/schemas — DO NOT EDIT
//
// Source: shared/schemas/turn.ts
// Regenerate with `npm run codegen`.
//
// Requires this app-target build setting:
//   SWIFT_DEFAULT_ACTOR_ISOLATION = nonisolated
//
// Under MainActor-by-default isolation these Codable conformances cannot
// compile: a main-actor-isolated initializer cannot satisfy the nonisolated
// `init(from:)` requirement.

import Foundation

struct TurnEvent: Codable, Hashable, Sendable {
    var type: TurnEventType
    var data: JSONValue?

    init(
        type: TurnEventType,
        data: JSONValue? = nil
    ) {
        self.type = type
        self.data = data
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case data
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decode(TurnEventType.self, forKey: .type)
        if container.contains(.data) {
            self.data = try container.decode(JSONValue.self, forKey: .data)
        } else {
            self.data = nil
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.type, forKey: .type)
        try container.encodeIfPresent(self.data, forKey: .data)
    }
}

enum TurnEventType: String, Codable, Hashable, Sendable, CaseIterable {
    case token
    /// Wire value: `"task_created"`.
    case taskCreated = "task_created"
    /// Wire value: `"task_updated"`.
    case taskUpdated = "task_updated"
    case draft
    /// Wire value: `"calendar_proposal"`.
    case calendarProposal = "calendar_proposal"
    case done
    case error
}

struct TurnRequest: Codable, Hashable, Sendable {
    var turnId: String
    var text: String
    var clientTimestamp: Date
    var timezone: String
    var sessionId: String?
    var events: [CalendarEvent]?

    init(
        turnId: String,
        text: String,
        clientTimestamp: Date,
        timezone: String,
        sessionId: String? = nil,
        events: [CalendarEvent]? = nil
    ) {
        self.turnId = turnId
        self.text = text
        self.clientTimestamp = clientTimestamp
        self.timezone = timezone
        self.sessionId = sessionId
        self.events = events
    }

    private enum CodingKeys: String, CodingKey {
        case turnId
        case text
        case clientTimestamp
        case timezone
        case sessionId
        case events
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.turnId = try container.decode(String.self, forKey: .turnId)
        self.text = try container.decode(String.self, forKey: .text)
        self.clientTimestamp = try container.decode(Date.self, forKey: .clientTimestamp)
        self.timezone = try container.decode(String.self, forKey: .timezone)
        self.sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        self.events = try container.decodeIfPresent([CalendarEvent].self, forKey: .events)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.turnId, forKey: .turnId)
        try container.encode(self.text, forKey: .text)
        try container.encode(self.clientTimestamp, forKey: .clientTimestamp)
        try container.encode(self.timezone, forKey: .timezone)
        try container.encodeIfPresent(self.sessionId, forKey: .sessionId)
        try container.encodeIfPresent(self.events, forKey: .events)
    }
}
