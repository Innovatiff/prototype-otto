// GENERATED FROM shared/schemas — DO NOT EDIT
//
// Source: shared/schemas/stage.ts
// Regenerate with `npm run codegen`.
//
// Requires this app-target build setting:
//   SWIFT_DEFAULT_ACTOR_ISOLATION = nonisolated
//
// Under MainActor-by-default isolation these Codable conformances cannot
// compile: a main-actor-isolated initializer cannot satisfy the nonisolated
// `init(from:)` requirement.

import Foundation

struct StageVisual: Codable, Hashable, Sendable {
    var kind: StageVisualKind
    var label: String?
    var detail: String?
    var weather: CurrentWeather?
    var dueTasks: [BriefDueTask]?
    var lists: [BriefListCount]?
    var planSessions: [BriefPlanSession]?

    init(
        kind: StageVisualKind,
        label: String? = nil,
        detail: String? = nil,
        weather: CurrentWeather? = nil,
        dueTasks: [BriefDueTask]? = nil,
        lists: [BriefListCount]? = nil,
        planSessions: [BriefPlanSession]? = nil
    ) {
        self.kind = kind
        self.label = label
        self.detail = detail
        self.weather = weather
        self.dueTasks = dueTasks
        self.lists = lists
        self.planSessions = planSessions
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case label
        case detail
        case weather
        case dueTasks
        case lists
        case planSessions
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.kind = try container.decode(StageVisualKind.self, forKey: .kind)
        self.label = try container.decodeIfPresent(String.self, forKey: .label)
        self.detail = try container.decodeIfPresent(String.self, forKey: .detail)
        self.weather = try container.decodeIfPresent(CurrentWeather.self, forKey: .weather)
        self.dueTasks = try container.decodeIfPresent([BriefDueTask].self, forKey: .dueTasks)
        self.lists = try container.decodeIfPresent([BriefListCount].self, forKey: .lists)
        self.planSessions = try container.decodeIfPresent([BriefPlanSession].self, forKey: .planSessions)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.kind, forKey: .kind)
        try container.encodeIfPresent(self.label, forKey: .label)
        try container.encodeIfPresent(self.detail, forKey: .detail)
        try container.encodeIfPresent(self.weather, forKey: .weather)
        try container.encodeIfPresent(self.dueTasks, forKey: .dueTasks)
        try container.encodeIfPresent(self.lists, forKey: .lists)
        try container.encodeIfPresent(self.planSessions, forKey: .planSessions)
    }
}

enum StageVisualKind: String, Codable, Hashable, Sendable, CaseIterable {
    case weather
    case calendar
    case reminders
    case plans
    case building
    case automation
}
