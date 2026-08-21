// GENERATED FROM shared/schemas — DO NOT EDIT
//
// Source: shared/schemas/user.ts
// Regenerate with `npm run codegen`.
//
// Requires this app-target build setting:
//   SWIFT_DEFAULT_ACTOR_ISOLATION = nonisolated
//
// Under MainActor-by-default isolation these Codable conformances cannot
// compile: a main-actor-isolated initializer cannot satisfy the nonisolated
// `init(from:)` requirement.

import Foundation

struct UserProfile: Codable, Hashable, Sendable {
    var ownerId: String
    var addressTerm: String
    var addressTermSet: Bool?
    var createdAt: Date
    var plansCreatedThisMonth: Int?
    var plansCountMonth: String?
    var quietHoursStart: String?
    var quietHoursEnd: String?
    var customAutomationCount: Int?

    init(
        ownerId: String,
        addressTerm: String = "Boss",
        addressTermSet: Bool? = nil,
        createdAt: Date,
        plansCreatedThisMonth: Int? = nil,
        plansCountMonth: String? = nil,
        quietHoursStart: String? = nil,
        quietHoursEnd: String? = nil,
        customAutomationCount: Int? = nil
    ) {
        self.ownerId = ownerId
        self.addressTerm = addressTerm
        self.addressTermSet = addressTermSet
        self.createdAt = createdAt
        self.plansCreatedThisMonth = plansCreatedThisMonth
        self.plansCountMonth = plansCountMonth
        self.quietHoursStart = quietHoursStart
        self.quietHoursEnd = quietHoursEnd
        self.customAutomationCount = customAutomationCount
    }

    private enum CodingKeys: String, CodingKey {
        case ownerId
        case addressTerm
        case addressTermSet
        case createdAt
        case plansCreatedThisMonth
        case plansCountMonth
        case quietHoursStart
        case quietHoursEnd
        case customAutomationCount
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.ownerId = try container.decode(String.self, forKey: .ownerId)
        self.addressTerm = try container.decodeIfPresent(String.self, forKey: .addressTerm) ?? "Boss"
        self.addressTermSet = try container.decodeIfPresent(Bool.self, forKey: .addressTermSet)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.plansCreatedThisMonth = try container.decodeIfPresent(Int.self, forKey: .plansCreatedThisMonth)
        self.plansCountMonth = try container.decodeIfPresent(String.self, forKey: .plansCountMonth)
        self.quietHoursStart = try container.decodeIfPresent(String.self, forKey: .quietHoursStart)
        self.quietHoursEnd = try container.decodeIfPresent(String.self, forKey: .quietHoursEnd)
        self.customAutomationCount = try container.decodeIfPresent(Int.self, forKey: .customAutomationCount)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.ownerId, forKey: .ownerId)
        try container.encode(self.addressTerm, forKey: .addressTerm)
        try container.encodeIfPresent(self.addressTermSet, forKey: .addressTermSet)
        try container.encode(self.createdAt, forKey: .createdAt)
        try container.encodeIfPresent(self.plansCreatedThisMonth, forKey: .plansCreatedThisMonth)
        try container.encodeIfPresent(self.plansCountMonth, forKey: .plansCountMonth)
        try container.encodeIfPresent(self.quietHoursStart, forKey: .quietHoursStart)
        try container.encodeIfPresent(self.quietHoursEnd, forKey: .quietHoursEnd)
        try container.encodeIfPresent(self.customAutomationCount, forKey: .customAutomationCount)
    }
}
