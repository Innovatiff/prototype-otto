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
    @State private var model: DebugModel

    init() {
        FirebaseApp.configure()
        // EmailPasswordAuth is the Phase 0 AuthProvider. Sign in with Apple
        // becomes a second implementation of the same protocol later — this
        // line is the only one that changes.
        _model = State(initialValue: DebugModel(auth: EmailPasswordAuth()))
    }

    var body: some Scene {
        WindowGroup {
            DebugView(model: model)
        }
    }
}
