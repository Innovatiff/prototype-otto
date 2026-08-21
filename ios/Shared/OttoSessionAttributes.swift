import ActivityKit
import Foundation

/// The Live Activity for a running guided session — shared between the app
/// (which starts/updates/ends it) and the widget bundle (which renders it
/// on the Lock Screen and in the Dynamic Island).
struct OttoSessionAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var stepTitle: String
        /// 0-based step the user is on.
        var stepIndex: Int
        var totalSteps: Int
    }

    var sessionTitle: String
}
