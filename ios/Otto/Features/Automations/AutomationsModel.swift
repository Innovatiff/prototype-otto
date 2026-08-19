import Foundation
import Observation

/// State for the automations management screen. The server is the truth:
/// every mutation round-trips and then reloads the list, so what the
/// screen shows is what the scheduler will actually do.
@MainActor
@Observable
final class AutomationsModel {

    private(set) var automations: [Automation] = []
    private(set) var quietHoursStart = "22:00"
    private(set) var quietHoursEnd = "07:00"
    private(set) var isLoading = false
    var errorMessage: String?

    /// The conversation model keeps the LOCAL weekday brief notifications
    /// in sync when wake time changes here (they are the no-push fallback).
    var onWakeTimeChanged: ((_ hour: Int, _ minute: Int) -> Void)?

    private let auth: any AuthProvider

    init(auth: any AuthProvider) {
        self.auth = auth
    }

    var builtIns: [Automation] {
        automations.filter { $0.type != .custom }
    }

    var customs: [Automation] {
        automations.filter { $0.type == .custom }
    }

    func load() async {
        guard let client = makeClient() else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let response = try await client.listAutomations()
            automations = response.automations
            quietHoursStart = response.quietHoursStart
            quietHoursEnd = response.quietHoursEnd
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't load automations."
        }
    }

    func setEnabled(_ automation: Automation, enabled: Bool) async {
        await mutate { client in
            try await client.updateAutomation(id: automation.id, enabled: enabled, timeOfDay: nil)
        }
    }

    /// Retimes a fixed automation. The morning brief arrives as a WAKE time
    /// and is stored five minutes earlier — generation lead, per spec.
    func setTime(_ automation: Automation, picked: Date) async {
        var timeOfDay = AutomationScheduleText.timeOfDay(from: picked)
        if automation.type == .morningBrief {
            timeOfDay = AutomationScheduleText.storedBriefTime(fromWake: timeOfDay)
            let parts = Calendar.current.dateComponents([.hour, .minute], from: picked)
            onWakeTimeChanged?(parts.hour ?? 7, parts.minute ?? 30)
        }
        let stored = timeOfDay
        await mutate { client in
            try await client.updateAutomation(id: automation.id, enabled: nil, timeOfDay: stored)
        }
    }

    func delete(_ automation: Automation) async {
        guard automation.type == .custom else { return }
        await mutate { client in
            try await client.deleteAutomation(id: automation.id)
        }
    }

    func setQuietHours(start: Date, end: Date) async {
        let startTime = AutomationScheduleText.timeOfDay(from: start)
        let endTime = AutomationScheduleText.timeOfDay(from: end)
        guard startTime != quietHoursStart || endTime != quietHoursEnd else { return }
        await mutate { client in
            try await client.updateAutomationSettings(
                quietHoursStart: startTime,
                quietHoursEnd: endTime
            )
        }
    }

    private func mutate(_ operation: (APIClient) async throws -> Void) async {
        guard let client = makeClient() else { return }
        do {
            try await operation(client)
            errorMessage = nil
        } catch {
            errorMessage = "That change didn't save."
        }
        await load()
    }

    private func makeClient() -> APIClient? {
        let urlString =
            UserDefaults.standard.string(forKey: DebugModel.serverURLKey) ?? "http://localhost:8080"
        guard let url = URL(string: urlString), url.scheme != nil else { return nil }
        guard auth.currentUserId != nil else { return nil }
        return APIClient(baseURL: url, auth: auth)
    }
}
