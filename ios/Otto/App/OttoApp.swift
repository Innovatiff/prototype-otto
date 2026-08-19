import SwiftUI
import FirebaseCore

/// App entry point.
///
/// `FirebaseApp.configure()` here is the SwiftUI equivalent of the UIKit
/// AppDelegate `didFinishLaunchingWithOptions` pattern from the Firebase docs.
/// It reads GoogleService-Info.plist from the bundle — place that file at
/// ios/Otto/GoogleService-Info.plist (it is gitignored, never committed).
@main
struct OttoApp: App {
    @State private var conversation: ConversationModel
    @State private var settings: DebugModel
    @State private var memory: MemoryModel
    @State private var tasks: TasksModel
    @State private var plans: PlansModel
    @State private var calendarSync: CalendarSyncService
    @Environment(\.scenePhase) private var scenePhase

    init() {
        FirebaseApp.configure()
        // Render the orb's 60k grains during launch, where the work is
        // masked — never as a hitch on the first frame of the stage.
        _ = OrbGrain.fieldA
        _ = OrbGrain.fieldB
        // EmailPasswordAuth is the Phase 0 AuthProvider. Sign in with Apple
        // becomes a second implementation of the same protocol later — this
        // line is the only one that changes. One instance feeds every model
        // so sign-in state is shared.
        let auth = EmailPasswordAuth()
        let tasksModel = TasksModel(auth: auth)
        let plansModel = PlansModel(auth: auth)
        let calendarService = CalendarService()
        _settings = State(initialValue: DebugModel(auth: auth))
        _tasks = State(initialValue: tasksModel)
        _plans = State(initialValue: plansModel)
        _conversation = State(
            initialValue: ConversationModel(
                auth: auth,
                tasksModel: tasksModel,
                plansModel: plansModel,
                calendarService: calendarService
            )
        )
        _memory = State(initialValue: MemoryModel(auth: auth))
        _calendarSync = State(
            initialValue: CalendarSyncService(auth: auth, calendar: calendarService)
        )
    }

    var body: some Scene {
        WindowGroup {
            ConversationView(
                model: conversation,
                settings: settings,
                memory: memory,
                tasks: tasks,
                plans: plans,
                calendarSync: calendarSync
            )
                // Otto's stage is dark-first and monochrome; sheets inherit.
                .preferredColorScheme(.dark)
                .tint(.white)
        }
        // The sync half of the automations contract: a (throttled) push of
        // the compressed 48-hour view on every foreground, and a queued
        // background refresh so the server's copy stays under its 24-hour
        // staleness line even when the app sits closed.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                Task { await calendarSync.syncIfNeeded() }
            case .background:
                calendarSync.scheduleBackgroundRefresh()
            default:
                break
            }
        }
        .backgroundTask(.appRefresh(CalendarSyncService.backgroundTaskId)) {
            await calendarSync.handleBackgroundRefresh()
        }
    }
}
