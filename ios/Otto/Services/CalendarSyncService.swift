import BackgroundTasks
import Foundation

/// Pushes the compressed 48-hour calendar view to the server so automations
/// (meeting prep, briefs) can see the shape of the day — and keeps the
/// server's idea of the timezone honest.
///
/// Three gates, all of which must open before a single byte leaves:
///   1. The user turned calendar sync ON in Settings (default OFF).
///   2. iOS calendar permission is full-access (never prompted from here).
///   3. The foreground throttle: at most one sync per hour unless forced.
///
/// What crosses the wire is CalendarSyncEvent — title, times, location,
/// attendee count. Notes and attendee identities are not in the type.
/// Failures are silent: sync is ambient plumbing, and the server treats a
/// view older than a day as untrustworthy anyway.
@MainActor
final class CalendarSyncService {

    /// Settings toggle — the consent flag. Nothing syncs while false.
    static let consentKey = "otto.calendarSync.enabled"
    static let lastSyncKey = "otto.calendarSync.lastSyncAt"
    /// Must match BGTaskSchedulerPermittedIdentifiers in project.yml.
    static let backgroundTaskId = "com.yourname.otto.calendar-refresh"

    /// Foreground syncs at most hourly; the view only needs to be fresher
    /// than the server's 24-hour staleness line.
    static let minSyncInterval: TimeInterval = 60 * 60

    private let auth: any AuthProvider
    private let calendar: CalendarService

    init(auth: any AuthProvider, calendar: CalendarService) {
        self.auth = auth
        self.calendar = calendar
    }

    static var consented: Bool {
        UserDefaults.standard.bool(forKey: consentKey)
    }

    /// The throttle decision, pure. `force` (the consent toggle just flipped
    /// on) bypasses the interval but never the consent itself.
    nonisolated static func shouldSync(
        consented: Bool,
        lastSyncAt: Date?,
        now: Date,
        force: Bool
    ) -> Bool {
        guard consented else { return false }
        if force { return true }
        guard let lastSyncAt else { return true }
        return now.timeIntervalSince(lastSyncAt) >= minSyncInterval
    }

    /// Foreground entry point (app became active, or consent flipped on).
    func syncIfNeeded(force: Bool = false) async {
        let defaults = UserDefaults.standard
        let lastSyncAt = defaults.object(forKey: Self.lastSyncKey) as? Date
        guard Self.shouldSync(
            consented: Self.consented,
            lastSyncAt: lastSyncAt,
            now: Date(),
            force: force
        ) else { return }
        guard let client = makeClient() else { return }

        // Empty is a valid view ("nothing on the calendar") — but only send
        // it when access exists, so a permission-revoked state uploads
        // nothing rather than an emptiness lie.
        guard calendar.hasFullAccess else { return }
        let events = calendar.syncViewIfAuthorized()
        let request = CalendarSyncRequest(events: events, timezone: TimeZone.current.identifier)
        do {
            _ = try await client.syncCalendar(request)
            defaults.set(Date(), forKey: Self.lastSyncKey)
        } catch {
            // Silent by design; the next foreground or background pass retries.
        }
    }

    // MARK: - Background refresh (the daily half of the contract)

    /// Queues the next background sync. iOS decides the actual moment;
    /// 12 hours keeps the view comfortably inside the server's 24-hour
    /// staleness line even if the app stays closed all day.
    func scheduleBackgroundRefresh() {
        guard Self.consented else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.backgroundTaskId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 12 * 60 * 60)
        // Duplicate submissions and simulator refusals both land here; a
        // missed schedule self-heals on the next foreground.
        try? BGTaskScheduler.shared.submit(request)
    }

    /// The system woke us: sync, then queue the next one.
    func handleBackgroundRefresh() async {
        await syncIfNeeded(force: false)
        scheduleBackgroundRefresh()
    }

    private func makeClient() -> APIClient? {
        let urlString =
            UserDefaults.standard.string(forKey: DebugModel.serverURLKey) ?? "http://localhost:8080"
        guard let url = URL(string: urlString), url.scheme != nil else { return nil }
        guard auth.currentUserId != nil else { return nil }
        return APIClient(baseURL: url, auth: auth)
    }
}
