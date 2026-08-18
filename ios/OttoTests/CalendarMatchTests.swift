import XCTest

@testable import Otto

/// Pins the fuzzy event-title resolution used by verified calendar moves.
final class CalendarMatchTests: XCTestCase {

    private func event(_ id: String, _ title: String, daysOut: Double) -> CalendarEvent {
        let start = Date(timeIntervalSince1970: 1_756_000_000 + daysOut * 86_400)
        return CalendarEvent(
            id: id,
            title: title,
            startsAt: start,
            endsAt: start.addingTimeInterval(3600)
        )
    }

    func testExactAndFuzzyTitleMatch() {
        let events = [
            event("late", "Dentist appointment", daysOut: 10),
            event("soon", "Dentist appointment", daysOut: 2),
            event("other", "Team sync", daysOut: 1),
        ]
        // Soonest exact match wins.
        XCTAssertEqual(CalendarService.matchEvent(events, title: "dentist appointment")?.id, "soon")
        // "appointment" is noise; bare "dentist" still resolves.
        XCTAssertEqual(CalendarService.matchEvent(events, title: "the dentist")?.id, "soon")
        XCTAssertEqual(CalendarService.matchEvent(events, title: "sync")?.id, "other")
    }

    func testNoPlausibleMatchIsNil() {
        let events = [event("a", "Team sync", daysOut: 1)]
        XCTAssertNil(CalendarService.matchEvent(events, title: "haircut"))
        XCTAssertNil(CalendarService.matchEvent(events, title: ""))
        XCTAssertNil(CalendarService.matchEvent([], title: "dentist"))
    }
}
