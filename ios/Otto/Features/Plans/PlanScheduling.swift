import Foundation

/// Pure computation of the calendar drafts for a plan's sessions. Day 0 is
/// the plan's creation day; only occurrences whose start is still in the
/// future become drafts — the past already happened.
enum PlanScheduling {

    struct SessionEvent: Equatable, Identifiable {
        let sessionId: String
        let dayOffset: Int
        let draft: EventDraft

        var id: String { "\(sessionId)@\(dayOffset)" }
    }

    /// When a schedule entry has no timeOfDay: fitness trains after work,
    /// learning studies in the evening, everything else starts the day.
    static func defaultTime(forDomain domain: String) -> (hour: Int, minute: Int) {
        switch domain {
        case "fitness": return (17, 0)
        case "learning": return (19, 0)
        default: return (7, 0)
        }
    }

    /// "HH:mm" → components; nil for anything malformed.
    static func parseTime(_ raw: String?) -> (hour: Int, minute: Int)? {
        guard let raw else { return nil }
        let parts = raw.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return (hour, minute)
    }

    static func drafts(
        for plan: Plan,
        now: Date,
        calendar: Foundation.Calendar = .current
    ) -> [SessionEvent] {
        let startDay = calendar.startOfDay(for: plan.createdAt)
        let sessionsById = Dictionary(
            plan.sessions.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var result: [SessionEvent] = []
        for entry in plan.schedule.sorted(by: { $0.dayOffset < $1.dayOffset }) {
            guard let session = sessionsById[entry.sessionId],
                  let day = calendar.date(byAdding: .day, value: entry.dayOffset, to: startDay)
            else { continue }
            let time = parseTime(entry.timeOfDay) ?? defaultTime(forDomain: plan.meta.domain)
            guard let starts = calendar.date(
                bySettingHour: time.hour, minute: time.minute, second: 0, of: day
            ) else { continue }
            guard starts >= now else { continue }
            let ends = starts.addingTimeInterval(TimeInterval(max(15, session.estimatedMinutes)) * 60)
            result.append(
                SessionEvent(
                    sessionId: entry.sessionId,
                    dayOffset: entry.dayOffset,
                    draft: EventDraft(
                        title: session.title,
                        startsAt: starts,
                        endsAt: ends,
                        notes: "Otto plan: \(plan.meta.goal)"
                    )
                )
            )
        }
        return result
    }
}
