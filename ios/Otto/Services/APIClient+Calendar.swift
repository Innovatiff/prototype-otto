import Foundation

/// The calendar sync endpoint (Phase 6 automations).
extension APIClient {

    /// Uploads the compressed 48-hour view. The server clamps, stores with
    /// a 48-hour TTL, and re-arms event-relative automations.
    func syncCalendar(_ request: CalendarSyncRequest) async throws -> CalendarSyncResponse {
        let body: Data
        do {
            body = try OttoCoding.encoder.encode(request)
        } catch {
            throw APIError.decoding(underlying: error)
        }
        let data = try await jsonRequest(path: "calendar/sync", method: "POST", body: body)
        return try decodeBody(CalendarSyncResponse.self, from: data)
    }
}
