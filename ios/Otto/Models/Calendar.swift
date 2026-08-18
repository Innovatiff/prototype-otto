// GENERATED FROM shared/schemas — DO NOT EDIT
//
// Source: shared/schemas/calendar.ts
// Regenerate with `npm run codegen`.
//
// Requires this app-target build setting:
//   SWIFT_DEFAULT_ACTOR_ISOLATION = nonisolated
//
// Under MainActor-by-default isolation these Codable conformances cannot
// compile: a main-actor-isolated initializer cannot satisfy the nonisolated
// `init(from:)` requirement.

import Foundation

struct CalendarEvent: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var title: String
    var startsAt: Date
    var endsAt: Date
    var isAllDay: Bool
    var location: String?
    var notes: String?

    init(
        id: String,
        title: String,
        startsAt: Date,
        endsAt: Date,
        isAllDay: Bool = false,
        location: String? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.title = title
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.isAllDay = isAllDay
        self.location = location
        self.notes = notes
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case startsAt
        case endsAt
        case isAllDay
        case location
        case notes
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.title = try container.decode(String.self, forKey: .title)
        self.startsAt = try container.decode(Date.self, forKey: .startsAt)
        self.endsAt = try container.decode(Date.self, forKey: .endsAt)
        self.isAllDay = try container.decodeIfPresent(Bool.self, forKey: .isAllDay) ?? false
        self.location = try container.decodeIfPresent(String.self, forKey: .location)
        self.notes = try container.decodeIfPresent(String.self, forKey: .notes)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .id)
        try container.encode(self.title, forKey: .title)
        try container.encode(self.startsAt, forKey: .startsAt)
        try container.encode(self.endsAt, forKey: .endsAt)
        try container.encode(self.isAllDay, forKey: .isAllDay)
        try container.encodeIfPresent(self.location, forKey: .location)
        try container.encodeIfPresent(self.notes, forKey: .notes)
    }
}

enum CalendarProposal: Codable, Hashable, Sendable {
    case create(draft: EventDraft)
    case move(eventTitle: String, newStartsAt: Date, newEndsAt: Date?)

    private enum CodingKeys: String, CodingKey {
        case kind
        case draft
        case eventTitle
        case newStartsAt
        case newEndsAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let discriminator = try container.decode(String.self, forKey: .kind)
        switch discriminator {
        case "create":
            let draft = try container.decode(EventDraft.self, forKey: .draft)
            self = .create(draft: draft)
        case "move":
            let eventTitle = try container.decode(String.self, forKey: .eventTitle)
            let newStartsAt = try container.decode(Date.self, forKey: .newStartsAt)
            let newEndsAt = try container.decode(Date.self, forKey: .newEndsAt)
            self = .move(eventTitle: eventTitle, newStartsAt: newStartsAt, newEndsAt: newEndsAt)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unknown CalendarProposal kind \(discriminator.debugDescription)."
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .create(let draft):
            try container.encode("create", forKey: .kind)
            try container.encode(draft, forKey: .draft)
        case .move(let eventTitle, let newStartsAt, let newEndsAt):
            try container.encode("move", forKey: .kind)
            try container.encode(eventTitle, forKey: .eventTitle)
            try container.encode(newStartsAt, forKey: .newStartsAt)
            try container.encode(newEndsAt, forKey: .newEndsAt)
        }
    }
}

struct Conflict: Codable, Hashable, Sendable {
    var eventA: CalendarEvent
    var eventB: CalendarEvent
    var kind: ConflictKind
    var minutesShort: Int

    init(
        eventA: CalendarEvent,
        eventB: CalendarEvent,
        kind: ConflictKind,
        minutesShort: Int
    ) {
        self.eventA = eventA
        self.eventB = eventB
        self.kind = kind
        self.minutesShort = minutesShort
    }

    private enum CodingKeys: String, CodingKey {
        case eventA
        case eventB
        case kind
        case minutesShort
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.eventA = try container.decode(CalendarEvent.self, forKey: .eventA)
        self.eventB = try container.decode(CalendarEvent.self, forKey: .eventB)
        self.kind = try container.decode(ConflictKind.self, forKey: .kind)
        self.minutesShort = try container.decode(Int.self, forKey: .minutesShort)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.eventA, forKey: .eventA)
        try container.encode(self.eventB, forKey: .eventB)
        try container.encode(self.kind, forKey: .kind)
        try container.encode(self.minutesShort, forKey: .minutesShort)
    }
}

enum ConflictKind: String, Codable, Hashable, Sendable, CaseIterable {
    case overlap
    case travel
}

struct EventDraft: Codable, Hashable, Sendable {
    var title: String
    var startsAt: Date
    var endsAt: Date
    var location: String?
    var notes: String?

    init(
        title: String,
        startsAt: Date,
        endsAt: Date,
        location: String? = nil,
        notes: String? = nil
    ) {
        self.title = title
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.location = location
        self.notes = notes
    }

    private enum CodingKeys: String, CodingKey {
        case title
        case startsAt
        case endsAt
        case location
        case notes
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.title = try container.decode(String.self, forKey: .title)
        self.startsAt = try container.decode(Date.self, forKey: .startsAt)
        self.endsAt = try container.decode(Date.self, forKey: .endsAt)
        self.location = try container.decodeIfPresent(String.self, forKey: .location)
        self.notes = try container.decodeIfPresent(String.self, forKey: .notes)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.title, forKey: .title)
        try container.encode(self.startsAt, forKey: .startsAt)
        try container.encode(self.endsAt, forKey: .endsAt)
        try container.encodeIfPresent(self.location, forKey: .location)
        try container.encodeIfPresent(self.notes, forKey: .notes)
    }
}
