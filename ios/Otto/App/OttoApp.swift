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

    init() {
        FirebaseApp.configure()
        // EmailPasswordAuth is the Phase 0 AuthProvider. Sign in with Apple
        // becomes a second implementation of the same protocol later — this
        // line is the only one that changes. One instance feeds every model
        // so sign-in state is shared.
        let auth = EmailPasswordAuth()
        let tasksModel = TasksModel(auth: auth)
        let plansModel = PlansModel(auth: auth)
        _settings = State(initialValue: DebugModel(auth: auth))
        _tasks = State(initialValue: tasksModel)
        _plans = State(initialValue: plansModel)
        _conversation = State(
            initialValue: ConversationModel(auth: auth, tasksModel: tasksModel, plansModel: plansModel)
        )
        _memory = State(initialValue: MemoryModel(auth: auth))
    }

    var body: some Scene {
        WindowGroup {
            ConversationView(
                model: conversation,
                settings: settings,
                memory: memory,
                tasks: tasks,
                plans: plans
            )
                // Otto's stage is dark-first and monochrome; sheets inherit.
                .preferredColorScheme(.dark)
                .tint(.white)
        }
    }
}
