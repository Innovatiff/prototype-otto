import EventKit
import Foundation

enum CalendarServiceError: Error, LocalizedError {
    case accessDenied
    case saveFailed
    case eventNotFound

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Calendar access is off. You can enable it for Otto in Settings."
        case .saveFailed:
            return "The calendar write failed."
        case .eventNotFound:
            return "That event isn't on the calendar."
        }
    }
}

/// EventKit behind a clean seam. EKEvent never leaves this file — everything
/// downstream speaks CalendarEvent, the shared domain type that round-trips
/// to the server.
///
/// Permission is requested IN CONTEXT — the first time a read or write is
/// actually needed (asking about the schedule, enabling the brief) — never
/// at app launch.
@MainActor
final class CalendarService {

    private let store = EKEventStore()

    // MARK: - Access

    private func ensureAccess() async throws {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            return
        case .notDetermined:
            // The in-context moment: the user just asked about their day.
            let granted = (try? await store.requestFullAccessToEvents()) ?? false
            if !granted {
                throw CalendarServiceError.accessDenied
            }
        case .denied, .restricted, .writeOnly:
            throw CalendarServiceError.accessDenied
        @unknown default:
            throw CalendarServiceError.accessDenied
        }
    }

    // MARK: - Read

    /// Events across all calendars in the range, all-day included, sorted by
    /// start time.
    func events(from: Date, to: Date) async throws -> [CalendarEvent] {
        try await ensureAccess()
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: nil)
        return store.events(matching: predicate)
            .compactMap(Self.domainEvent(from:))
            .sorted { $0.startsAt < $1.startsAt }
    }

    /// Events WITHOUT prompting: empty unless full access already exists.
    /// Used for ambient conversation context, which must never trigger the
    /// permission dialog — that happens in context (brief, schedule asks).
    func eventsIfAuthorized(from: Date, to: Date) -> [CalendarEvent] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            return []
        }
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: nil)
        return store.events(matching: predicate)
            .compactMap(Self.domainEvent(from:))
            .sorted { $0.startsAt < $1.startsAt }
    }

    /// One event by identifier — the read-back path for verified writes.
    func event(withId id: String) async throws -> CalendarEvent? {
        try await ensureAccess()
        guard let event = store.event(withIdentifier: id) else {
            return nil
        }
        return Self.domainEvent(from: event)
    }

    // MARK: - Write

    /// Moves an existing event. Callers verify by reading it back.
    func moveEvent(id: String, newStart: Date, newEnd: Date) async throws {
        try await ensureAccess()
        guard let event = store.event(withIdentifier: id) else {
            throw CalendarServiceError.eventNotFound
        }
        event.startDate = newStart
        event.endDate = newEnd
        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            throw CalendarServiceError.saveFailed
        }
    }

    /// Fuzzy title match against events, soonest first — "dentist" finds
    /// "Dentist appointment". Deterministic; nil when nothing plausibly
    /// matches.
    nonisolated static func matchEvent(_ events: [CalendarEvent], title: String) -> CalendarEvent? {
        let needle = normalizedTitle(title)
        guard !needle.isEmpty else { return nil }
        let sorted = events.sorted { $0.startsAt < $1.startsAt }
        if let exact = sorted.first(where: { normalizedTitle($0.title) == needle }) {
            return exact
        }
        return sorted.first { candidate in
            let haystack = normalizedTitle(candidate.title)
            return haystack.contains(needle) || needle.contains(haystack)
        }
    }

    private nonisolated static func normalizedTitle(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "appointment", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted)
            .joined()
            .split(separator: " ")
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Creates the event and returns its identifier. Callers verify by
    /// reading the event back — never assume a write landed.
    func createEvent(_ draft: EventDraft) async throws -> String {
        try await ensureAccess()
        let event = EKEvent(eventStore: store)
        event.title = draft.title
        event.startDate = draft.startsAt
        event.endDate = draft.endsAt
        event.location = draft.location
        event.notes = draft.notes
        event.calendar = store.defaultCalendarForNewEvents
        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            throw CalendarServiceError.saveFailed
        }
        guard let id = event.eventIdentifier else {
            throw CalendarServiceError.saveFailed
        }
        return id
    }

    // MARK: - Mapping

    private static func domainEvent(from event: EKEvent) -> CalendarEvent? {
        guard let id = event.eventIdentifier,
              let start = event.startDate,
              let end = event.endDate
        else { return nil }
        let title = event.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return CalendarEvent(
            id: id,
            title: title.isEmpty ? "Untitled" : title,
            startsAt: start,
            endsAt: end,
            isAllDay: event.isAllDay,
            location: event.location?.isEmpty == false ? event.location : nil,
            notes: event.notes?.isEmpty == false ? event.notes : nil
        )
    }

    // MARK: - Conflict detection (deterministic, pure — NEVER the model)

    /// The travel rule's required gap between events at different places.
    nonisolated static let travelGapMinutes = 30

    /// Detects schedule problems in code, deterministically:
    ///   - overlap: two timed events share time (minutesShort = overlap length)
    ///   - travel: back-to-back at DIFFERENT locations with under 30 minutes
    ///     between them (minutesShort = how much of the 30 is missing)
    /// All-day events are skipped — an all-day "Vacation" overlapping every
    /// meeting is noise, not signal. Pairs are reported once, ordered by the
    /// earlier event.
    nonisolated static func conflicts(in events: [CalendarEvent]) -> [Conflict] {
        let timed = events
            .filter { !$0.isAllDay && $0.endsAt > $0.startsAt }
            .sorted { $0.startsAt < $1.startsAt }
        var found: [Conflict] = []

        for i in timed.indices {
            for j in timed.indices where j > i {
                let a = timed[i]
                let b = timed[j]

                if a.startsAt < b.endsAt && b.startsAt < a.endsAt {
                    let overlapStart = max(a.startsAt, b.startsAt)
                    let overlapEnd = min(a.endsAt, b.endsAt)
                    let minutes = Int((overlapEnd.timeIntervalSince(overlapStart) / 60).rounded(.up))
                    found.append(Conflict(eventA: a, eventB: b, kind: .overlap, minutesShort: max(1, minutes)))
                    continue
                }

                // b starts at or after a ends (sorted). Travel is a
                // back-to-back rule: only ADJACENT events qualify — flagging
                // A→C across an intervening B reads as noise.
                guard
                    j == i + 1,
                    let locationA = normalizedLocation(a.location),
                    let locationB = normalizedLocation(b.location),
                    locationA != locationB
                else { continue }
                let gapMinutes = b.startsAt.timeIntervalSince(a.endsAt) / 60
                if gapMinutes < Double(travelGapMinutes) {
                    found.append(
                        Conflict(
                            eventA: a,
                            eventB: b,
                            kind: .travel,
                            minutesShort: Int((Double(travelGapMinutes) - gapMinutes).rounded(.up))
                        )
                    )
                }
            }
        }
        return found
    }

    private nonisolated static func normalizedLocation(_ location: String?) -> String? {
        guard let location else { return nil }
        let normalized = location.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}
