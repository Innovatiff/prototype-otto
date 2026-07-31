import Foundation

/// Plain JSON plumbing shared by the memory and task surfaces. Same auth and
/// error typing as the SSE path; deliberately no retries — these are
/// user-initiated actions with visible outcomes, and repeating a mutation is
/// worse than surfacing a failure.
extension APIClient {

    func decodeBody<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try OttoCoding.decoder.decode(type, from: data)
        } catch {
            throw APIError.decoding(underlying: error)
        }
    }

    func jsonRequest(
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
