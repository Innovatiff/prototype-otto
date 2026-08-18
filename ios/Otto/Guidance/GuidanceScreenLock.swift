import UIKit

/// The phone sits on a bench three feet away — the screen must not sleep
/// mid-session. Balanced begin/end; ending always re-enables idle sleep.
@MainActor
enum GuidanceScreenLock {
    static func keepAwake(_ on: Bool) {
        UIApplication.shared.isIdleTimerDisabled = on
    }
}
