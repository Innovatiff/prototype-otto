import Foundation

/// POST /plans/{id}/calendar-events — after the device has created the
/// plan's sessions in EventKit and VERIFIED each by read-back, it reports
/// the event ids so the server stores them on the plan (adaptation can
/// move real events later).
extension APIClient {
    func storePlanCalendarEvents(planId: String, events: [PlanCalendarEvent]) async throws {
        let body: Data
        do {
            body = try OttoCoding.encoder.encode(PlanCalendarEventsRequest(events: events))
        } catch {
            throw APIError.decoding(underlying: error)
        }
        _ = try await jsonRequest(
            path: "plans/\(planId)/calendar-events",
            method: "POST",
            body: body
        )
    }
}
