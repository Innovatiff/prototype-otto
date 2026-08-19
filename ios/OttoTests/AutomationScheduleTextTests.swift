import XCTest

@testable import Otto

/// The Swift schedule describer must say exactly what the server's does —
/// the row text and Otto's spoken confirmation are the same sentence.
final class AutomationScheduleTextTests: XCTestCase {

    func testDescribeMirrorsTheServer() {
        XCTAssertEqual(
            AutomationScheduleText.describe(.fixed(rrule: "FREQ=WEEKLY;BYDAY=FR", timeOfDay: "15:30")),
            "Every Friday at 3:30 PM"
        )
        XCTAssertEqual(
            AutomationScheduleText.describe(
                .fixed(rrule: "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR", timeOfDay: "07:25")),
            "Weekdays at 7:25 AM"
        )
        XCTAssertEqual(
            AutomationScheduleText.describe(.fixed(rrule: "FREQ=WEEKLY;BYDAY=SA,SU", timeOfDay: "09:00")),
            "Weekends at 9:00 AM"
        )
        XCTAssertEqual(
            AutomationScheduleText.describe(.fixed(rrule: "FREQ=DAILY", timeOfDay: "21:00")),
            "Every day at 9:00 PM"
        )
        XCTAssertEqual(
            AutomationScheduleText.describe(
                .fixed(rrule: "FREQ=WEEKLY;BYDAY=MO,WE,FR", timeOfDay: "12:00")),
            "Every Monday, Wednesday and Friday at 12:00 PM"
        )
        XCTAssertEqual(
            AutomationScheduleText.describe(
                .relativeToEvent(
                    minutesBefore: 30,
                    eventFilter: AutomationEventFilter(minAttendees: 2)
                )),
            "30 minutes before meetings"
        )
    }

    func testTimeDisplayEdges() {
        XCTAssertEqual(AutomationScheduleText.timeDisplay("00:05"), "12:05 AM")
        XCTAssertEqual(AutomationScheduleText.timeDisplay("12:00"), "12:00 PM")
        XCTAssertEqual(AutomationScheduleText.timeDisplay("23:59"), "11:59 PM")
    }

    func testWakeMappingRoundTripsAcrossMidnight() {
        XCTAssertEqual(AutomationScheduleText.wakeDisplay(fromStored: "07:25"), "07:30")
        XCTAssertEqual(AutomationScheduleText.storedBriefTime(fromWake: "07:30"), "07:25")
        // A midnight-adjacent wake still stores five minutes earlier.
        XCTAssertEqual(AutomationScheduleText.storedBriefTime(fromWake: "00:02"), "23:57")
        XCTAssertEqual(AutomationScheduleText.wakeDisplay(fromStored: "23:57"), "00:02")
    }

    func testPickerRoundTrip() {
        let date = AutomationScheduleText.pickerDate(from: "06:45")
        XCTAssertEqual(AutomationScheduleText.timeOfDay(from: date), "06:45")
    }

    func testLastRunLine() {
        XCTAssertEqual(
            AutomationScheduleText.lastRunLine(lastRunAt: nil, lastResult: nil),
            "Never run"
        )
        let now = Date(timeIntervalSince1970: 1_787_000_000)
        let earlier = now.addingTimeInterval(-3600)
        let line = AutomationScheduleText.lastRunLine(
            lastRunAt: earlier, lastResult: .suppressed, now: now
        )
        XCTAssertTrue(line.hasPrefix("Last ran "))
        XCTAssertTrue(line.hasSuffix("— suppressed"))
        let old = now.addingTimeInterval(-6 * 86_400)
        let oldLine = AutomationScheduleText.lastRunLine(
            lastRunAt: old, lastResult: .delivered, now: now
        )
        XCTAssertTrue(oldLine.contains("— delivered"))
    }
}
