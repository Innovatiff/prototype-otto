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
    var createdAt: Date
    var plansCreatedThisMonth: Int?
    var plansCountMonth: String?

    init(
        ownerId: String,
        addressTerm: String = "Boss",
        createdAt: Date,
        plansCreatedThisMonth: Int? = nil,
        plansCountMonth: String? = nil
    ) {
        self.ownerId = ownerId
        self.addressTerm = addressTerm
        self.createdAt = createdAt
        self.plansCreatedThisMonth = plansCreatedThisMonth
        self.plansCountMonth = plansCountMonth
    }

    private enum CodingKeys: String, CodingKey {
        case ownerId
        case addressTerm
        case createdAt
        case plansCreatedThisMonth
        case plansCountMonth
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.ownerId = try container.decode(String.self, forKey: .ownerId)
        self.addressTerm = try container.decodeIfPresent(String.self, forKey: .addressTerm) ?? "Boss"
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.plansCreatedThisMonth = try container.decodeIfPresent(Int.self, forKey: .plansCreatedThisMonth)
        self.plansCountMonth = try container.decodeIfPresent(String.self, forKey: .plansCountMonth)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.ownerId, forKey: .ownerId)
        try container.encode(self.addressTerm, forKey: .addressTerm)
        try container.encode(self.createdAt, forKey: .createdAt)
        try container.encodeIfPresent(self.plansCreatedThisMonth, forKey: .plansCreatedThisMonth)
        try container.encodeIfPresent(self.plansCountMonth, forKey: .plansCountMonth)
    }
}
