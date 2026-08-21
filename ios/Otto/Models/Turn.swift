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

struct GuidanceTurnContext: Codable, Hashable, Sendable {
    var sessionTitle: String
    var stepTitle: String
    var stepCue: String
    var position: String?

    init(
        sessionTitle: String,
        stepTitle: String,
        stepCue: String,
        position: String? = nil
    ) {
        self.sessionTitle = sessionTitle
        self.stepTitle = stepTitle
        self.stepCue = stepCue
        self.position = position
    }

    private enum CodingKeys: String, CodingKey {
        case sessionTitle
        case stepTitle
        case stepCue
        case position
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.sessionTitle = try container.decode(String.self, forKey: .sessionTitle)
        self.stepTitle = try container.decode(String.self, forKey: .stepTitle)
        self.stepCue = try container.decode(String.self, forKey: .stepCue)
        self.position = try container.decodeIfPresent(String.self, forKey: .position)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.sessionTitle, forKey: .sessionTitle)
        try container.encode(self.stepTitle, forKey: .stepTitle)
        try container.encode(self.stepCue, forKey: .stepCue)
        try container.encodeIfPresent(self.position, forKey: .position)
    }
}

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
    /// Wire value: `"plan_progress"`.
    case planProgress = "plan_progress"
    /// Wire value: `"plan_ready"`.
    case planReady = "plan_ready"
    /// Wire value: `"plan_failed"`.
    case planFailed = "plan_failed"
    /// Wire value: `"walkthrough_ready"`.
    case walkthroughReady = "walkthrough_ready"
    /// Wire value: `"experience_ready"`.
    case experienceReady = "experience_ready"
    case stage
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
    var guidance: GuidanceTurnContext?

    init(
        turnId: String,
        text: String,
        clientTimestamp: Date,
        timezone: String,
        sessionId: String? = nil,
        events: [CalendarEvent]? = nil,
        guidance: GuidanceTurnContext? = nil
    ) {
        self.turnId = turnId
        self.text = text
        self.clientTimestamp = clientTimestamp
        self.timezone = timezone
        self.sessionId = sessionId
        self.events = events
        self.guidance = guidance
    }

    private enum CodingKeys: String, CodingKey {
        case turnId
        case text
        case clientTimestamp
        case timezone
        case sessionId
        case events
        case guidance
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.turnId = try container.decode(String.self, forKey: .turnId)
        self.text = try container.decode(String.self, forKey: .text)
        self.clientTimestamp = try container.decode(Date.self, forKey: .clientTimestamp)
        self.timezone = try container.decode(String.self, forKey: .timezone)
        self.sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        self.events = try container.decodeIfPresent([CalendarEvent].self, forKey: .events)
        self.guidance = try container.decodeIfPresent(GuidanceTurnContext.self, forKey: .guidance)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.turnId, forKey: .turnId)
        try container.encode(self.text, forKey: .text)
        try container.encode(self.clientTimestamp, forKey: .clientTimestamp)
        try container.encode(self.timezone, forKey: .timezone)
        try container.encodeIfPresent(self.sessionId, forKey: .sessionId)
        try container.encodeIfPresent(self.events, forKey: .events)
        try container.encodeIfPresent(self.guidance, forKey: .guidance)
    }
}
