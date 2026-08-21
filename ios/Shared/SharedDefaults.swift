import Foundation

/// The App Group bridge between the app, the widgets, and the share
/// extension. Everything here must stay tiny and Codable — it crosses
/// process boundaries through UserDefaults.
enum SharedDefaults {
    static let suiteName = "group.com.alamfernandez.otto"

    static var store: UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }
}

/// What the home-screen widget shows — written by the app whenever the
/// up-next session refreshes.
struct WidgetUpNext: Codable {
    var title: String
    var minutes: Int
    var dayLabel: String

    static let key = "otto.widget.upnext"

    static func save(_ snapshot: WidgetUpNext?) {
        guard let snapshot, let data = try? JSONEncoder().encode(snapshot) else {
            SharedDefaults.store.removeObject(forKey: key)
            return
        }
        SharedDefaults.store.set(data, forKey: key)
    }

    static func load() -> WidgetUpNext? {
        guard let data = SharedDefaults.store.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(WidgetUpNext.self, from: data)
    }
}

/// Captures queued outside the app (the share extension) or while offline —
/// drained by the app into real tasks whenever it comes to the foreground.
/// Append-only from extensions; drain-and-requeue from the app.
enum CaptureQueue {
    static let key = "otto.capture.queue"

    static func append(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var queue = SharedDefaults.store.stringArray(forKey: key) ?? []
        queue.append(trimmed)
        SharedDefaults.store.set(Array(queue.suffix(50)), forKey: key)
    }

    /// Returns everything and clears the queue — failed sends are re-queued.
    static func drain() -> [String] {
        let queue = SharedDefaults.store.stringArray(forKey: key) ?? []
        SharedDefaults.store.removeObject(forKey: key)
        return queue
    }

    static func requeue(_ items: [String]) {
        guard !items.isEmpty else { return }
        var queue = items
        queue.append(contentsOf: SharedDefaults.store.stringArray(forKey: key) ?? [])
        SharedDefaults.store.set(Array(queue.prefix(50)), forKey: key)
    }
}

/// One-shot intent handoff: App Intents (Siri, Action Button, widgets)
/// write it; the app consumes it on foreground.
enum PendingIntent {
    static let key = "otto.intent.pending"

    static func set(_ value: String) {
        SharedDefaults.store.set(value, forKey: key)
    }

    static func consume() -> String? {
        let value = SharedDefaults.store.string(forKey: key)
        SharedDefaults.store.removeObject(forKey: key)
        return value
    }
}
