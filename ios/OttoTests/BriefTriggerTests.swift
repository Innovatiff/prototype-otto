import XCTest

@testable import Otto

final class BriefTriggerTests: XCTestCase {

    func testSpecPhrasesTrigger() {
        XCTAssertTrue(BriefTriggers.matches("Get me ready for today"))
        XCTAssertTrue(BriefTriggers.matches("what's expected today?"))
        XCTAssertTrue(BriefTriggers.matches("Brief me."))
        XCTAssertTrue(BriefTriggers.matches("Otto, brief me on the morning"))
        XCTAssertTrue(BriefTriggers.matches("What's my day look like"))
        XCTAssertTrue(BriefTriggers.matches("run my brief"))
    }

    func testOrdinaryUtterancesDoNot() {
        XCTAssertFalse(BriefTriggers.matches("Give me a brief summary of the meeting"))
        XCTAssertFalse(BriefTriggers.matches("Get me ready for the party"))
        XCTAssertFalse(BriefTriggers.matches("What do I need at Walmart"))
        XCTAssertFalse(BriefTriggers.matches("Remind me to call the dentist"))
        XCTAssertFalse(BriefTriggers.matches(""))
    }
}
