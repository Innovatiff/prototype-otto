// GENERATED FROM shared/schemas — DO NOT EDIT
//
// Source: shared/schemas/automation.ts
// Regenerate with `npm run codegen`.
//
// Requires this app-target build setting:
//   SWIFT_DEFAULT_ACTOR_ISOLATION = nonisolated
//
// Under MainActor-by-default isolation these Codable conformances cannot
// compile: a main-actor-isolated initializer cannot satisfy the nonisolated
// `init(from:)` requirement.

import Foundation

struct Automation: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var ownerId: String
    var type: AutomationType
    var label: String
    var enabled: Bool
    var schedule: AutomationSchedule
    var timezone: String
    var action: AutomationAction
    var lastRunAt: Date?
    var nextRunAt: Date?
    var lastResult: AutomationRunResult?
    var createdAt: Date

    init(
        id: String,
        ownerId: String,
        type: AutomationType,
        label: String,
        enabled: Bool,
        schedule: AutomationSchedule,
        timezone: String,
        action: AutomationAction,
        lastRunAt: Date? = nil,
        nextRunAt: Date? = nil,
        lastResult: AutomationRunResult? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.ownerId = ownerId
        self.type = type
        self.label = label
        self.enabled = enabled
        self.schedule = schedule
        self.timezone = timezone
        self.action = action
        self.lastRunAt = lastRunAt
        self.nextRunAt = nextRunAt
        self.lastResult = lastResult
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case ownerId
        case type
        case label
        case enabled
        case schedule
        case timezone
        case action
        case lastRunAt
        case nextRunAt
        case lastResult
        case createdAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.ownerId = try container.decode(String.self, forKey: .ownerId)
        self.type = try container.decode(AutomationType.self, forKey: .type)
        self.label = try container.decode(String.self, forKey: .label)
        self.enabled = try container.decode(Bool.self, forKey: .enabled)
        self.schedule = try container.decode(AutomationSchedule.self, forKey: .schedule)
        self.timezone = try container.decode(String.self, forKey: .timezone)
        self.action = try container.decode(AutomationAction.self, forKey: .action)
        self.lastRunAt = try container.decodeIfPresent(Date.self, forKey: .lastRunAt)
        self.nextRunAt = try container.decodeIfPresent(Date.self, forKey: .nextRunAt)
        self.lastResult = try container.decodeIfPresent(AutomationRunResult.self, forKey: .lastResult)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .id)
        try container.encode(self.ownerId, forKey: .ownerId)
        try container.encode(self.type, forKey: .type)
        try container.encode(self.label, forKey: .label)
        try container.encode(self.enabled, forKey: .enabled)
        try container.encode(self.schedule, forKey: .schedule)
        try container.encode(self.timezone, forKey: .timezone)
        try container.encode(self.action, forKey: .action)
        try container.encodeIfPresent(self.lastRunAt, forKey: .lastRunAt)
        try container.encodeIfPresent(self.nextRunAt, forKey: .nextRunAt)
        try container.encodeIfPresent(self.lastResult, forKey: .lastResult)
        try container.encode(self.createdAt, forKey: .createdAt)
    }
}

struct AutomationAction: Codable, Hashable, Sendable {
    var kind: String
    var params: [String: JSONValue]

    init(
        kind: String,
        params: [String: JSONValue] = [:]
    ) {
        self.kind = kind
        self.params = params
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case params
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.kind = try container.decode(String.self, forKey: .kind)
        self.params = try container.decodeIfPresent([String: JSONValue].self, forKey: .params) ?? [:]
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.kind, forKey: .kind)
        try container.encode(self.params, forKey: .params)
    }
}

struct AutomationEventFilter: Codable, Hashable, Sendable {
    var minAttendees: Int?
    var keywords: [String]?

    init(
        minAttendees: Int? = nil,
        keywords: [String]? = nil
    ) {
        self.minAttendees = minAttendees
        self.keywords = keywords
    }

    private enum CodingKeys: String, CodingKey {
        case minAttendees
        case keywords
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.minAttendees = try container.decodeIfPresent(Int.self, forKey: .minAttendees)
        self.keywords = try container.decodeIfPresent([String].self, forKey: .keywords)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(self.minAttendees, forKey: .minAttendees)
        try container.encodeIfPresent(self.keywords, forKey: .keywords)
    }
}

enum AutomationRunResult: String, Codable, Hashable, Sendable, CaseIterable {
    case delivered
    case suppressed
    case failed
}

enum AutomationSchedule: Codable, Hashable, Sendable {
    case fixed(rrule: String, timeOfDay: String)
    case relativeToEvent(minutesBefore: Int, eventFilter: AutomationEventFilter)

    private enum CodingKeys: String, CodingKey {
        case kind
        case rrule
        case timeOfDay
        case minutesBefore
        case eventFilter
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let discriminator = try container.decode(String.self, forKey: .kind)
        switch discriminator {
        case "fixed":
            let rrule = try container.decode(String.self, forKey: .rrule)
            let timeOfDay = try container.decode(String.self, forKey: .timeOfDay)
            self = .fixed(rrule: rrule, timeOfDay: timeOfDay)
        case "relative_to_event":
            let minutesBefore = try container.decode(Int.self, forKey: .minutesBefore)
            let eventFilter = try container.decode(AutomationEventFilter.self, forKey: .eventFilter)
            self = .relativeToEvent(minutesBefore: minutesBefore, eventFilter: eventFilter)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unknown AutomationSchedule kind \(discriminator.debugDescription)."
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .fixed(let rrule, let timeOfDay):
            try container.encode("fixed", forKey: .kind)
            try container.encode(rrule, forKey: .rrule)
            try container.encode(timeOfDay, forKey: .timeOfDay)
        case .relativeToEvent(let minutesBefore, let eventFilter):
            try container.encode("relative_to_event", forKey: .kind)
            try container.encode(minutesBefore, forKey: .minutesBefore)
            try container.encode(eventFilter, forKey: .eventFilter)
        }
    }
}

enum AutomationType: String, Codable, Hashable, Sendable, CaseIterable {
    /// Wire value: `"morning_brief"`.
    case morningBrief = "morning_brief"
    /// Wire value: `"evening_shutdown"`.
    case eveningShutdown = "evening_shutdown"
    /// Wire value: `"weekly_review"`.
    case weeklyReview = "weekly_review"
    /// Wire value: `"meeting_prep"`.
    case meetingPrep = "meeting_prep"
    /// Wire value: `"plan_checkin"`.
    case planCheckin = "plan_checkin"
    case custom
}

enum DeliveryAction: String, Codable, Hashable, Sendable, CaseIterable {
    case opened
    case snoozed
    case dismissed
}

struct DeliveryResponseRequest: Codable, Hashable, Sendable {
    var deliveryId: String
    var action: DeliveryAction

    init(
        deliveryId: String,
        action: DeliveryAction
    ) {
        self.deliveryId = deliveryId
        self.action = action
    }

    private enum CodingKeys: String, CodingKey {
        case deliveryId
        case action
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.deliveryId = try container.decode(String.self, forKey: .deliveryId)
        self.action = try container.decode(DeliveryAction.self, forKey: .action)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.deliveryId, forKey: .deliveryId)
        try container.encode(self.action, forKey: .action)
    }
}

struct DeviceTokenRequest: Codable, Hashable, Sendable {
    var token: String

    init(
        token: String
    ) {
        self.token = token
    }

    private enum CodingKeys: String, CodingKey {
        case token
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.token = try container.decode(String.self, forKey: .token)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.token, forKey: .token)
    }
}
