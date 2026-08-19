import FirebaseCore
import FirebaseMessaging
import SwiftUI
import UIKit

/// APNs plumbing SwiftUI cannot express: the system hands the APNs device
/// token to the app delegate, and FCM needs it before it can mint its own
/// registration token.
@MainActor
final class PushAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Messaging.messaging().apnsToken = deviceToken
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: any Error
    ) {
        // Simulators and denied capability land here; pushes just don't
        // arrive, and everything else works.
        print("PushAppDelegate: APNs registration failed: \(error.localizedDescription)")
    }
}

/// App entry point.
///
/// `FirebaseApp.configure()` here is the SwiftUI equivalent of the UIKit
/// AppDelegate `didFinishLaunchingWithOptions` pattern from the Firebase docs.
/// It reads GoogleService-Info.plist from the bundle — place that file at
/// ios/Otto/GoogleService-Info.plist (it is gitignored, never committed).
@main
struct OttoApp: App {
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var pushAppDelegate
    @State private var conversation: ConversationModel
    @State private var settings: DebugModel
    @State private var memory: MemoryModel
    @State private var tasks: TasksModel
    @State private var plans: PlansModel
    @State private var calendarSync: CalendarSyncService
    @State private var automations: AutomationsModel
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
        _automations = State(initialValue: AutomationsModel(auth: auth))
    }

    var body: some Scene {
        WindowGroup {
            ConversationView(
                model: conversation,
                settings: settings,
                memory: memory,
                tasks: tasks,
                plans: plans,
                calendarSync: calendarSync,
                automations: automations
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
