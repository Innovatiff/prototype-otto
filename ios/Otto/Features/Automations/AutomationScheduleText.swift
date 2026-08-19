import Foundation

/// Pure text for the automations screen — the Swift mirror of the server's
/// schedule describer, plus the row's status line. Kept deterministic and
/// locale-fixed so the strings match what Otto SAYS when confirming by
/// voice ("Every Friday at 3:30 PM").
enum AutomationScheduleText {

    private static let dayNames = [
        "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday",
    ]

    /// "15:30" -> "3:30 PM".
    static func timeDisplay(_ timeOfDay: String) -> String {
        guard let (hour, minute) = components(of: timeOfDay) else { return timeOfDay }
        let suffix = hour >= 12 ? "PM" : "AM"
        let twelve = hour % 12 == 0 ? 12 : hour % 12
        return String(format: "%d:%02d %@", twelve, minute, suffix)
    }

    /// The row's schedule line — "Weekdays at 7:25 AM", "30 minutes before
    /// meetings".
    static func describe(_ schedule: AutomationSchedule) -> String {
        switch schedule {
        case .relativeToEvent(let minutesBefore, let filter):
            let what = (filter.minAttendees ?? 0) >= 2 ? "meetings" : "events"
            return "\(minutesBefore) minutes before \(what)"
        case .fixed(let rrule, let timeOfDay):
            return describeFixed(rrule: rrule, timeOfDay: timeOfDay)
        }
    }

    private static func describeFixed(rrule: String, timeOfDay: String) -> String {
        let time = timeDisplay(timeOfDay)
        guard let days = weekdays(fromRrule: rrule) else {
            return "Every day at \(time)"
        }
        let key = days.sorted().map(String.init).joined(separator: ",")
        if key == "1,2,3,4,5" { return "Weekdays at \(time)" }
        if key == "6,7" { return "Weekends at \(time)" }
        if days.count == 7 { return "Every day at \(time)" }
        let names = days.sorted().compactMap { index in
            index >= 1 && index <= 7 ? dayNames[index - 1] : nil
        }
        if names.count == 1 {
            return "Every \(names[0]) at \(time)"
        }
        let joined = names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
        return "Every \(joined) at \(time)"
    }

    /// BYDAY weekday numbers (1 = Monday … 7 = Sunday), nil for FREQ=DAILY.
    private static func weekdays(fromRrule rrule: String) -> Set<Int>? {
        let map: [String: Int] = ["MO": 1, "TU": 2, "WE": 3, "TH": 4, "FR": 5, "SA": 6, "SU": 7]
        for part in rrule.uppercased().split(separator: ";") {
            guard part.hasPrefix("BYDAY=") else { continue }
            let tokens = part.dropFirst("BYDAY=".count).split(separator: ",")
            let days = tokens.compactMap { map[String($0)] }
            return days.isEmpty ? nil : Set(days)
        }
        return nil
    }

    /// "Last ran 7:25 AM — delivered" / "suppressed" / "failed" / "Never run".
    static func lastRunLine(lastRunAt: Date?, lastResult: AutomationRunResult?, now: Date = Date()) -> String {
        guard let lastRunAt else { return "Never run" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let calendar = Calendar.current
        if calendar.isDate(lastRunAt, inSameDayAs: now) {
            formatter.dateFormat = "h:mm a"
        } else {
            formatter.dateFormat = "MMM d"
        }
        let when = formatter.string(from: lastRunAt)
        guard let lastResult else { return "Last ran \(when)" }
        return "Last ran \(when) — \(lastResult.rawValue)"
    }

    // MARK: - Wall-clock ↔ Date, for the DatePicker bindings

    /// "07:25" -> today's 07:25 as a Date (picker display only).
    static func pickerDate(from timeOfDay: String, calendar: Calendar = .current) -> Date {
        guard let (hour, minute) = components(of: timeOfDay) else { return Date() }
        var parts = DateComponents()
        parts.hour = hour
        parts.minute = minute
        return calendar.date(from: parts) ?? Date()
    }

    /// A picked Date -> "HH:mm".
    static func timeOfDay(from date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    /// The morning brief GENERATES five minutes before wake so it lands at
    /// wake. The screen shows the wake time; storage keeps the -5.
    static let briefLeadMinutes = 5

    /// "07:25" (stored) -> "07:30" (shown as wake time).
    static func wakeDisplay(fromStored timeOfDay: String) -> String {
        shift(timeOfDay, by: briefLeadMinutes)
    }

    /// "07:30" (picked wake) -> "07:25" (stored fire time).
    static func storedBriefTime(fromWake timeOfDay: String) -> String {
        shift(timeOfDay, by: -briefLeadMinutes)
    }

    private static func shift(_ timeOfDay: String, by minutes: Int) -> String {
        guard let (hour, minute) = components(of: timeOfDay) else { return timeOfDay }
        let total = (hour * 60 + minute + minutes + 24 * 60) % (24 * 60)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private static func components(of timeOfDay: String) -> (Int, Int)? {
        let parts = timeOfDay.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]), (0...23).contains(hour),
              let minute = Int(parts[1]), (0...59).contains(minute)
        else { return nil }
        return (hour, minute)
    }
}
