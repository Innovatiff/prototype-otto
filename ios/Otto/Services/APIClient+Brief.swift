import Foundation

/// POST /brief — the morning brief round trip. The client supplies the
/// calendar (EventKit is on-device) with conflicts already computed in
/// Swift; the server returns the spoken text plus the structured card.
extension APIClient {
    func morningBrief(_ request: BriefRequest) async throws -> BriefResponse {
        let body: Data
        do {
            body = try OttoCoding.encoder.encode(request)
        } catch {
            throw APIError.decoding(underlying: error)
        }
        let data = try await jsonRequest(path: "brief", method: "POST", body: body)
        return try decodeBody(BriefResponse.self, from: data)
    }
}
