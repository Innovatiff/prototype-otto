import SwiftUI

/// Simple illustrations for plan content: every step and session gets a
/// glyph in a soft color, chosen deterministically from its words — a
/// dumbbell for the squat, a fork for the rice, a book for the reading.
/// Pure and table-driven so the mapping is testable and easy to grow.
enum StepArt {

    struct Art: Equatable {
        let symbol: String
        let paletteIndex: Int
    }

    /// Keyword → art, checked in order; first hit wins. Multi-word phrases
    /// sit above their fragments ("warm up" before "up").
    private static let table: [(keywords: [String], symbol: String, palette: Int)] = [
        // Strength & gym
        (["squat", "deadlift", "bench", "press", "row", "curl", "lunge", "dumbbell", "barbell", "lift", "pull up", "pullup", "push up", "pushup", "chin up"], "dumbbell.fill", 3),
        (["warm up", "warmup", "stretch", "mobility", "cool down", "cooldown", "foam"], "figure.flexibility", 1),
        (["run", "jog", "sprint", "treadmill"], "figure.run", 0),
        (["walk", "steps"], "figure.walk", 1),
        (["bike", "cycling", "spin"], "figure.outdoor.cycle", 0),
        (["swim"], "figure.pool.swim", 0),
        (["yoga", "pose"], "figure.yoga", 2),
        (["plank", "core", "abs", "crunch"], "figure.core.training", 4),
        (["rest", "recover", "breathe", "breathing"], "moon.zzz.fill", 2),
        // Kitchen
        (["rice", "pasta", "noodle", "grain"], "fork.knife", 5),
        (["cook", "meal", "recipe", "chop", "prep the", "kitchen", "bake", "roast", "simmer"], "frying.pan.fill", 3),
        (["coffee", "tea"], "cup.and.saucer.fill", 3),
        (["water", "hydrate"], "drop.fill", 0),
        // Learning & work
        (["read", "chapter", "book"], "book.fill", 0),
        (["write", "journal", "notes", "essay"], "pencil.and.outline", 4),
        (["review", "recall", "quiz", "flashcard", "practice test"], "checkmark.seal.fill", 1),
        (["study", "learn", "lesson", "course", "vocab"], "graduationcap.fill", 2),
        (["listen", "podcast", "audio"], "headphones", 2),
        (["language", "spanish", "french", "japanese"], "character.bubble.fill", 4),
        (["plan the", "planning", "schedule", "calendar"], "calendar", 0),
        (["email", "inbox", "messages"], "envelope.fill", 0),
        (["deep work", "focus", "shutdown", "wind down"], "brain.head.profile", 2),
        (["meditate", "meditation", "mindful"], "leaf.fill", 1),
        (["timer", "minutes of", "hold"], "timer", 5),
        (["check", "checklist", "gear", "pack", "setup", "set up"], "checklist", 1),
    ]

    /// Art for a piece of plan content. `domain` breaks ties when the
    /// words say nothing ("Session B" in a fitness plan is still a workout).
    static func art(for title: String, cue: String? = nil, domain: String? = nil) -> Art {
        let haystack = "\(title) \(cue ?? "")".lowercased()
        for entry in table {
            if entry.keywords.contains(where: { haystack.contains($0) }) {
                return Art(symbol: entry.symbol, paletteIndex: entry.palette)
            }
        }
        switch domain {
        case "fitness":
            return Art(symbol: "dumbbell.fill", paletteIndex: 3)
        case "learning":
            return Art(symbol: "book.fill", paletteIndex: 0)
        case "productivity":
            return Art(symbol: "brain.head.profile", paletteIndex: 2)
        default:
            return Art(symbol: "sparkles", paletteIndex: 2)
        }
    }

    static func color(for art: Art) -> Color {
        OttoTheme.palette[art.paletteIndex % OttoTheme.palette.count]
    }
}

/// The illustration itself: a rounded tile, soft color field, full-color
/// glyph. Small in rows, large on the guided-session screen.
struct StepIllustration: View {
    let art: StepArt.Art
    var size: CGFloat = 44

    var body: some View {
        let color = StepArt.color(for: art)
        Image(systemName: art.symbol)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(
                color.opacity(0.16),
                in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            )
            .accessibilityHidden(true)
    }
}
