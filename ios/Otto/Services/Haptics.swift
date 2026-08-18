import UIKit

/// Otto's touch. One vocabulary, used sparingly and consistently — the app
/// should feel alive, not buzzy. Generators are created once and kept
/// prepared; every call is fire-and-forget on the main actor.
@MainActor
enum Haptics {

    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let medium = UIImpactFeedbackGenerator(style: .medium)
    private static let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private static let soft = UIImpactFeedbackGenerator(style: .soft)
    private static let notify = UINotificationFeedbackGenerator()
    private static let select = UISelectionFeedbackGenerator()

    /// Small acknowledgments: control-bar buttons, cards appearing.
    static func tap() {
        light.impactOccurred()
        light.prepare()
    }

    /// Deliberate actions: the mic, starting a session, confirmations.
    static func press() {
        medium.impactOccurred()
        medium.prepare()
    }

    /// A step of real work landed: step advance, set done, timer zero.
    static func step() {
        rigid.impactOccurred()
        rigid.prepare()
    }

    /// The clock is almost out — paired with the "Ten seconds" clip.
    static func warning() {
        soft.impactOccurred(intensity: 1.0)
        soft.prepare()
    }

    /// The session (or a plan) finished — the big one.
    static func success() {
        notify.notificationOccurred(.success)
        notify.prepare()
    }

    /// Something needs attention: paused, an error surfaced.
    static func caution() {
        notify.notificationOccurred(.warning)
        notify.prepare()
    }

    /// Checkbox ticks and item-by-item movement.
    static func tick() {
        select.selectionChanged()
        select.prepare()
    }
}
