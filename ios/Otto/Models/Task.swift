// GENERATED FROM shared/schemas — DO NOT EDIT
//
// Source: shared/schemas/task.ts
// Regenerate with `npm run codegen`.
//
// Requires this app-target build setting:
//   SWIFT_DEFAULT_ACTOR_ISOLATION = nonisolated
//
// Under MainActor-by-default isolation these Codable conformances cannot
// compile: a main-actor-isolated initializer cannot satisfy the nonisolated
// `init(from:)` requirement.

import Foundation

struct ListItem: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var text: String
    var checked: Bool
    var quantity: String?
    var addedAt: Date

    init(
        id: String,
        text: String,
        checked: Bool = false,
        quantity: String? = nil,
        addedAt: Date
    ) {
        self.id = id
        self.text = text
        self.checked = checked
        self.quantity = quantity
        self.addedAt = addedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case text
        case checked
        case quantity
        case addedAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.text = try container.decode(String.self, forKey: .text)
        self.checked = try container.decodeIfPresent(Bool.self, forKey: .checked) ?? false
        self.quantity = try container.decodeIfPresent(String.self, forKey: .quantity)
        self.addedAt = try container.decode(Date.self, forKey: .addedAt)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .id)
        try container.encode(self.text, forKey: .text)
        try container.encode(self.checked, forKey: .checked)
        try container.encodeIfPresent(self.quantity, forKey: .quantity)
        try container.encode(self.addedAt, forKey: .addedAt)
    }
}

struct OttoTask: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var ownerId: String
    var intent: TaskIntent
    var title: String
    var items: [ListItem]
    var context: String?
    var body: String?
    var recipient: String?
    var trigger: Trigger
    var verification: Verification
    var status: TaskStatus
    var sourcePlanId: String?
    var createdAt: Date
    var completedAt: Date?

    init(
        id: String,
        ownerId: String,
        intent: TaskIntent,
        title: String,
        items: [ListItem] = [],
        context: String? = nil,
        body: String? = nil,
        recipient: String? = nil,
        trigger: Trigger,
        verification: Verification,
        status: TaskStatus,
        sourcePlanId: String? = nil,
        createdAt: Date,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.ownerId = ownerId
        self.intent = intent
        self.title = title
        self.items = items
        self.context = context
        self.body = body
        self.recipient = recipient
        self.trigger = trigger
        self.verification = verification
        self.status = status
        self.sourcePlanId = sourcePlanId
        self.createdAt = createdAt
        self.completedAt = completedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case ownerId
        case intent
        case title
        case items
        case context
        case body
        case recipient
        case trigger
        case verification
        case status
        case sourcePlanId
        case createdAt
        case completedAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.ownerId = try container.decode(String.self, forKey: .ownerId)
        self.intent = try container.decode(TaskIntent.self, forKey: .intent)
        self.title = try container.decode(String.self, forKey: .title)
        self.items = try container.decodeIfPresent([ListItem].self, forKey: .items) ?? []
        self.context = try container.decodeIfPresent(String.self, forKey: .context)
        self.body = try container.decodeIfPresent(String.self, forKey: .body)
        self.recipient = try container.decodeIfPresent(String.self, forKey: .recipient)
        self.trigger = try container.decode(Trigger.self, forKey: .trigger)
        self.verification = try container.decode(Verification.self, forKey: .verification)
        self.status = try container.decode(TaskStatus.self, forKey: .status)
        self.sourcePlanId = try container.decodeIfPresent(String.self, forKey: .sourcePlanId)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .id)
        try container.encode(self.ownerId, forKey: .ownerId)
        try container.encode(self.intent, forKey: .intent)
        try container.encode(self.title, forKey: .title)
        try container.encode(self.items, forKey: .items)
        try container.encodeIfPresent(self.context, forKey: .context)
        try container.encodeIfPresent(self.body, forKey: .body)
        try container.encodeIfPresent(self.recipient, forKey: .recipient)
        try container.encode(self.trigger, forKey: .trigger)
        try container.encode(self.verification, forKey: .verification)
        try container.encode(self.status, forKey: .status)
        try container.encodeIfPresent(self.sourcePlanId, forKey: .sourcePlanId)
        try container.encode(self.createdAt, forKey: .createdAt)
        try container.encodeIfPresent(self.completedAt, forKey: .completedAt)
    }
}

enum TaskIntent: String, Codable, Hashable, Sendable, CaseIterable {
    case reminder
    case list
    case capture
    case message
}

enum TaskStatus: String, Codable, Hashable, Sendable, CaseIterable {
    case active
    case completed
    case dismissed
}

enum Trigger: Codable, Hashable, Sendable {
    /// Wire value: `"none"`.
    case noTrigger
    case time(at: Date)
    case recurring(rrule: String, nextFire: Date)

    private enum CodingKeys: String, CodingKey {
        case type
        case at
        case rrule
        case nextFire
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let typeTag = try container.decode(String.self, forKey: .type)
        switch typeTag {
        case "none":
            self = .noTrigger
        case "time":
            let at = try container.decode(Date.self, forKey: .at)
            self = .time(at: at)
        case "recurring":
            let rrule = try container.decode(String.self, forKey: .rrule)
            let nextFire = try container.decode(Date.self, forKey: .nextFire)
            self = .recurring(rrule: rrule, nextFire: nextFire)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown Trigger type \(typeTag.debugDescription)."
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .noTrigger:
            try container.encode("none", forKey: .type)
        case .time(let at):
            try container.encode("time", forKey: .type)
            try container.encode(at, forKey: .at)
        case .recurring(let rrule, let nextFire):
            try container.encode("recurring", forKey: .type)
            try container.encode(rrule, forKey: .rrule)
            try container.encode(nextFire, forKey: .nextFire)
        }
    }
}

enum Verification: String, Codable, Hashable, Sendable, CaseIterable {
    /// Wire value: `"none"`.
    case noVerification = "none"
    case inline
    /// Wire value: `"voice_confirm"`.
    case voiceConfirm = "voice_confirm"
    /// Wire value: `"system_sheet"`.
    case systemSheet = "system_sheet"
}
