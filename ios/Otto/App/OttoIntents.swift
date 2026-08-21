import AppIntents

/// Otto from the outside: Siri, Shortcuts, Spotlight, and the Action
/// Button. Each intent opens the app and leaves a one-shot handoff in the
/// App Group; the app consumes it the moment it foregrounds.
struct AskOttoIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Otto"
    static let description = IntentDescription("Open Otto listening, ready for you to talk.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        PendingIntent.set("listen")
        return .result()
    }
}

struct StartSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "Start My Session"
    static let description = IntentDescription("Start today's guided session or the pending walkthrough.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        PendingIntent.set("start")
        return .result()
    }
}

struct RunBriefIntent: AppIntent {
    static let title: LocalizedStringResource = "Run My Brief"
    static let description = IntentDescription("Play the morning brief with its visuals.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        PendingIntent.set("brief")
        return .result()
    }
}

struct OttoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskOttoIntent(),
            phrases: ["Ask \(.applicationName)", "Talk to \(.applicationName)"],
            shortTitle: "Ask Otto",
            systemImageName: "mic.fill"
        )
        AppShortcut(
            intent: StartSessionIntent(),
            phrases: ["Start my session with \(.applicationName)", "Start my workout with \(.applicationName)"],
            shortTitle: "Start Session",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: RunBriefIntent(),
            phrases: ["Run my brief in \(.applicationName)", "Get me ready with \(.applicationName)"],
            shortTitle: "Morning Brief",
            systemImageName: "sun.max.fill"
        )
    }
}
