import Foundation

/// The short phrases Otto says thousands of times. Synthesized once, replayed
/// at zero cost and near-zero latency.
///
/// Scaffolded here with the starter set; expands to ~200 later. The cache
/// itself (pre-rendering to .caf on first launch, <20ms playback) lands in
/// Step 5 — until then `Speaker.speak(clip:)` synthesizes the raw value live.
enum CachedClip: String, CaseIterable, Sendable {
    case acknowledged = "Understood."
    case working = "One moment."
    case listening = "Go ahead."
    case gotIt = "Got that."
    case tenSeconds = "Ten seconds."
    case timeUp = "Time."
    case nextStep = "Next step."
    case notSure = "I didn't catch that."
    case cantHelp = "I can't do that yet."
}
