import XCTest

@testable import Otto

/// Pins the sync gates and the compressed-event normalizer — the privacy
/// boundary's client half.
final class CalendarSyncTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_787_000_000)

    // MARK: - The throttle gate

    func testNothingSyncsWithoutConsent() {
        XCTAssertFalse(
            CalendarSyncService.shouldSync(consented: false, lastSyncAt: nil, now: now, force: false)
        )
        // Force is a UI convenience, never a consent bypass.
        XCTAssertFalse(
            CalendarSyncService.shouldSync(consented: false, lastSyncAt: nil, now: now, force: true)
        )
    }

    func testFirstSyncAndHourlyThrottle() {
        XCTAssertTrue(
            CalendarSyncService.shouldSync(consented: true, lastSyncAt: nil, now: now, force: false)
        )
        let tenMinutesAgo = now.addingTimeInterval(-600)
        XCTAssertFalse(
            CalendarSyncService.shouldSync(
                consented: true, lastSyncAt: tenMinutesAgo, now: now, force: false
            )
        )
        let twoHoursAgo = now.addingTimeInterval(-7200)
        XCTAssertTrue(
            CalendarSyncService.shouldSync(
                consented: true, lastSyncAt: twoHoursAgo, now: now, force: false
            )
        )
        // The consent toggle just flipped on: sync immediately.
        XCTAssertTrue(
            CalendarSyncService.shouldSync(
                consented: true, lastSyncAt: tenMinutesAgo, now: now, force: true
            )
        )
    }

    // MARK: - The compressed event normalizer

    func testNormalizerBoundsAndTrims() {
        let event = CalendarService.syncEvent(
            id: "e1",
            title: "  Henderson review  ",
            startsAt: now,
            endsAt: now.addingTimeInterval(1800),
            location: "   ",
            attendeeCount: 3
        )
        XCTAssertEqual(event?.title, "Henderson review")
        XCTAssertNil(event?.location, "whitespace-only locations are dropped")
        XCTAssertEqual(event?.attendeeCount, 3)
    }

    func testNormalizerRejectsDegenerateEvents() {
        XCTAssertNil(
            CalendarService.syncEvent(
                id: "", title: "x", startsAt: now, endsAt: now.addingTimeInterval(60),
                location: nil, attendeeCount: 0
            )
        )
        XCTAssertNil(
            CalendarService.syncEvent(
                id: "e1", title: "x", startsAt: now, endsAt: now,
                location: nil, attendeeCount: 0
            ),
            "zero-length events carry no schedulable moment"
        )
    }

    func testNormalizerCapsRunawayValues() {
        let longTitle = String(repeating: "a", count: 500)
        let event = CalendarService.syncEvent(
            id: "e1",
            title: longTitle,
            startsAt: now,
            endsAt: now.addingTimeInterval(60),
            location: String(repeating: "b", count: 500),
            attendeeCount: 9999
        )
        XCTAssertEqual(event?.title.count, 200)
        XCTAssertEqual(event?.location?.count, 200)
        XCTAssertEqual(event?.attendeeCount, 500)
        let negative = CalendarService.syncEvent(
            id: "e2", title: nil, startsAt: now, endsAt: now.addingTimeInterval(60),
            location: nil, attendeeCount: -3
        )
        XCTAssertEqual(negative?.title, "Untitled")
        XCTAssertEqual(negative?.attendeeCount, 0)
    }
}
