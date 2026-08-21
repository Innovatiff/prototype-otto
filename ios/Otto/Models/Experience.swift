// GENERATED FROM shared/schemas — DO NOT EDIT
//
// Source: shared/schemas/experience.ts
// Regenerate with `npm run codegen`.
//
// Requires this app-target build setting:
//   SWIFT_DEFAULT_ACTOR_ISOLATION = nonisolated
//
// Under MainActor-by-default isolation these Codable conformances cannot
// compile: a main-actor-isolated initializer cannot satisfy the nonisolated
// `init(from:)` requirement.

import Foundation

struct Experience: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var ownerId: String
    var kind: ExperienceKind
    var title: String
    var destination: String
    var vibe: String?
    var days: [ExperienceDay]
    var budget: ExperienceBudget
    var chapters: [ExperienceChapter]
    var summary: String
    var createdAt: Date

    init(
        id: String,
        ownerId: String,
        kind: ExperienceKind,
        title: String,
        destination: String,
        vibe: String? = nil,
        days: [ExperienceDay],
        budget: ExperienceBudget,
        chapters: [ExperienceChapter],
        summary: String,
        createdAt: Date
    ) {
        self.id = id
        self.ownerId = ownerId
        self.kind = kind
        self.title = title
        self.destination = destination
        self.vibe = vibe
        self.days = days
        self.budget = budget
        self.chapters = chapters
        self.summary = summary
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case ownerId
        case kind
        case title
        case destination
        case vibe
        case days
        case budget
        case chapters
        case summary
        case createdAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.ownerId = try container.decode(String.self, forKey: .ownerId)
        self.kind = try container.decode(ExperienceKind.self, forKey: .kind)
        self.title = try container.decode(String.self, forKey: .title)
        self.destination = try container.decode(String.self, forKey: .destination)
        self.vibe = try container.decodeIfPresent(String.self, forKey: .vibe)
        self.days = try container.decode([ExperienceDay].self, forKey: .days)
        self.budget = try container.decode(ExperienceBudget.self, forKey: .budget)
        self.chapters = try container.decode([ExperienceChapter].self, forKey: .chapters)
        self.summary = try container.decode(String.self, forKey: .summary)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .id)
        try container.encode(self.ownerId, forKey: .ownerId)
        try container.encode(self.kind, forKey: .kind)
        try container.encode(self.title, forKey: .title)
        try container.encode(self.destination, forKey: .destination)
        try container.encodeIfPresent(self.vibe, forKey: .vibe)
        try container.encode(self.days, forKey: .days)
        try container.encode(self.budget, forKey: .budget)
        try container.encode(self.chapters, forKey: .chapters)
        try container.encode(self.summary, forKey: .summary)
        try container.encode(self.createdAt, forKey: .createdAt)
    }
}

struct ExperienceBudget: Codable, Hashable, Sendable {
    var stated: Int
    var planned: Int
    var buffer: Int
    var currency: String

    init(
        stated: Int,
        planned: Int,
        buffer: Int,
        currency: String
    ) {
        self.stated = stated
        self.planned = planned
        self.buffer = buffer
        self.currency = currency
    }

    private enum CodingKeys: String, CodingKey {
        case stated
        case planned
        case buffer
        case currency
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.stated = try container.decode(Int.self, forKey: .stated)
        self.planned = try container.decode(Int.self, forKey: .planned)
        self.buffer = try container.decode(Int.self, forKey: .buffer)
        self.currency = try container.decode(String.self, forKey: .currency)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.stated, forKey: .stated)
        try container.encode(self.planned, forKey: .planned)
        try container.encode(self.buffer, forKey: .buffer)
        try container.encode(self.currency, forKey: .currency)
    }
}

struct ExperienceChapter: Codable, Hashable, Sendable {
    var kind: ExperienceChapterKind
    var spoken: String

    init(
        kind: ExperienceChapterKind,
        spoken: String
    ) {
        self.kind = kind
        self.spoken = spoken
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case spoken
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.kind = try container.decode(ExperienceChapterKind.self, forKey: .kind)
        self.spoken = try container.decode(String.self, forKey: .spoken)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.kind, forKey: .kind)
        try container.encode(self.spoken, forKey: .spoken)
    }
}

enum ExperienceChapterKind: String, Codable, Hashable, Sendable, CaseIterable {
    case overview
    case stay
    case food
    case activities
    case transport
    case budget
}

struct ExperienceDay: Codable, Hashable, Sendable {
    var label: String
    var items: [ExperienceItem]

    init(
        label: String,
        items: [ExperienceItem]
    ) {
        self.label = label
        self.items = items
    }

    private enum CodingKeys: String, CodingKey {
        case label
        case items
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.label = try container.decode(String.self, forKey: .label)
        self.items = try container.decode([ExperienceItem].self, forKey: .items)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.label, forKey: .label)
        try container.encode(self.items, forKey: .items)
    }
}

struct ExperienceItem: Codable, Hashable, Sendable {
    var kind: ExperienceItemKind
    var title: String
    var note: String?
    var area: String?
    var address: String?
    var startTime: String?
    var durationMin: Int?
    var estCost: Int?

    init(
        kind: ExperienceItemKind,
        title: String,
        note: String? = nil,
        area: String? = nil,
        address: String? = nil,
        startTime: String? = nil,
        durationMin: Int? = nil,
        estCost: Int? = nil
    ) {
        self.kind = kind
        self.title = title
        self.note = note
        self.area = area
        self.address = address
        self.startTime = startTime
        self.durationMin = durationMin
        self.estCost = estCost
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case title
        case note
        case area
        case address
        case startTime
        case durationMin
        case estCost
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.kind = try container.decode(ExperienceItemKind.self, forKey: .kind)
        self.title = try container.decode(String.self, forKey: .title)
        self.note = try container.decodeIfPresent(String.self, forKey: .note)
        self.area = try container.decodeIfPresent(String.self, forKey: .area)
        self.address = try container.decodeIfPresent(String.self, forKey: .address)
        self.startTime = try container.decodeIfPresent(String.self, forKey: .startTime)
        self.durationMin = try container.decodeIfPresent(Int.self, forKey: .durationMin)
        self.estCost = try container.decodeIfPresent(Int.self, forKey: .estCost)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.kind, forKey: .kind)
        try container.encode(self.title, forKey: .title)
        try container.encodeIfPresent(self.note, forKey: .note)
        try container.encodeIfPresent(self.area, forKey: .area)
        try container.encodeIfPresent(self.address, forKey: .address)
        try container.encodeIfPresent(self.startTime, forKey: .startTime)
        try container.encodeIfPresent(self.durationMin, forKey: .durationMin)
        try container.encodeIfPresent(self.estCost, forKey: .estCost)
    }
}

enum ExperienceItemKind: String, Codable, Hashable, Sendable, CaseIterable {
    case stay
    case food
    case activity
    case transport
    case tip
}

enum ExperienceKind: String, Codable, Hashable, Sendable, CaseIterable {
    case trip
    case date
    case outing
}

struct ExperienceListResponse: Codable, Hashable, Sendable {
    var experiences: [ExperienceSummary]

    init(
        experiences: [ExperienceSummary]
    ) {
        self.experiences = experiences
    }

    private enum CodingKeys: String, CodingKey {
        case experiences
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.experiences = try container.decode([ExperienceSummary].self, forKey: .experiences)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.experiences, forKey: .experiences)
    }
}

struct ExperienceSummary: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var kind: ExperienceKind
    var title: String
    var destination: String
    var vibe: String?
    var dayCount: Int
    var budget: ExperienceBudget
    var summary: String
    var createdAt: Date

    init(
        id: String,
        kind: ExperienceKind,
        title: String,
        destination: String,
        vibe: String? = nil,
        dayCount: Int,
        budget: ExperienceBudget,
        summary: String,
        createdAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.destination = destination
        self.vibe = vibe
        self.dayCount = dayCount
        self.budget = budget
        self.summary = summary
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case title
        case destination
        case vibe
        case dayCount
        case budget
        case summary
        case createdAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.kind = try container.decode(ExperienceKind.self, forKey: .kind)
        self.title = try container.decode(String.self, forKey: .title)
        self.destination = try container.decode(String.self, forKey: .destination)
        self.vibe = try container.decodeIfPresent(String.self, forKey: .vibe)
        self.dayCount = try container.decode(Int.self, forKey: .dayCount)
        self.budget = try container.decode(ExperienceBudget.self, forKey: .budget)
        self.summary = try container.decode(String.self, forKey: .summary)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .id)
        try container.encode(self.kind, forKey: .kind)
        try container.encode(self.title, forKey: .title)
        try container.encode(self.destination, forKey: .destination)
        try container.encodeIfPresent(self.vibe, forKey: .vibe)
        try container.encode(self.dayCount, forKey: .dayCount)
        try container.encode(self.budget, forKey: .budget)
        try container.encode(self.summary, forKey: .summary)
        try container.encode(self.createdAt, forKey: .createdAt)
    }
}
