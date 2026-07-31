import Foundation
import Observation
import SwiftUI

/// State for the task screen. Loads from the server, and stays live: task
/// events from the voice loop upsert straight into the list, so an item
/// added by voice animates in while you watch.
@MainActor
@Observable
final class TasksModel {

    private(set) var tasks: [OttoTask] = []
    private(set) var isLoading = false
    private(set) var errorText: String?

    private let auth: any AuthProvider

    init(auth: any AuthProvider) {
        self.auth = auth
    }

    // MARK: - Grouping

    /// Tasks with a fire date, soonest first.
    var reminders: [OttoTask] {
        tasks
            .compactMap { (task: OttoTask) -> (OttoTask, Date)? in
                guard let fireAt = Self.fireDate(of: task) else { return nil }
                return (task, fireAt)
            }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    /// Everything else, grouped by context: named contexts alphabetically,
    /// then untagged.
    var contextGroups: [(context: String?, tasks: [OttoTask])] {
        let listables = tasks.filter { Self.fireDate(of: $0) == nil }
        let named = Dictionary(grouping: listables.filter { $0.context != nil }) { $0.context ?? "" }
        let groups: [(String?, [OttoTask])] = named
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { ($0.key, $0.value) }
        let untagged = listables.filter { $0.context == nil }
        return untagged.isEmpty ? groups : groups + [(nil, untagged)]
    }

    static func fireDate(of task: OttoTask) -> Date? {
        switch task.trigger {
        case .time(let at):
            return at
        case .recurring(_, let nextFire):
            return nextFire
        case .noTrigger:
            return nil
        }
    }

    // MARK: - Loading and live updates

    func load() async {
        guard let client = makeClient() else { return }
        isLoading = true
        errorText = nil
        defer { isLoading = false }
        do {
            tasks = try await client.listTasks()
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// A task event from the conversation: upsert, animated — this is how
    /// voice-added items visibly arrive.
    func apply(_ task: OttoTask) {
        withAnimation(.snappy) {
            if task.status != .active {
                tasks.removeAll { $0.id == task.id }
            } else if let index = tasks.firstIndex(where: { $0.id == task.id }) {
                tasks[index] = task
            } else {
                tasks.insert(task, at: 0)
            }
        }
    }

    // MARK: - Mutations

    /// Checkbox tap: optimistic flip, then persist; server truth on reply,
    /// revert on failure.
    func toggle(item: ListItem, in task: OttoTask) async {
        guard let taskIndex = tasks.firstIndex(where: { $0.id == task.id }),
              let itemIndex = tasks[taskIndex].items.firstIndex(where: { $0.id == item.id }),
              let client = makeClient()
        else { return }
        let previous = tasks[taskIndex].items
        tasks[taskIndex].items[itemIndex].checked.toggle()
        do {
            let updated = try await client.updateTaskItems(id: task.id, items: tasks[taskIndex].items)
            if let index = tasks.firstIndex(where: { $0.id == updated.id }) {
                tasks[index] = updated
            }
        } catch {
            if let index = tasks.firstIndex(where: { $0.id == task.id }) {
                tasks[index].items = previous
            }
            errorText = error.localizedDescription
        }
    }

    func delete(_ task: OttoTask) async {
        guard let client = makeClient() else { return }
        do {
            try await client.deleteTask(id: task.id)
            withAnimation(.snappy) {
                tasks.removeAll { $0.id == task.id }
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func makeClient() -> APIClient? {
        let urlString =
            UserDefaults.standard.string(forKey: DebugModel.serverURLKey) ?? "http://localhost:8080"
        guard let url = URL(string: urlString), url.scheme != nil else {
            errorText = "Invalid server URL."
            return nil
        }
        guard auth.currentUserId != nil else {
            errorText = "Sign in to see your tasks."
            return nil
        }
        return APIClient(baseURL: url, auth: auth)
    }
}
