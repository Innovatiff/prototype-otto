import Foundation

/// Plan reads for the hub's Plans pane, plus the calendar-link report.
extension APIClient {

    /// GET /plans — every plan, newest first, summaries only. Superseded
    /// versions are included: history is the supersedes chain.
    func listPlans() async throws -> [PlanSummary] {
        let data = try await jsonRequest(path: "plans", method: "GET")
        return try decodeBody(PlanListResponse.self, from: data).plans
    }

    /// GET /plans/{id} — one full plan (sessions, schedule, links).
    func planDetail(id: String) async throws -> Plan {
        let data = try await jsonRequest(path: "plans/\(id)", method: "GET")
        return try decodeBody(Plan.self, from: data)
    }

    /// POST /plans/{id}/calendar-events — after the device has created the
    /// plan's sessions in EventKit and VERIFIED each by read-back, it
    /// reports the event ids so the server stores them on the plan
    /// (adaptation can move real events later).
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
