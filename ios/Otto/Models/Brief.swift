// GENERATED FROM shared/schemas — DO NOT EDIT
//
// Source: shared/schemas/brief.ts
// Regenerate with `npm run codegen`.
//
// Requires this app-target build setting:
//   SWIFT_DEFAULT_ACTOR_ISOLATION = nonisolated
//
// Under MainActor-by-default isolation these Codable conformances cannot
// compile: a main-actor-isolated initializer cannot satisfy the nonisolated
// `init(from:)` requirement.

import Foundation

struct BriefCard: Codable, Hashable, Sendable {
    var date: String
    var weather: CurrentWeather?
    var events: [CalendarEvent]
    var conflicts: [Conflict]
    var dueTasks: [BriefDueTask]
    var lists: [BriefListCount]

    init(
        date: String,
        weather: CurrentWeather? = nil,
        events: [CalendarEvent],
        conflicts: [Conflict],
        dueTasks: [BriefDueTask],
        lists: [BriefListCount]
    ) {
        self.date = date
        self.weather = weather
        self.events = events
        self.conflicts = conflicts
        self.dueTasks = dueTasks
        self.lists = lists
    }

    private enum CodingKeys: String, CodingKey {
        case date
        case weather
        case events
        case conflicts
        case dueTasks
        case lists
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.date = try container.decode(String.self, forKey: .date)
        self.weather = try container.decodeIfPresent(CurrentWeather.self, forKey: .weather)
        self.events = try container.decode([CalendarEvent].self, forKey: .events)
        self.conflicts = try container.decode([Conflict].self, forKey: .conflicts)
        self.dueTasks = try container.decode([BriefDueTask].self, forKey: .dueTasks)
        self.lists = try container.decode([BriefListCount].self, forKey: .lists)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.date, forKey: .date)
        try container.encodeIfPresent(self.weather, forKey: .weather)
        try container.encode(self.events, forKey: .events)
        try container.encode(self.conflicts, forKey: .conflicts)
        try container.encode(self.dueTasks, forKey: .dueTasks)
        try container.encode(self.lists, forKey: .lists)
    }
}

struct BriefDueTask: Codable, Hashable, Sendable {
    var taskId: String
    var title: String
    var at: Date

    init(
        taskId: String,
        title: String,
        at: Date
    ) {
        self.taskId = taskId
        self.title = title
        self.at = at
    }

    private enum CodingKeys: String, CodingKey {
        case taskId
        case title
        case at
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.taskId = try container.decode(String.self, forKey: .taskId)
        self.title = try container.decode(String.self, forKey: .title)
        self.at = try container.decode(Date.self, forKey: .at)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.taskId, forKey: .taskId)
        try container.encode(self.title, forKey: .title)
        try container.encode(self.at, forKey: .at)
    }
}

struct BriefListCount: Codable, Hashable, Sendable {
    var taskId: String
    var title: String
    var context: String?
    var openCount: Int

    init(
        taskId: String,
        title: String,
        context: String? = nil,
        openCount: Int
    ) {
        self.taskId = taskId
        self.title = title
        self.context = context
        self.openCount = openCount
    }

    private enum CodingKeys: String, CodingKey {
        case taskId
        case title
        case context
        case openCount
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.taskId = try container.decode(String.self, forKey: .taskId)
        self.title = try container.decode(String.self, forKey: .title)
        self.context = try container.decodeIfPresent(String.self, forKey: .context)
        self.openCount = try container.decode(Int.self, forKey: .openCount)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.taskId, forKey: .taskId)
        try container.encode(self.title, forKey: .title)
        try container.encodeIfPresent(self.context, forKey: .context)
        try container.encode(self.openCount, forKey: .openCount)
    }
}

struct BriefRecord: Codable, Hashable, Sendable {
    var ownerId: String
    var date: String
    var spoken: String
    var summary: String
    var createdAt: Date

    init(
        ownerId: String,
        date: String,
        spoken: String,
        summary: String,
        createdAt: Date
    ) {
        self.ownerId = ownerId
        self.date = date
        self.spoken = spoken
        self.summary = summary
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case ownerId
        case date
        case spoken
        case summary
        case createdAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.ownerId = try container.decode(String.self, forKey: .ownerId)
        self.date = try container.decode(String.self, forKey: .date)
        self.spoken = try container.decode(String.self, forKey: .spoken)
        self.summary = try container.decode(String.self, forKey: .summary)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.ownerId, forKey: .ownerId)
        try container.encode(self.date, forKey: .date)
        try container.encode(self.spoken, forKey: .spoken)
        try container.encode(self.summary, forKey: .summary)
        try container.encode(self.createdAt, forKey: .createdAt)
    }
}

struct BriefRequest: Codable, Hashable, Sendable {
    var events: [CalendarEvent]
    var conflicts: [Conflict]
    var timezone: String
    var lat: Double?
    var lon: Double?

    init(
        events: [CalendarEvent],
        conflicts: [Conflict],
        timezone: String,
        lat: Double? = nil,
        lon: Double? = nil
    ) {
        self.events = events
        self.conflicts = conflicts
        self.timezone = timezone
        self.lat = lat
        self.lon = lon
    }

    private enum CodingKeys: String, CodingKey {
        case events
        case conflicts
        case timezone
        case lat
        case lon
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.events = try container.decode([CalendarEvent].self, forKey: .events)
        self.conflicts = try container.decode([Conflict].self, forKey: .conflicts)
        self.timezone = try container.decode(String.self, forKey: .timezone)
        self.lat = try container.decodeIfPresent(Double.self, forKey: .lat)
        self.lon = try container.decodeIfPresent(Double.self, forKey: .lon)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.events, forKey: .events)
        try container.encode(self.conflicts, forKey: .conflicts)
        try container.encode(self.timezone, forKey: .timezone)
        try container.encodeIfPresent(self.lat, forKey: .lat)
        try container.encodeIfPresent(self.lon, forKey: .lon)
    }
}

struct BriefResponse: Codable, Hashable, Sendable {
    var spoken: String
    var card: BriefCard

    init(
        spoken: String,
        card: BriefCard
    ) {
        self.spoken = spoken
        self.card = card
    }

    private enum CodingKeys: String, CodingKey {
        case spoken
        case card
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.spoken = try container.decode(String.self, forKey: .spoken)
        self.card = try container.decode(BriefCard.self, forKey: .card)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.spoken, forKey: .spoken)
        try container.encode(self.card, forKey: .card)
    }
}
