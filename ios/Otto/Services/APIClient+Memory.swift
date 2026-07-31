import Foundation

/// Plain JSON calls for the memory screen. Same auth and error typing as the
/// SSE path; no retries — these are user-initiated actions with visible
/// outcomes, and repeating a delete is worse than surfacing a failure.
extension APIClient {

    private struct MemoryListResponse: Decodable {
        let memories: [Memory]
    }

    private struct MemoryEditBody: Encodable {
        let content: String
        let userEdited: Bool
    }

    private struct DeleteAllResponse: Decodable {
        let deleted: Int
    }

    func listMemories() async throws -> [Memory] {
        let data = try await jsonRequest(
            path: "memory",
            method: "GET",
            queryItems: [URLQueryItem(name: "limit", value: "200")]
        )
        return try decodeBody(MemoryListResponse.self, from: data).memories
    }

    /// Edits content. userEdited is always set — an edited memory is exactly
    /// what the extractor must never auto-overwrite.
    func updateMemory(id: String, content: String) async throws -> Memory {
        let body = try OttoCoding.encoder.encode(MemoryEditBody(content: content, userEdited: true))
        let data = try await jsonRequest(path: "memory/\(id)", method: "PATCH", body: body)
        return try decodeBody(Memory.self, from: data)
    }

    func deleteMemory(id: String) async throws {
        _ = try await jsonRequest(path: "memory/\(id)", method: "DELETE")
    }

    @discardableResult
    func deleteAllMemories() async throws -> Int {
        let data = try await jsonRequest(path: "memory", method: "DELETE")
        return try decodeBody(DeleteAllResponse.self, from: data).deleted
    }
}
