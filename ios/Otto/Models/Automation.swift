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

struct AutomationListResponse: Codable, Hashable, Sendable {
    var automations: [Automation]
    var quietHoursStart: String
    var quietHoursEnd: String
    var suggestions: [AutomationTimeSuggestion]?

    init(
        automations: [Automation],
        quietHoursStart: String,
        quietHoursEnd: String,
        suggestions: [AutomationTimeSuggestion]? = nil
    ) {
        self.automations = automations
        self.quietHoursStart = quietHoursStart
        self.quietHoursEnd = quietHoursEnd
        self.suggestions = suggestions
    }

    private enum CodingKeys: String, CodingKey {
        case automations
        case quietHoursStart
        case quietHoursEnd
        case suggestions
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.automations = try container.decode([Automation].self, forKey: .automations)
        self.quietHoursStart = try container.decode(String.self, forKey: .quietHoursStart)
        self.quietHoursEnd = try container.decode(String.self, forKey: .quietHoursEnd)
        self.suggestions = try container.decodeIfPresent([AutomationTimeSuggestion].self, forKey: .suggestions)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.automations, forKey: .automations)
        try container.encode(self.quietHoursStart, forKey: .quietHoursStart)
        try container.encode(self.quietHoursEnd, forKey: .quietHoursEnd)
        try container.encodeIfPresent(self.suggestions, forKey: .suggestions)
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

struct AutomationSettingsRequest: Codable, Hashable, Sendable {
    var quietHoursStart: String?
    var quietHoursEnd: String?

    init(
        quietHoursStart: String? = nil,
        quietHoursEnd: String? = nil
    ) {
        self.quietHoursStart = quietHoursStart
        self.quietHoursEnd = quietHoursEnd
    }

    private enum CodingKeys: String, CodingKey {
        case quietHoursStart
        case quietHoursEnd
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.quietHoursStart = try container.decodeIfPresent(String.self, forKey: .quietHoursStart)
        self.quietHoursEnd = try container.decodeIfPresent(String.self, forKey: .quietHoursEnd)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(self.quietHoursStart, forKey: .quietHoursStart)
        try container.encodeIfPresent(self.quietHoursEnd, forKey: .quietHoursEnd)
    }
}

struct AutomationTimeSuggestion: Codable, Hashable, Sendable {
    var automationId: String
    var suggestedTime: String
    var opensAround: String

    init(
        automationId: String,
        suggestedTime: String,
        opensAround: String
    ) {
        self.automationId = automationId
        self.suggestedTime = suggestedTime
        self.opensAround = opensAround
    }

    private enum CodingKeys: String, CodingKey {
        case automationId
        case suggestedTime
        case opensAround
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.automationId = try container.decode(String.self, forKey: .automationId)
        self.suggestedTime = try container.decode(String.self, forKey: .suggestedTime)
        self.opensAround = try container.decode(String.self, forKey: .opensAround)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.automationId, forKey: .automationId)
        try container.encode(self.suggestedTime, forKey: .suggestedTime)
        try container.encode(self.opensAround, forKey: .opensAround)
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

struct AutomationUpdateRequest: Codable, Hashable, Sendable {
    var enabled: Bool?
    var timeOfDay: String?

    init(
        enabled: Bool? = nil,
        timeOfDay: String? = nil
    ) {
        self.enabled = enabled
        self.timeOfDay = timeOfDay
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case timeOfDay
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
        self.timeOfDay = try container.decodeIfPresent(String.self, forKey: .timeOfDay)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(self.enabled, forKey: .enabled)
        try container.encodeIfPresent(self.timeOfDay, forKey: .timeOfDay)
    }
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
    var timezone: String?

    init(
        token: String,
        timezone: String? = nil
    ) {
        self.token = token
        self.timezone = timezone
    }

    private enum CodingKeys: String, CodingKey {
        case token
        case timezone
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.token = try container.decode(String.self, forKey: .token)
        self.timezone = try container.decodeIfPresent(String.self, forKey: .timezone)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.token, forKey: .token)
        try container.encodeIfPresent(self.timezone, forKey: .timezone)
    }
}
