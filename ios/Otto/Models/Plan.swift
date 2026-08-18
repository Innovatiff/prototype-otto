// GENERATED FROM shared/schemas — DO NOT EDIT
//
// Source: shared/schemas/plan.ts
// Regenerate with `npm run codegen`.
//
// Requires this app-target build setting:
//   SWIFT_DEFAULT_ACTOR_ISOLATION = nonisolated
//
// Under MainActor-by-default isolation these Codable conformances cannot
// compile: a main-actor-isolated initializer cannot satisfy the nonisolated
// `init(from:)` requirement.

import Foundation

struct Plan: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var ownerId: String
    var meta: PlanMeta
    var constraints: [String: JSONValue]
    var schedule: [ScheduledSession]
    var sessions: [Session]
    var status: PlanStatus
    var supersedes: String?
    var createdAt: Date

    init(
        id: String,
        ownerId: String,
        meta: PlanMeta,
        constraints: [String: JSONValue],
        schedule: [ScheduledSession],
        sessions: [Session],
        status: PlanStatus,
        supersedes: String? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.ownerId = ownerId
        self.meta = meta
        self.constraints = constraints
        self.schedule = schedule
        self.sessions = sessions
        self.status = status
        self.supersedes = supersedes
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case ownerId
        case meta
        case constraints
        case schedule
        case sessions
        case status
        case supersedes
        case createdAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.ownerId = try container.decode(String.self, forKey: .ownerId)
        self.meta = try container.decode(PlanMeta.self, forKey: .meta)
        self.constraints = try container.decode([String: JSONValue].self, forKey: .constraints)
        self.schedule = try container.decode([ScheduledSession].self, forKey: .schedule)
        self.sessions = try container.decode([Session].self, forKey: .sessions)
        self.status = try container.decode(PlanStatus.self, forKey: .status)
        self.supersedes = try container.decodeIfPresent(String.self, forKey: .supersedes)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .id)
        try container.encode(self.ownerId, forKey: .ownerId)
        try container.encode(self.meta, forKey: .meta)
        try container.encode(self.constraints, forKey: .constraints)
        try container.encode(self.schedule, forKey: .schedule)
        try container.encode(self.sessions, forKey: .sessions)
        try container.encode(self.status, forKey: .status)
        try container.encodeIfPresent(self.supersedes, forKey: .supersedes)
        try container.encode(self.createdAt, forKey: .createdAt)
    }
}

struct PlanMeta: Codable, Hashable, Sendable {
    var domain: String
    var goal: String
    var horizonDays: Int
    var version: Int

    init(
        domain: String,
        goal: String,
        horizonDays: Int,
        version: Int
    ) {
        self.domain = domain
        self.goal = goal
        self.horizonDays = horizonDays
        self.version = version
    }

    private enum CodingKeys: String, CodingKey {
        case domain
        case goal
        case horizonDays
        case version
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.domain = try container.decode(String.self, forKey: .domain)
        self.goal = try container.decode(String.self, forKey: .goal)
        self.horizonDays = try container.decode(Int.self, forKey: .horizonDays)
        self.version = try container.decode(Int.self, forKey: .version)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.domain, forKey: .domain)
        try container.encode(self.goal, forKey: .goal)
        try container.encode(self.horizonDays, forKey: .horizonDays)
        try container.encode(self.version, forKey: .version)
    }
}

enum PlanStatus: String, Codable, Hashable, Sendable, CaseIterable {
    case active
    case superseded
}

struct Progression: Codable, Hashable, Sendable {
    var loadMultiplier: Double?
    var repsDelta: Int?
    var setsDelta: Int?
    var note: String?

    init(
        loadMultiplier: Double? = nil,
        repsDelta: Int? = nil,
        setsDelta: Int? = nil,
        note: String? = nil
    ) {
        self.loadMultiplier = loadMultiplier
        self.repsDelta = repsDelta
        self.setsDelta = setsDelta
        self.note = note
    }

    private enum CodingKeys: String, CodingKey {
        case loadMultiplier
        case repsDelta
        case setsDelta
        case note
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.loadMultiplier = try container.decodeIfPresent(Double.self, forKey: .loadMultiplier)
        self.repsDelta = try container.decodeIfPresent(Int.self, forKey: .repsDelta)
        self.setsDelta = try container.decodeIfPresent(Int.self, forKey: .setsDelta)
        self.note = try container.decodeIfPresent(String.self, forKey: .note)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(self.loadMultiplier, forKey: .loadMultiplier)
        try container.encodeIfPresent(self.repsDelta, forKey: .repsDelta)
        try container.encodeIfPresent(self.setsDelta, forKey: .setsDelta)
        try container.encodeIfPresent(self.note, forKey: .note)
    }
}

struct ScheduledSession: Codable, Hashable, Sendable {
    var sessionId: String
    var dayOffset: Int
    var timeOfDay: String?
    var progression: Progression?

    init(
        sessionId: String,
        dayOffset: Int,
        timeOfDay: String? = nil,
        progression: Progression? = nil
    ) {
        self.sessionId = sessionId
        self.dayOffset = dayOffset
        self.timeOfDay = timeOfDay
        self.progression = progression
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId
        case dayOffset
        case timeOfDay
        case progression
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.sessionId = try container.decode(String.self, forKey: .sessionId)
        self.dayOffset = try container.decode(Int.self, forKey: .dayOffset)
        self.timeOfDay = try container.decodeIfPresent(String.self, forKey: .timeOfDay)
        self.progression = try container.decodeIfPresent(Progression.self, forKey: .progression)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.sessionId, forKey: .sessionId)
        try container.encode(self.dayOffset, forKey: .dayOffset)
        try container.encodeIfPresent(self.timeOfDay, forKey: .timeOfDay)
        try container.encodeIfPresent(self.progression, forKey: .progression)
    }
}

struct Session: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var title: String
    var estimatedMinutes: Int
    var steps: [Step]

    init(
        id: String,
        title: String,
        estimatedMinutes: Int,
        steps: [Step]
    ) {
        self.id = id
        self.title = title
        self.estimatedMinutes = estimatedMinutes
        self.steps = steps
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case estimatedMinutes
        case steps
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.title = try container.decode(String.self, forKey: .title)
        self.estimatedMinutes = try container.decode(Int.self, forKey: .estimatedMinutes)
        self.steps = try container.decode([Step].self, forKey: .steps)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .id)
        try container.encode(self.title, forKey: .title)
        try container.encode(self.estimatedMinutes, forKey: .estimatedMinutes)
        try container.encode(self.steps, forKey: .steps)
    }
}

struct Step: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var type: StepType
    var title: String
    var cue: String
    var target: StepTarget?
    var mediaUrl: String?
    var completion: StepCompletion

    init(
        id: String,
        type: StepType,
        title: String,
        cue: String,
        target: StepTarget? = nil,
        mediaUrl: String? = nil,
        completion: StepCompletion
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.cue = cue
        self.target = target
        self.mediaUrl = mediaUrl
        self.completion = completion
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case type
        case title
        case cue
        case target
        case mediaUrl
        case completion
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.type = try container.decode(StepType.self, forKey: .type)
        self.title = try container.decode(String.self, forKey: .title)
        self.cue = try container.decode(String.self, forKey: .cue)
        self.target = try container.decodeIfPresent(StepTarget.self, forKey: .target)
        self.mediaUrl = try container.decodeIfPresent(String.self, forKey: .mediaUrl)
        self.completion = try container.decode(StepCompletion.self, forKey: .completion)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .id)
        try container.encode(self.type, forKey: .type)
        try container.encode(self.title, forKey: .title)
        try container.encode(self.cue, forKey: .cue)
        try container.encodeIfPresent(self.target, forKey: .target)
        try container.encodeIfPresent(self.mediaUrl, forKey: .mediaUrl)
        try container.encode(self.completion, forKey: .completion)
    }
}

enum StepCompletion: String, Codable, Hashable, Sendable, CaseIterable {
    case auto
    case manual
    case voice
}

struct StepTarget: Codable, Hashable, Sendable {
    var sets: Int?
    var reps: Int?
    var load: Double?
    var durationSec: Int?

    init(
        sets: Int? = nil,
        reps: Int? = nil,
        load: Double? = nil,
        durationSec: Int? = nil
    ) {
        self.sets = sets
        self.reps = reps
        self.load = load
        self.durationSec = durationSec
    }

    private enum CodingKeys: String, CodingKey {
        case sets
        case reps
        case load
        case durationSec
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.sets = try container.decodeIfPresent(Int.self, forKey: .sets)
        self.reps = try container.decodeIfPresent(Int.self, forKey: .reps)
        self.load = try container.decodeIfPresent(Double.self, forKey: .load)
        self.durationSec = try container.decodeIfPresent(Int.self, forKey: .durationSec)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(self.sets, forKey: .sets)
        try container.encodeIfPresent(self.reps, forKey: .reps)
        try container.encodeIfPresent(self.load, forKey: .load)
        try container.encodeIfPresent(self.durationSec, forKey: .durationSec)
    }
}

enum StepType: String, Codable, Hashable, Sendable, CaseIterable {
    case timed
    case counted
    case checklist
    case prompt
}
