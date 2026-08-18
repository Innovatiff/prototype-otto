import Foundation
import UserNotifications

/// Arms and clears the timer backstop. Faked in tests; the real one talks
/// to UNUserNotificationCenter.
protocol GuidanceBackstopping: Sendable {
    func arm(fireIn: TimeInterval, stepTitle: String) async
    func cancel() async
}

/// The backstop behind background survival: every running timer also
/// schedules a local notification at its deadline, so even if iOS
/// TERMINATES the app mid-workout, the user still gets "Time — Bench
/// Press" at the right moment. Timers that complete, pause, or cancel
/// in-app clear it — the notification only ever fires for a dead app.
actor GuidanceBackstop: GuidanceBackstopping {

    nonisolated static let identifier = "otto.guidance.timer"

    private let center = UNUserNotificationCenter.current()
    private var authorized: Bool?

    func arm(fireIn: TimeInterval, stepTitle: String) async {
        guard await ensureAuthorization() else { return }
        // One timer runs at a time; one identifier, always replaced.
        center.removePendingNotificationRequests(withIdentifiers: [Self.identifier])
        let content = UNMutableNotificationContent()
        content.title = "Time."
        content.body = "\(stepTitle) — back to it."
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: max(1, fireIn),
            repeats: false
        )
        let request = UNNotificationRequest(
            identifier: Self.identifier,
            content: content,
            trigger: trigger
        )
        try? await center.add(request)
    }

    func cancel() async {
        center.removePendingNotificationRequests(withIdentifiers: [Self.identifier])
    }

    /// In-context request, cached for the session. Reminder and brief flows
    /// usually granted this long ago; asking again is a no-op.
    private func ensureAuthorization() async -> Bool {
        if let authorized { return authorized }
        let granted =
            (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        authorized = granted
        return granted
    }
}
