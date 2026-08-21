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
            suggestions = (response.suggestions ?? []).filter { !isDismissed($0) }
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't load automations."
        }
    }

    // MARK: - Open-time suggestions (the engagement log, read positively)

    private(set) var suggestions: [AutomationTimeSuggestion] = []

    func suggestion(for automation: Automation) -> AutomationTimeSuggestion? {
        suggestions.first { $0.automationId == automation.id }
    }

    /// One tap moves the fire time to when they actually show up.
    func applySuggestion(_ suggestion: AutomationTimeSuggestion) async {
        suggestions.removeAll { $0.automationId == suggestion.automationId }
        await mutate { client in
            try await client.updateAutomation(
                id: suggestion.automationId,
                enabled: nil,
                timeOfDay: suggestion.suggestedTime
            )
        }
    }

    /// "Keep it" — remembered per automation+time, so the same suggestion
    /// never nags twice.
    func dismissSuggestion(_ suggestion: AutomationTimeSuggestion) {
        UserDefaults.standard.set(true, forKey: Self.dismissKey(suggestion))
        suggestions.removeAll { $0.automationId == suggestion.automationId }
    }

    private func isDismissed(_ suggestion: AutomationTimeSuggestion) -> Bool {
        UserDefaults.standard.bool(forKey: Self.dismissKey(suggestion))
    }

    private static func dismissKey(_ suggestion: AutomationTimeSuggestion) -> String {
        "otto.timesuggestion.dismissed.\(suggestion.automationId).\(suggestion.suggestedTime)"
    }

    func setEnabled(_ automation: Automation, enabled: Bool) async {
        // Optimistic: the toggle must not snap back while the round trip
        // runs; the reload afterwards restores server truth either way.
        if let index = automations.firstIndex(where: { $0.id == automation.id }) {
            automations[index].enabled = enabled
        }
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
        // Optimistic, same reason as the toggle: the picker holds its value.
        if let index = automations.firstIndex(where: { $0.id == automation.id }),
           case .fixed(let rrule, _) = automations[index].schedule {
            automations[index].schedule = .fixed(rrule: rrule, timeOfDay: stored)
        }
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
        var failure: String?
        do {
            try await operation(client)
        } catch {
            failure = "That change didn't save."
        }
        // Reload restores server truth (and rolls back the optimistic
        // change on failure) — then the failure message survives it.
        await load()
        if let failure {
            errorMessage = failure
        }
    }

    private func makeClient() -> APIClient? {
        let urlString =
            UserDefaults.standard.string(forKey: DebugModel.serverURLKey) ?? "http://localhost:8080"
        guard let url = URL(string: urlString), url.scheme != nil else { return nil }
        guard auth.currentUserId != nil else { return nil }
        return APIClient(baseURL: url, auth: auth)
    }
}
