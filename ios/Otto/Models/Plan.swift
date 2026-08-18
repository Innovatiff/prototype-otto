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
    var calendarEvents: [PlanCalendarEvent]?
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
        calendarEvents: [PlanCalendarEvent]? = nil,
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
        self.calendarEvents = calendarEvents
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
        case calendarEvents
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
        self.calendarEvents = try container.decodeIfPresent([PlanCalendarEvent].self, forKey: .calendarEvents)
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
        try container.encodeIfPresent(self.calendarEvents, forKey: .calendarEvents)
        try container.encode(self.createdAt, forKey: .createdAt)
    }
}

struct PlanCalendarEvent: Codable, Hashable, Sendable {
    var sessionId: String
    var dayOffset: Int
    var eventId: String

    init(
        sessionId: String,
        dayOffset: Int,
        eventId: String
    ) {
        self.sessionId = sessionId
        self.dayOffset = dayOffset
        self.eventId = eventId
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId
        case dayOffset
        case eventId
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.sessionId = try container.decode(String.self, forKey: .sessionId)
        self.dayOffset = try container.decode(Int.self, forKey: .dayOffset)
        self.eventId = try container.decode(String.self, forKey: .eventId)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.sessionId, forKey: .sessionId)
        try container.encode(self.dayOffset, forKey: .dayOffset)
        try container.encode(self.eventId, forKey: .eventId)
    }
}

struct PlanCalendarEventsRequest: Codable, Hashable, Sendable {
    var events: [PlanCalendarEvent]

    init(
        events: [PlanCalendarEvent]
    ) {
        self.events = events
    }

    private enum CodingKeys: String, CodingKey {
        case events
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.events = try container.decode([PlanCalendarEvent].self, forKey: .events)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.events, forKey: .events)
    }
}

struct PlanListResponse: Codable, Hashable, Sendable {
    var plans: [PlanSummary]

    init(
        plans: [PlanSummary]
    ) {
        self.plans = plans
    }

    private enum CodingKeys: String, CodingKey {
        case plans
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.plans = try container.decode([PlanSummary].self, forKey: .plans)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.plans, forKey: .plans)
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

struct PlanProgressSummary: Codable, Hashable, Sendable {
    var planId: String
    var records: Int
    var scheduledToDate: Int
    var missedToDate: Int
    var missedThisWeek: Int
    var lastCompletedAt: Date?
    var substitutionCandidates: [SubstitutionCandidate]
    var latestLoggedValues: [String: String]

    init(
        planId: String,
        records: Int,
        scheduledToDate: Int,
        missedToDate: Int,
        missedThisWeek: Int,
        lastCompletedAt: Date? = nil,
        substitutionCandidates: [SubstitutionCandidate],
        latestLoggedValues: [String: String]
    ) {
        self.planId = planId
        self.records = records
        self.scheduledToDate = scheduledToDate
        self.missedToDate = missedToDate
        self.missedThisWeek = missedThisWeek
        self.lastCompletedAt = lastCompletedAt
        self.substitutionCandidates = substitutionCandidates
        self.latestLoggedValues = latestLoggedValues
    }

    private enum CodingKeys: String, CodingKey {
        case planId
        case records
        case scheduledToDate
        case missedToDate
        case missedThisWeek
        case lastCompletedAt
        case substitutionCandidates
        case latestLoggedValues
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.planId = try container.decode(String.self, forKey: .planId)
        self.records = try container.decode(Int.self, forKey: .records)
        self.scheduledToDate = try container.decode(Int.self, forKey: .scheduledToDate)
        self.missedToDate = try container.decode(Int.self, forKey: .missedToDate)
        self.missedThisWeek = try container.decode(Int.self, forKey: .missedThisWeek)
        self.lastCompletedAt = try container.decodeIfPresent(Date.self, forKey: .lastCompletedAt)
        self.substitutionCandidates = try container.decode([SubstitutionCandidate].self, forKey: .substitutionCandidates)
        self.latestLoggedValues = try container.decode([String: String].self, forKey: .latestLoggedValues)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.planId, forKey: .planId)
        try container.encode(self.records, forKey: .records)
        try container.encode(self.scheduledToDate, forKey: .scheduledToDate)
        try container.encode(self.missedToDate, forKey: .missedToDate)
        try container.encode(self.missedThisWeek, forKey: .missedThisWeek)
        try container.encodeIfPresent(self.lastCompletedAt, forKey: .lastCompletedAt)
        try container.encode(self.substitutionCandidates, forKey: .substitutionCandidates)
        try container.encode(self.latestLoggedValues, forKey: .latestLoggedValues)
    }
}

enum PlanStatus: String, Codable, Hashable, Sendable, CaseIterable {
    case active
    case superseded
}

struct PlanSummary: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var meta: PlanMeta
    var status: PlanStatus
    var supersedes: String?
    var sessionCount: Int
    var scheduleEntryCount: Int
    var createdAt: Date

    init(
        id: String,
        meta: PlanMeta,
        status: PlanStatus,
        supersedes: String? = nil,
        sessionCount: Int,
        scheduleEntryCount: Int,
        createdAt: Date
    ) {
        self.id = id
        self.meta = meta
        self.status = status
        self.supersedes = supersedes
        self.sessionCount = sessionCount
        self.scheduleEntryCount = scheduleEntryCount
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case meta
        case status
        case supersedes
        case sessionCount
        case scheduleEntryCount
        case createdAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.meta = try container.decode(PlanMeta.self, forKey: .meta)
        self.status = try container.decode(PlanStatus.self, forKey: .status)
        self.supersedes = try container.decodeIfPresent(String.self, forKey: .supersedes)
        self.sessionCount = try container.decode(Int.self, forKey: .sessionCount)
        self.scheduleEntryCount = try container.decode(Int.self, forKey: .scheduleEntryCount)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .id)
        try container.encode(self.meta, forKey: .meta)
        try container.encode(self.status, forKey: .status)
        try container.encodeIfPresent(self.supersedes, forKey: .supersedes)
        try container.encode(self.sessionCount, forKey: .sessionCount)
        try container.encode(self.scheduleEntryCount, forKey: .scheduleEntryCount)
        try container.encode(self.createdAt, forKey: .createdAt)
    }
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

struct SessionRecord: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var ownerId: String
    var planId: String
    var sessionId: String
    var scheduledDate: Date?
    var startedAt: Date
    var completedAt: Date
    var completedSteps: [String]
    var skippedSteps: [String]
    var loggedValues: [String: String]
    var durationSec: Int
    var endedEarly: Bool

    init(
        id: String,
        ownerId: String,
        planId: String,
        sessionId: String,
        scheduledDate: Date? = nil,
        startedAt: Date,
        completedAt: Date,
        completedSteps: [String],
        skippedSteps: [String],
        loggedValues: [String: String],
        durationSec: Int,
        endedEarly: Bool
    ) {
        self.id = id
        self.ownerId = ownerId
        self.planId = planId
        self.sessionId = sessionId
        self.scheduledDate = scheduledDate
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.completedSteps = completedSteps
        self.skippedSteps = skippedSteps
        self.loggedValues = loggedValues
        self.durationSec = durationSec
        self.endedEarly = endedEarly
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case ownerId
        case planId
        case sessionId
        case scheduledDate
        case startedAt
        case completedAt
        case completedSteps
        case skippedSteps
        case loggedValues
        case durationSec
        case endedEarly
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.ownerId = try container.decode(String.self, forKey: .ownerId)
        self.planId = try container.decode(String.self, forKey: .planId)
        self.sessionId = try container.decode(String.self, forKey: .sessionId)
        self.scheduledDate = try container.decodeIfPresent(Date.self, forKey: .scheduledDate)
        self.startedAt = try container.decode(Date.self, forKey: .startedAt)
        self.completedAt = try container.decode(Date.self, forKey: .completedAt)
        self.completedSteps = try container.decode([String].self, forKey: .completedSteps)
        self.skippedSteps = try container.decode([String].self, forKey: .skippedSteps)
        self.loggedValues = try container.decode([String: String].self, forKey: .loggedValues)
        self.durationSec = try container.decode(Int.self, forKey: .durationSec)
        self.endedEarly = try container.decode(Bool.self, forKey: .endedEarly)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .id)
        try container.encode(self.ownerId, forKey: .ownerId)
        try container.encode(self.planId, forKey: .planId)
        try container.encode(self.sessionId, forKey: .sessionId)
        try container.encodeIfPresent(self.scheduledDate, forKey: .scheduledDate)
        try container.encode(self.startedAt, forKey: .startedAt)
        try container.encode(self.completedAt, forKey: .completedAt)
        try container.encode(self.completedSteps, forKey: .completedSteps)
        try container.encode(self.skippedSteps, forKey: .skippedSteps)
        try container.encode(self.loggedValues, forKey: .loggedValues)
        try container.encode(self.durationSec, forKey: .durationSec)
        try container.encode(self.endedEarly, forKey: .endedEarly)
    }
}

struct SessionRecordUpload: Codable, Hashable, Sendable {
    var sessionId: String
    var scheduledDate: Date?
    var startedAt: Date
    var completedAt: Date
    var completedSteps: [String]
    var skippedSteps: [String]
    var loggedValues: [String: String]
    var durationSec: Int
    var endedEarly: Bool

    init(
        sessionId: String,
        scheduledDate: Date? = nil,
        startedAt: Date,
        completedAt: Date,
        completedSteps: [String],
        skippedSteps: [String],
        loggedValues: [String: String],
        durationSec: Int,
        endedEarly: Bool
    ) {
        self.sessionId = sessionId
        self.scheduledDate = scheduledDate
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.completedSteps = completedSteps
        self.skippedSteps = skippedSteps
        self.loggedValues = loggedValues
        self.durationSec = durationSec
        self.endedEarly = endedEarly
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId
        case scheduledDate
        case startedAt
        case completedAt
        case completedSteps
        case skippedSteps
        case loggedValues
        case durationSec
        case endedEarly
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.sessionId = try container.decode(String.self, forKey: .sessionId)
        self.scheduledDate = try container.decodeIfPresent(Date.self, forKey: .scheduledDate)
        self.startedAt = try container.decode(Date.self, forKey: .startedAt)
        self.completedAt = try container.decode(Date.self, forKey: .completedAt)
        self.completedSteps = try container.decode([String].self, forKey: .completedSteps)
        self.skippedSteps = try container.decode([String].self, forKey: .skippedSteps)
        self.loggedValues = try container.decode([String: String].self, forKey: .loggedValues)
        self.durationSec = try container.decode(Int.self, forKey: .durationSec)
        self.endedEarly = try container.decode(Bool.self, forKey: .endedEarly)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.sessionId, forKey: .sessionId)
        try container.encodeIfPresent(self.scheduledDate, forKey: .scheduledDate)
        try container.encode(self.startedAt, forKey: .startedAt)
        try container.encode(self.completedAt, forKey: .completedAt)
        try container.encode(self.completedSteps, forKey: .completedSteps)
        try container.encode(self.skippedSteps, forKey: .skippedSteps)
        try container.encode(self.loggedValues, forKey: .loggedValues)
        try container.encode(self.durationSec, forKey: .durationSec)
        try container.encode(self.endedEarly, forKey: .endedEarly)
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

struct SubstitutionCandidate: Codable, Hashable, Sendable {
    var stepId: String
    var skips: Int

    init(
        stepId: String,
        skips: Int
    ) {
        self.stepId = stepId
        self.skips = skips
    }

    private enum CodingKeys: String, CodingKey {
        case stepId
        case skips
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.stepId = try container.decode(String.self, forKey: .stepId)
        self.skips = try container.decode(Int.self, forKey: .skips)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.stepId, forKey: .stepId)
        try container.encode(self.skips, forKey: .skips)
    }
}
