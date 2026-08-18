import XCTest

@testable import Otto

/// Pins the pure draft computation: day 0 is the creation day, times come
/// from timeOfDay with per-domain fallbacks, and anything already in the
/// past produces no draft.
final class PlanSchedulingTests: XCTestCase {

    private var utc: Foundation.Calendar {
        var calendar = Foundation.Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    // Mon 2026-08-03 00:00:00 UTC
    private let created = Date(timeIntervalSince1970: 1_785_715_200)

    private func plan(
        domain: String = "fitness",
        schedule: [ScheduledSession],
        estimatedMinutes: Int = 45
    ) -> Plan {
        Plan(
            id: "p1",
            ownerId: "u1",
            meta: PlanMeta(domain: domain, goal: "get stronger", horizonDays: 56, version: 1),
            constraints: [:],
            schedule: schedule,
            sessions: [
                Session(
                    id: "lower-a",
                    title: "Lower A",
                    estimatedMinutes: estimatedMinutes,
                    steps: [
                        Step(
                            id: "s1",
                            type: .counted,
                            title: "Goblet squat",
                            cue: "Chest tall.",
                            completion: .manual
                        )
                    ]
                )
            ],
            status: .active,
            createdAt: created
        )
    }

    func testTimeOfDayHonoredAndDurationFromSession() {
        let result = PlanScheduling.drafts(
            for: plan(schedule: [ScheduledSession(sessionId: "lower-a", dayOffset: 2, timeOfDay: "06:30")]),
            now: created,
            calendar: utc
        )
        XCTAssertEqual(result.count, 1)
        let draft = result[0].draft
        var expected = DateComponents()
        expected.year = 2026; expected.month = 8; expected.day = 5
        expected.hour = 6; expected.minute = 30
        XCTAssertEqual(draft.startsAt, utc.date(from: expected))
        XCTAssertEqual(draft.endsAt.timeIntervalSince(draft.startsAt), 45 * 60)
        XCTAssertEqual(draft.title, "Lower A")
        XCTAssertEqual(result[0].id, "lower-a@2")
    }

    func testDomainDefaultsFillMissingTimes() {
        let fitness = PlanScheduling.drafts(
            for: plan(domain: "fitness", schedule: [ScheduledSession(sessionId: "lower-a", dayOffset: 1)]),
            now: created,
            calendar: utc
        )
        XCTAssertEqual(utc.component(.hour, from: fitness[0].draft.startsAt), 17)

        let learning = PlanScheduling.drafts(
            for: plan(domain: "learning", schedule: [ScheduledSession(sessionId: "lower-a", dayOffset: 1)]),
            now: created,
            calendar: utc
        )
        XCTAssertEqual(utc.component(.hour, from: learning[0].draft.startsAt), 19)
    }

    func testPastOccurrencesAreSkipped() {
        // Now = day 10 of the plan at noon: days 0-9 are gone, and day 10's
        // own 07:00 session has already started too.
        let now = created.addingTimeInterval(10 * 86_400 + 12 * 3600)
        let result = PlanScheduling.drafts(
            for: plan(schedule: [
                ScheduledSession(sessionId: "lower-a", dayOffset: 0, timeOfDay: "07:00"),
                ScheduledSession(sessionId: "lower-a", dayOffset: 10, timeOfDay: "07:00"),
                ScheduledSession(sessionId: "lower-a", dayOffset: 10, timeOfDay: "18:00"),
                ScheduledSession(sessionId: "lower-a", dayOffset: 11, timeOfDay: "07:00"),
            ]),
            now: now,
            calendar: utc
        )
        XCTAssertEqual(result.map(\.dayOffset), [10, 11])
        XCTAssertEqual(utc.component(.hour, from: result[0].draft.startsAt), 18)
    }

    func testMalformedTimeFallsBackAndUnknownSessionSkipped() {
        let result = PlanScheduling.drafts(
            for: plan(schedule: [
                ScheduledSession(sessionId: "lower-a", dayOffset: 1, timeOfDay: "late-ish"),
                ScheduledSession(sessionId: "ghost", dayOffset: 2),
            ]),
            now: created,
            calendar: utc
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(utc.component(.hour, from: result[0].draft.startsAt), 17)
        XCTAssertNil(PlanScheduling.parseTime("25:00"))
        XCTAssertNil(PlanScheduling.parseTime("7"))
        XCTAssertEqual(PlanScheduling.parseTime("07:05")?.minute, 5)
    }
}
