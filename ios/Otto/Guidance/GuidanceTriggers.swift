import Foundation

/// "Start my workout" — detected on device, exactly like the brief
/// trigger: the guided session needs the local runtime, never a server
/// turn.
enum GuidanceTriggers {

    /// Post-normalization forms (punctuation and apostrophes stripped,
    /// leading "otto"/"hey" fillers dropped by the classifier's normalize).
    private static let phrases: Set<String> = [
        "start my workout",
        "start the workout",
        "start my session",
        "start the session",
        "start todays session",
        "begin my workout",
        "begin the workout",
        "begin my session",
        "begin the session",
        "lets train",
        "time to train",
        "start my study session",
        "guide me through my session",
    ]

    /// Exact-utterance match only — "when should I start my workout" is a
    /// question for the model, not a trigger.
    static func matches(_ utterance: String) -> Bool {
        phrases.contains(GuidanceCommandClassifier.normalize(utterance))
    }
}
