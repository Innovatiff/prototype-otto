// GENERATED FROM shared/schemas — DO NOT EDIT
//
// Source: shared/schemas/memory.ts
// Regenerate with `npm run codegen`.
//
// Requires this app-target build setting:
//   SWIFT_DEFAULT_ACTOR_ISOLATION = nonisolated
//
// Under MainActor-by-default isolation these Codable conformances cannot
// compile: a main-actor-isolated initializer cannot satisfy the nonisolated
// `init(from:)` requirement.

import Foundation

struct Memory: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var ownerId: String
    var category: MemoryCategory
    var content: String
    var embedding: [Double]?
    var confidence: Double
    var sourceTurnId: String
    var supersedes: String?
    var createdAt: Date
    var lastUsedAt: Date?
    var userEdited: Bool

    init(
        id: String,
        ownerId: String,
        category: MemoryCategory,
        content: String,
        embedding: [Double]? = nil,
        confidence: Double,
        sourceTurnId: String,
        supersedes: String? = nil,
        createdAt: Date,
        lastUsedAt: Date? = nil,
        userEdited: Bool = false
    ) {
        self.id = id
        self.ownerId = ownerId
        self.category = category
        self.content = content
        self.embedding = embedding
        self.confidence = confidence
        self.sourceTurnId = sourceTurnId
        self.supersedes = supersedes
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.userEdited = userEdited
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case ownerId
        case category
        case content
        case embedding
        case confidence
        case sourceTurnId
        case supersedes
        case createdAt
        case lastUsedAt
        case userEdited
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.ownerId = try container.decode(String.self, forKey: .ownerId)
        self.category = try container.decode(MemoryCategory.self, forKey: .category)
        self.content = try container.decode(String.self, forKey: .content)
        self.embedding = try container.decodeIfPresent([Double].self, forKey: .embedding)
        self.confidence = try container.decode(Double.self, forKey: .confidence)
        self.sourceTurnId = try container.decode(String.self, forKey: .sourceTurnId)
        self.supersedes = try container.decodeIfPresent(String.self, forKey: .supersedes)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.lastUsedAt = try container.decodeIfPresent(Date.self, forKey: .lastUsedAt)
        self.userEdited = try container.decodeIfPresent(Bool.self, forKey: .userEdited) ?? false
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .id)
        try container.encode(self.ownerId, forKey: .ownerId)
        try container.encode(self.category, forKey: .category)
        try container.encode(self.content, forKey: .content)
        try container.encodeIfPresent(self.embedding, forKey: .embedding)
        try container.encode(self.confidence, forKey: .confidence)
        try container.encode(self.sourceTurnId, forKey: .sourceTurnId)
        try container.encodeIfPresent(self.supersedes, forKey: .supersedes)
        try container.encode(self.createdAt, forKey: .createdAt)
        try container.encodeIfPresent(self.lastUsedAt, forKey: .lastUsedAt)
        try container.encode(self.userEdited, forKey: .userEdited)
    }
}

enum MemoryCategory: String, Codable, Hashable, Sendable, CaseIterable {
    case identity
    case schedule
    case preference
    case constraint
    case goal
    case context
}
