import Foundation
import UserNotifications

/// What became of a task event, for the conversation surface to react to.
enum ReminderScheduling {
    case scheduled(Date)
    /// Nothing pending anymore (not a time trigger, not active, or in the past).
    case removed
    case permissionDenied
}

/// Schedules LOCAL notifications for time-triggered reminder tasks.
///
/// - Local only. Remote push needs a paid developer account; local does not.
/// - Permission is requested IN CONTEXT — the first time a reminder is
///   actually scheduled — never at app launch.
/// - The notification identifier is the task id: re-scheduling a changed
///   trigger replaces the pending request, completing the task cancels it,
///   and scheduled notifications survive app relaunches system-side.
/// - No location triggers, no geofencing, no CLLocationManager — cut from
///   scope by explicit product decision.
@MainActor
final class ReminderScheduler: NSObject, UNUserNotificationCenterDelegate {

    private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()
        // Foreground presentation: a reminder firing while Otto is open
        // still banners and sounds instead of vanishing silently.
        center.delegate = self
    }

    /// Reacts to a task_created/task_updated event: schedules, replaces, or
    /// cancels the task's local notification.
    func handle(_ task: OttoTask) async -> ReminderScheduling {
        let fireAt: Date?
        switch task.trigger {
        case .time(let at):
            fireAt = at
        case .recurring(_, let nextFire):
            // One-shot on the pre-computed next fire; RRULE expansion arrives
            // with the planning phase.
            fireAt = nextFire
        case .noTrigger:
            fireAt = nil
        }

        guard task.status == .active, let fireAt, fireAt.timeIntervalSinceNow > 1 else {
            center.removePendingNotificationRequests(withIdentifiers: [task.id])
            return .removed
        }
        guard await ensureAuthorization() else {
            return .permissionDenied
        }

        let content = UNMutableNotificationContent()
        content.title = task.title
        if let context = task.context {
            content.subtitle = context
        }
        content.sound = .default

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: fireAt
        )
        let request = UNNotificationRequest(
            identifier: task.id,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        )
        do {
            try await center.add(request)
            return .scheduled(fireAt)
        } catch {
            print("ReminderScheduler: scheduling failed: \(error)")
            return .removed
        }
    }

    private func ensureAuthorization() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            // The in-context moment: the user just asked for a reminder.
            return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
