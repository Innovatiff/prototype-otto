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
    var planSessions: [BriefPlanSession]?

    init(
        date: String,
        weather: CurrentWeather? = nil,
        events: [CalendarEvent],
        conflicts: [Conflict],
        dueTasks: [BriefDueTask],
        lists: [BriefListCount],
        planSessions: [BriefPlanSession]? = nil
    ) {
        self.date = date
        self.weather = weather
        self.events = events
        self.conflicts = conflicts
        self.dueTasks = dueTasks
        self.lists = lists
        self.planSessions = planSessions
    }

    private enum CodingKeys: String, CodingKey {
        case date
        case weather
        case events
        case conflicts
        case dueTasks
        case lists
        case planSessions
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.date = try container.decode(String.self, forKey: .date)
        self.weather = try container.decodeIfPresent(CurrentWeather.self, forKey: .weather)
        self.events = try container.decode([CalendarEvent].self, forKey: .events)
        self.conflicts = try container.decode([Conflict].self, forKey: .conflicts)
        self.dueTasks = try container.decode([BriefDueTask].self, forKey: .dueTasks)
        self.lists = try container.decode([BriefListCount].self, forKey: .lists)
        self.planSessions = try container.decodeIfPresent([BriefPlanSession].self, forKey: .planSessions)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.date, forKey: .date)
        try container.encodeIfPresent(self.weather, forKey: .weather)
        try container.encode(self.events, forKey: .events)
        try container.encode(self.conflicts, forKey: .conflicts)
        try container.encode(self.dueTasks, forKey: .dueTasks)
        try container.encode(self.lists, forKey: .lists)
        try container.encodeIfPresent(self.planSessions, forKey: .planSessions)
    }
}

struct BriefChapter: Codable, Hashable, Sendable {
    var kind: BriefChapterKind
    var spoken: String

    init(
        kind: BriefChapterKind,
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
        self.kind = try container.decode(BriefChapterKind.self, forKey: .kind)
        self.spoken = try container.decode(String.self, forKey: .spoken)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.kind, forKey: .kind)
        try container.encode(self.spoken, forKey: .spoken)
    }
}

enum BriefChapterKind: String, Codable, Hashable, Sendable, CaseIterable {
    case intro
    case weather
    case calendar
    case plans
    case reminders
    case outro
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

enum BriefMode: String, Codable, Hashable, Sendable, CaseIterable {
    case morning
    case evening
    case weekly
}

struct BriefPlanSession: Codable, Hashable, Sendable {
    var planId: String
    var sessionId: String
    var sessionTitle: String
    var domain: String
    var week: Int
    var timeOfDay: String?
    var completed: Bool

    init(
        planId: String,
        sessionId: String,
        sessionTitle: String,
        domain: String,
        week: Int,
        timeOfDay: String? = nil,
        completed: Bool
    ) {
        self.planId = planId
        self.sessionId = sessionId
        self.sessionTitle = sessionTitle
        self.domain = domain
        self.week = week
        self.timeOfDay = timeOfDay
        self.completed = completed
    }

    private enum CodingKeys: String, CodingKey {
        case planId
        case sessionId
        case sessionTitle
        case domain
        case week
        case timeOfDay
        case completed
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.planId = try container.decode(String.self, forKey: .planId)
        self.sessionId = try container.decode(String.self, forKey: .sessionId)
        self.sessionTitle = try container.decode(String.self, forKey: .sessionTitle)
        self.domain = try container.decode(String.self, forKey: .domain)
        self.week = try container.decode(Int.self, forKey: .week)
        self.timeOfDay = try container.decodeIfPresent(String.self, forKey: .timeOfDay)
        self.completed = try container.decode(Bool.self, forKey: .completed)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.planId, forKey: .planId)
        try container.encode(self.sessionId, forKey: .sessionId)
        try container.encode(self.sessionTitle, forKey: .sessionTitle)
        try container.encode(self.domain, forKey: .domain)
        try container.encode(self.week, forKey: .week)
        try container.encodeIfPresent(self.timeOfDay, forKey: .timeOfDay)
        try container.encode(self.completed, forKey: .completed)
    }
}

struct BriefRecord: Codable, Hashable, Sendable {
    var ownerId: String
    var date: String
    var spoken: String
    var summary: String
    var createdAt: Date
    var chapters: [BriefChapter]?
    var card: BriefCard?

    init(
        ownerId: String,
        date: String,
        spoken: String,
        summary: String,
        createdAt: Date,
        chapters: [BriefChapter]? = nil,
        card: BriefCard? = nil
    ) {
        self.ownerId = ownerId
        self.date = date
        self.spoken = spoken
        self.summary = summary
        self.createdAt = createdAt
        self.chapters = chapters
        self.card = card
    }

    private enum CodingKeys: String, CodingKey {
        case ownerId
        case date
        case spoken
        case summary
        case createdAt
        case chapters
        case card
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.ownerId = try container.decode(String.self, forKey: .ownerId)
        self.date = try container.decode(String.self, forKey: .date)
        self.spoken = try container.decode(String.self, forKey: .spoken)
        self.summary = try container.decode(String.self, forKey: .summary)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.chapters = try container.decodeIfPresent([BriefChapter].self, forKey: .chapters)
        self.card = try container.decodeIfPresent(BriefCard.self, forKey: .card)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.ownerId, forKey: .ownerId)
        try container.encode(self.date, forKey: .date)
        try container.encode(self.spoken, forKey: .spoken)
        try container.encode(self.summary, forKey: .summary)
        try container.encode(self.createdAt, forKey: .createdAt)
        try container.encodeIfPresent(self.chapters, forKey: .chapters)
        try container.encodeIfPresent(self.card, forKey: .card)
    }
}

struct BriefRequest: Codable, Hashable, Sendable {
    var events: [CalendarEvent]
    var conflicts: [Conflict]
    var timezone: String
    var lat: Double?
    var lon: Double?
    var mode: BriefMode?

    init(
        events: [CalendarEvent],
        conflicts: [Conflict],
        timezone: String,
        lat: Double? = nil,
        lon: Double? = nil,
        mode: BriefMode? = nil
    ) {
        self.events = events
        self.conflicts = conflicts
        self.timezone = timezone
        self.lat = lat
        self.lon = lon
        self.mode = mode
    }

    private enum CodingKeys: String, CodingKey {
        case events
        case conflicts
        case timezone
        case lat
        case lon
        case mode
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.events = try container.decode([CalendarEvent].self, forKey: .events)
        self.conflicts = try container.decode([Conflict].self, forKey: .conflicts)
        self.timezone = try container.decode(String.self, forKey: .timezone)
        self.lat = try container.decodeIfPresent(Double.self, forKey: .lat)
        self.lon = try container.decodeIfPresent(Double.self, forKey: .lon)
        self.mode = try container.decodeIfPresent(BriefMode.self, forKey: .mode)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.events, forKey: .events)
        try container.encode(self.conflicts, forKey: .conflicts)
        try container.encode(self.timezone, forKey: .timezone)
        try container.encodeIfPresent(self.lat, forKey: .lat)
        try container.encodeIfPresent(self.lon, forKey: .lon)
        try container.encodeIfPresent(self.mode, forKey: .mode)
    }
}

struct BriefResponse: Codable, Hashable, Sendable {
    var spoken: String
    var card: BriefCard
    var chapters: [BriefChapter]?

    init(
        spoken: String,
        card: BriefCard,
        chapters: [BriefChapter]? = nil
    ) {
        self.spoken = spoken
        self.card = card
        self.chapters = chapters
    }

    private enum CodingKeys: String, CodingKey {
        case spoken
        case card
        case chapters
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.spoken = try container.decode(String.self, forKey: .spoken)
        self.card = try container.decode(BriefCard.self, forKey: .card)
        self.chapters = try container.decodeIfPresent([BriefChapter].self, forKey: .chapters)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.spoken, forKey: .spoken)
        try container.encode(self.card, forKey: .card)
        try container.encodeIfPresent(self.chapters, forKey: .chapters)
    }
}
