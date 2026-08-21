import XCTest

@testable import Otto

/// The illustration mapping: the right glyph for the right words, the
/// domain fallback when the words say nothing, and determinism.
final class StepArtTests: XCTestCase {

    func testKeywordsPickTheObviousGlyph() {
        XCTAssertEqual(StepArt.art(for: "Back Squat").symbol, "dumbbell.fill")
        XCTAssertEqual(StepArt.art(for: "Bench Press 3×8").symbol, "dumbbell.fill")
        XCTAssertEqual(StepArt.art(for: "Cook the rice").symbol, "fork.knife")
        XCTAssertEqual(StepArt.art(for: "Prep the vegetables").symbol, "frying.pan.fill")
        XCTAssertEqual(StepArt.art(for: "Read chapter 4").symbol, "book.fill")
        XCTAssertEqual(StepArt.art(for: "Warm up").symbol, "figure.flexibility")
        XCTAssertEqual(StepArt.art(for: "Easy run").symbol, "figure.run")
        XCTAssertEqual(StepArt.art(for: "Rest").symbol, "moon.zzz.fill")
        XCTAssertEqual(StepArt.art(for: "Recall practice", cue: "No notes.").symbol, "checkmark.seal.fill")
    }

    func testCueWordsCountToo() {
        let art = StepArt.art(for: "Block A", cue: "Three sets of goblet squats, slow down.")
        XCTAssertEqual(art.symbol, "dumbbell.fill")
    }

    func testDomainFallbackWhenWordsSayNothing() {
        XCTAssertEqual(StepArt.art(for: "Session B", domain: "fitness").symbol, "dumbbell.fill")
        XCTAssertEqual(StepArt.art(for: "Block 2", domain: "learning").symbol, "book.fill")
        XCTAssertEqual(StepArt.art(for: "Block 2", domain: "productivity").symbol, "brain.head.profile")
        XCTAssertEqual(StepArt.art(for: "Step 3", domain: "cooking").symbol, "frying.pan.fill")
        XCTAssertEqual(StepArt.art(for: "Step 3", domain: "repair").symbol, "wrench.and.screwdriver.fill")
        XCTAssertEqual(StepArt.art(for: "Step 3", domain: "errand").symbol, "bag.fill")
        XCTAssertEqual(StepArt.art(for: "Step 3", domain: "chores").symbol, "house.fill")
        XCTAssertEqual(StepArt.art(for: "Block 2").symbol, "sparkles")
    }

    func testWalkthroughKeywordsPickTheirGlyphs() {
        XCTAssertEqual(StepArt.art(for: "Loosen the lug nuts").symbol, "wrench.and.screwdriver.fill")
        XCTAssertEqual(StepArt.art(for: "Change the tire").symbol, "wrench.and.screwdriver.fill")
        XCTAssertEqual(StepArt.art(for: "Check under the hood").symbol, "car.fill")
        XCTAssertEqual(StepArt.art(for: "Buy groceries").symbol, "bag.fill")
        XCTAssertEqual(StepArt.art(for: "Simmer the sauce").symbol, "frying.pan.fill")
        XCTAssertEqual(StepArt.art(for: "Wipe down the counters").symbol, "bubbles.and.sparkles")
        // "cardio" must never match the "car " keyword.
        XCTAssertEqual(StepArt.art(for: "Cardio intervals").symbol, "figure.run")
    }

    func testDeterministicAndPaletteBounded() {
        let first = StepArt.art(for: "Deadlift", cue: "Brace hard.", domain: "fitness")
        let second = StepArt.art(for: "Deadlift", cue: "Brace hard.", domain: "fitness")
        XCTAssertEqual(first, second)
        XCTAssertTrue((0..<OttoTheme.palette.count).contains(first.paletteIndex))
    }
}
