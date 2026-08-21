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

enum SubscriptionTierValue: String, Codable, Hashable, Sendable, CaseIterable {
    case free
    case lite
    case pro
    case max
}

struct UserProfile: Codable, Hashable, Sendable {
    var ownerId: String
    var addressTerm: String
    var addressTermSet: Bool?
    var subscriptionTier: SubscriptionTierValue?
    var subscriptionAnchorAt: Date?
    var subscriptionExpiresAt: Date?
    var maxSeats: [String]?
    var aiConsentVersion: String?
    var aiConsentAt: Date?
    var plansPeriodKey: String?
    var plansCreatedThisPeriod: Int?
    var planMeterMentionedPeriod: String?
    var turnsMonthKey: String?
    var turnsThisMonth: Int?
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
        subscriptionTier: SubscriptionTierValue? = nil,
        subscriptionAnchorAt: Date? = nil,
        subscriptionExpiresAt: Date? = nil,
        maxSeats: [String]? = nil,
        aiConsentVersion: String? = nil,
        aiConsentAt: Date? = nil,
        plansPeriodKey: String? = nil,
        plansCreatedThisPeriod: Int? = nil,
        planMeterMentionedPeriod: String? = nil,
        turnsMonthKey: String? = nil,
        turnsThisMonth: Int? = nil,
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
        self.subscriptionTier = subscriptionTier
        self.subscriptionAnchorAt = subscriptionAnchorAt
        self.subscriptionExpiresAt = subscriptionExpiresAt
        self.maxSeats = maxSeats
        self.aiConsentVersion = aiConsentVersion
        self.aiConsentAt = aiConsentAt
        self.plansPeriodKey = plansPeriodKey
        self.plansCreatedThisPeriod = plansCreatedThisPeriod
        self.planMeterMentionedPeriod = planMeterMentionedPeriod
        self.turnsMonthKey = turnsMonthKey
        self.turnsThisMonth = turnsThisMonth
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
        case subscriptionTier
        case subscriptionAnchorAt
        case subscriptionExpiresAt
        case maxSeats
        case aiConsentVersion
        case aiConsentAt
        case plansPeriodKey
        case plansCreatedThisPeriod
        case planMeterMentionedPeriod
        case turnsMonthKey
        case turnsThisMonth
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
        self.subscriptionTier = try container.decodeIfPresent(SubscriptionTierValue.self, forKey: .subscriptionTier)
        self.subscriptionAnchorAt = try container.decodeIfPresent(Date.self, forKey: .subscriptionAnchorAt)
        self.subscriptionExpiresAt = try container.decodeIfPresent(Date.self, forKey: .subscriptionExpiresAt)
        self.maxSeats = try container.decodeIfPresent([String].self, forKey: .maxSeats)
        self.aiConsentVersion = try container.decodeIfPresent(String.self, forKey: .aiConsentVersion)
        self.aiConsentAt = try container.decodeIfPresent(Date.self, forKey: .aiConsentAt)
        self.plansPeriodKey = try container.decodeIfPresent(String.self, forKey: .plansPeriodKey)
        self.plansCreatedThisPeriod = try container.decodeIfPresent(Int.self, forKey: .plansCreatedThisPeriod)
        self.planMeterMentionedPeriod = try container.decodeIfPresent(String.self, forKey: .planMeterMentionedPeriod)
        self.turnsMonthKey = try container.decodeIfPresent(String.self, forKey: .turnsMonthKey)
        self.turnsThisMonth = try container.decodeIfPresent(Int.self, forKey: .turnsThisMonth)
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
        try container.encodeIfPresent(self.subscriptionTier, forKey: .subscriptionTier)
        try container.encodeIfPresent(self.subscriptionAnchorAt, forKey: .subscriptionAnchorAt)
        try container.encodeIfPresent(self.subscriptionExpiresAt, forKey: .subscriptionExpiresAt)
        try container.encodeIfPresent(self.maxSeats, forKey: .maxSeats)
        try container.encodeIfPresent(self.aiConsentVersion, forKey: .aiConsentVersion)
        try container.encodeIfPresent(self.aiConsentAt, forKey: .aiConsentAt)
        try container.encodeIfPresent(self.plansPeriodKey, forKey: .plansPeriodKey)
        try container.encodeIfPresent(self.plansCreatedThisPeriod, forKey: .plansCreatedThisPeriod)
        try container.encodeIfPresent(self.planMeterMentionedPeriod, forKey: .planMeterMentionedPeriod)
        try container.encodeIfPresent(self.turnsMonthKey, forKey: .turnsMonthKey)
        try container.encodeIfPresent(self.turnsThisMonth, forKey: .turnsThisMonth)
        try container.encode(self.createdAt, forKey: .createdAt)
        try container.encodeIfPresent(self.plansCreatedThisMonth, forKey: .plansCreatedThisMonth)
        try container.encodeIfPresent(self.plansCountMonth, forKey: .plansCountMonth)
        try container.encodeIfPresent(self.quietHoursStart, forKey: .quietHoursStart)
        try container.encodeIfPresent(self.quietHoursEnd, forKey: .quietHoursEnd)
        try container.encodeIfPresent(self.customAutomationCount, forKey: .customAutomationCount)
    }
}
