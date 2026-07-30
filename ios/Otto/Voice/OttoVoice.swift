import AVFoundation

/// Picks the system voice Otto speaks with.
///
/// The synthesizer's implicit default is usually the lowest-quality compact
/// voice. Ranking the installed voices by quality (premium > enhanced >
/// default) uses the best one the device has — including any the user
/// downloads under Settings → Accessibility → Spoken Content → Voices —
/// while skipping novelty and personal voices.
///
/// Both the live speaker and the clip cache resolve their voice here, and
/// the cache manifest keys on the identifier, so cached and live audio can
/// never diverge: a new best voice invalidates and re-renders the clips.
enum OttoVoice {

    /// The best installed voice for the current language, or nil to let the
    /// synthesizer fall back to its default.
    static func best() -> AVSpeechSynthesisVoice? {
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
        let usable = AVSpeechSynthesisVoice.speechVoices().filter { voice in
            !voice.voiceTraits.contains(.isNoveltyVoice)
                && !voice.voiceTraits.contains(.isPersonalVoice)
        }
        let exact = usable.filter { $0.language == language }
        let base = language.split(separator: "-").first.map(String.init) ?? language
        let related = usable.filter { $0.language.hasPrefix(base) }
        let pool = exact.isEmpty ? related : exact
        return pool.max { $0.quality.rawValue < $1.quality.rawValue }
    }
}
