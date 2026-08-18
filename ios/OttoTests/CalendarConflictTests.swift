import XCTest

@testable import Otto

/// Pins the deterministic conflict rules. The product constraint: conflict
/// detection happens here, in code — never delegated to the model.
final class CalendarConflictTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_754_000_000)

    private func event(
        _ id: String,
        startMin: Int,
        endMin: Int,
        location: String? = nil,
        allDay: Bool = false
    ) -> CalendarEvent {
        CalendarEvent(
            id: id,
            title: id,
            startsAt: base.addingTimeInterval(TimeInterval(startMin * 60)),
            endsAt: base.addingTimeInterval(TimeInterval(endMin * 60)),
            isAllDay: allDay,
            location: location
        )
    }

    func testOverlapDetectedWithOverlapLength() {
        let conflicts = CalendarService.conflicts(in: [
            event("a", startMin: 0, endMin: 60),
            event("b", startMin: 45, endMin: 90),
        ])
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts.first?.kind, .overlap)
        XCTAssertEqual(conflicts.first?.minutesShort, 15)
        XCTAssertEqual(conflicts.first?.eventA.id, "a")
    }

    func testContainmentIsAnOverlap() {
        let conflicts = CalendarService.conflicts(in: [
            event("outer", startMin: 0, endMin: 120),
            event("inner", startMin: 30, endMin: 60),
        ])
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts.first?.minutesShort, 30)
    }

    func testTouchingEventsDoNotOverlap() {
        let conflicts = CalendarService.conflicts(in: [
            event("a", startMin: 0, endMin: 60),
            event("b", startMin: 60, endMin: 90),
        ])
        XCTAssertTrue(conflicts.isEmpty)
    }

    func testTravelConflictWhenLocationsDifferUnderThirtyMinutes() {
        let conflicts = CalendarService.conflicts(in: [
            event("a", startMin: 0, endMin: 60, location: "Toronto"),
            event("b", startMin: 80, endMin: 120, location: "Mississauga"),
        ])
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts.first?.kind, .travel)
        XCTAssertEqual(conflicts.first?.minutesShort, 10)
    }

    func testNoTravelConflictSameLocationOrEnoughGap() {
        XCTAssertTrue(
            CalendarService.conflicts(in: [
                event("a", startMin: 0, endMin: 60, location: "Office"),
                event("b", startMin: 75, endMin: 120, location: "  office "),
            ]).isEmpty
        )
        XCTAssertTrue(
            CalendarService.conflicts(in: [
                event("a", startMin: 0, endMin: 60, location: "Toronto"),
                event("b", startMin: 95, endMin: 120, location: "Mississauga"),
            ]).isEmpty
        )
    }

    func testNoTravelWithoutBothLocations() {
        let conflicts = CalendarService.conflicts(in: [
            event("a", startMin: 0, endMin: 60, location: "Toronto"),
            event("b", startMin: 70, endMin: 120),
        ])
        XCTAssertTrue(conflicts.isEmpty)
    }

    func testTravelOnlyBetweenAdjacentEvents() {
        // A@X, then B@X, then C@Y: the real travel pair is B→C, not A→C.
        let conflicts = CalendarService.conflicts(in: [
            event("a", startMin: 0, endMin: 60, location: "X"),
            event("b", startMin: 60, endMin: 75, location: "X"),
            event("c", startMin: 80, endMin: 120, location: "Y"),
        ])
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts.first?.eventA.id, "b")
        XCTAssertEqual(conflicts.first?.eventB.id, "c")
    }

    func testAllDayEventsAreSkipped() {
        let conflicts = CalendarService.conflicts(in: [
            event("vacation", startMin: 0, endMin: 1440, allDay: true),
            event("meeting", startMin: 60, endMin: 120),
        ])
        XCTAssertTrue(conflicts.isEmpty)
    }
}
