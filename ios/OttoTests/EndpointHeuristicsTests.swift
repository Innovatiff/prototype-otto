import XCTest

@testable import Otto

/// Pins the semantic-completion heuristic that picks between the fast
/// endpoint (350ms) and the learned patience window. The user-facing rule:
/// an unfinished-sounding sentence must never be cut fast.
final class EndpointHeuristicsTests: XCTestCase {

    private func complete(_ text: String) -> Bool {
        Transcriber.isSemanticallyComplete(text)
    }

    func testHangingFragmentsHold() {
        XCTAssertFalse(complete("I don't"))
        XCTAssertFalse(complete("Remind me to"))
        XCTAssertFalse(complete("Add onions and"))
        XCTAssertFalse(complete("I need you to add"))
        XCTAssertFalse(complete("Text Marissa that I can't"))
        XCTAssertFalse(complete("Tell me when I"))
        XCTAssertFalse(complete("The thing is"))
    }

    func testCompleteSentencesFireFast() {
        XCTAssertTrue(complete("I don't eat pork"))
        XCTAssertTrue(complete("What do I need at Walmart"))
        XCTAssertTrue(complete("Remind me to call the dentist at three"))
        XCTAssertTrue(complete("Got the onions and the milk"))
        XCTAssertTrue(complete("Anything with terminal punctuation."))
    }

    func testShortAnswersCountAsComplete() {
        XCTAssertTrue(complete("Yes"))
        XCTAssertTrue(complete("yes."))
        XCTAssertTrue(complete("Nope"))
        XCTAssertTrue(complete("okay"))
        XCTAssertTrue(complete("Never mind"))
        XCTAssertTrue(complete("Morning"))
    }

    func testShortNonAnswersStillHold() {
        // Two words, not a known answer, no punctuation: wait for more.
        XCTAssertFalse(complete("I want"))
        XCTAssertFalse(complete("we should"))
        XCTAssertFalse(complete(""))
        XCTAssertFalse(complete("   "))
    }
}
