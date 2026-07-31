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

    // MARK: - JSON plumbing

    private func decodeBody<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try OttoCoding.decoder.decode(type, from: data)
        } catch {
            throw APIError.decoding(underlying: error)
        }
    }

    private func jsonRequest(
        path: String,
        method: String,
        queryItems: [URLQueryItem] = [],
        body: Data? = nil
    ) async throws -> Data {
        let token = try await auth.idToken()
        var url = baseURL.appending(path: path)
        if !queryItems.isEmpty {
            url.append(queryItems: queryItems)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.transport(underlying: error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw APIError.notHTTP
        }
        guard (200...299).contains(http.statusCode) else {
            throw APIError.http(
                status: http.statusCode,
                body: String(decoding: data.prefix(16_384), as: UTF8.self)
            )
        }
        return data
    }
}
