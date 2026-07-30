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

    init() {
        FirebaseApp.configure()
        // EmailPasswordAuth is the Phase 0 AuthProvider. Sign in with Apple
        // becomes a second implementation of the same protocol later — this
        // line is the only one that changes. One instance feeds both models
        // so sign-in state is shared.
        let auth = EmailPasswordAuth()
        _settings = State(initialValue: DebugModel(auth: auth))
        _conversation = State(initialValue: ConversationModel(auth: auth))
    }

    var body: some Scene {
        WindowGroup {
            ConversationView(model: conversation, settings: settings)
        }
    }
}
