// GENERATED FROM shared/schemas — DO NOT EDIT
//
// Source: shared/schemas/session.ts
// Regenerate with `npm run codegen`.
//
// Requires this app-target build setting:
//   SWIFT_DEFAULT_ACTOR_ISOLATION = nonisolated
//
// Under MainActor-by-default isolation these Codable conformances cannot
// compile: a main-actor-isolated initializer cannot satisfy the nonisolated
// `init(from:)` requirement.

import Foundation

struct ConversationMessage: Codable, Hashable, Sendable {
    var role: ConversationRole
    var content: String
    var timestamp: Date

    init(
        role: ConversationRole,
        content: String,
        timestamp: Date
    ) {
        self.role = role
        self.content = content
        self.timestamp = timestamp
    }

    private enum CodingKeys: String, CodingKey {
        case role
        case content
        case timestamp
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.role = try container.decode(ConversationRole.self, forKey: .role)
        self.content = try container.decode(String.self, forKey: .content)
        self.timestamp = try container.decode(Date.self, forKey: .timestamp)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.role, forKey: .role)
        try container.encode(self.content, forKey: .content)
        try container.encode(self.timestamp, forKey: .timestamp)
    }
}

enum ConversationRole: String, Codable, Hashable, Sendable, CaseIterable {
    case user
    case assistant
}

struct ConversationSession: Codable, Hashable, Sendable {
    var sessionId: String
    var ownerId: String
    var startedAt: Date
    var lastTurnAt: Date
    var messages: [ConversationMessage]

    init(
        sessionId: String,
        ownerId: String,
        startedAt: Date,
        lastTurnAt: Date,
        messages: [ConversationMessage]
    ) {
        self.sessionId = sessionId
        self.ownerId = ownerId
        self.startedAt = startedAt
        self.lastTurnAt = lastTurnAt
        self.messages = messages
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId
        case ownerId
        case startedAt
        case lastTurnAt
        case messages
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.sessionId = try container.decode(String.self, forKey: .sessionId)
        self.ownerId = try container.decode(String.self, forKey: .ownerId)
        self.startedAt = try container.decode(Date.self, forKey: .startedAt)
        self.lastTurnAt = try container.decode(Date.self, forKey: .lastTurnAt)
        self.messages = try container.decode([ConversationMessage].self, forKey: .messages)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.sessionId, forKey: .sessionId)
        try container.encode(self.ownerId, forKey: .ownerId)
        try container.encode(self.startedAt, forKey: .startedAt)
        try container.encode(self.lastTurnAt, forKey: .lastTurnAt)
        try container.encode(self.messages, forKey: .messages)
    }
}
