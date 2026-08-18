import Foundation

/// The persisted truth of a running guided session — written to disk on
/// EVERY transition, so a killed app can offer to pick up exactly where the
/// user left off. Codable via OttoCoding (ISO dates).
struct GuidanceSnapshot: Codable, Equatable, Sendable {
    var planId: String
    var sessionId: String
    /// Denormalized so the resume offer can speak without fetching the plan.
    var sessionTitle: String
    var totalSteps: Int
    /// The step the user is ON (0-based). Steps below it are behind them.
    var currentStepIndex: Int
    var startedAt: Date
    /// Stamped on every persist; resume offers expire on staleness.
    var updatedAt: Date
    var completedSteps: [String]
    var skippedSteps: [String]
    /// stepId → what the user actually did, verbatim ("135 pounds",
    /// "8 reps"). Kept raw and lossless; Step 8's overload logic parses.
    var loggedValues: [String: String]
    var pausedAt: Date?
}

extension GuidanceSnapshot {
    /// "You were 4 steps into Upper A. Pick up where you left off?"
    var resumeOfferLine: String {
        if currentStepIndex <= 0 {
            return "You'd just started \(sessionTitle). Pick up where you left off?"
        }
        let steps = currentStepIndex == 1 ? "1 step" : "\(currentStepIndex) steps"
        return "You were \(steps) into \(sessionTitle). Pick up where you left off?"
    }
}
