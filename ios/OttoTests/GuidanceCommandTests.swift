import XCTest

@testable import Otto

/// Pins the on-device command vocabulary — every spec line, the deliberate
/// done-vs-I'm-done split, value extraction, and the near-misses that must
/// fall through to off-script instead of firing a command.
final class GuidanceCommandTests: XCTestCase {

    private func classify(_ text: String) -> VoiceCommand? {
        GuidanceCommandClassifier.classify(text)
    }

    func testTheSpecVocabulary() {
        // next / done / finished → complete current step
        XCTAssertEqual(classify("next"), .next)
        XCTAssertEqual(classify("Done."), .next)
        XCTAssertEqual(classify("finished"), .next)
        // repeat / say that again
        XCTAssertEqual(classify("repeat"), .repeatCue)
        XCTAssertEqual(classify("say that again"), .repeatCue)
        // how much longer / time left
        XCTAssertEqual(classify("How much longer?"), .timeLeft)
        XCTAssertEqual(classify("time left"), .timeLeft)
        // skip
        XCTAssertEqual(classify("skip"), .skip)
        // pause / hold on
        XCTAssertEqual(classify("pause"), .pause)
        XCTAssertEqual(classify("hold on"), .pause)
        // resume / continue
        XCTAssertEqual(classify("resume"), .resume)
        XCTAssertEqual(classify("continue"), .resume)
        // back
        XCTAssertEqual(classify("back"), .back)
        XCTAssertEqual(classify("go back"), .back)
        // I'm done / stop → end session
        XCTAssertEqual(classify("I'm done"), .stop)
        XCTAssertEqual(classify("stop"), .stop)
        // add weight / used <N> pounds
        XCTAssertEqual(classify("add weight"), .logValue("add weight"))
        XCTAssertEqual(classify("used 135 pounds"), .logValue("135 pounds"))
    }

    func testDoneVersusImDoneIsTheLine() {
        XCTAssertEqual(classify("done"), .next, "a set is done")
        XCTAssertEqual(classify("I'm done"), .stop, "the session is over")
        XCTAssertEqual(classify("finished"), .next)
        XCTAssertEqual(classify("I am finished"), .stop)
    }

    func testFillersAndPunctuationAreStripped() {
        XCTAssertEqual(classify("Okay, next."), .next)
        XCTAssertEqual(classify("Otto, pause"), .pause)
        XCTAssertEqual(classify("hey otto skip please"), .skip)
        XCTAssertEqual(classify("Um, how much longer?"), .timeLeft)
    }

    func testValueLogging() {
        XCTAssertEqual(classify("used 22.5 kilos"), .logValue("22.5 kilos"))
        XCTAssertEqual(classify("I did 60 kg"), .logValue("60 kilos"))
        XCTAssertEqual(classify("that was 135 lbs"), .logValue("135 pounds"))
        XCTAssertEqual(classify("135 pounds"), .logValue("135 pounds"))
        XCTAssertEqual(classify("used 135"), .logValue("135"))
        XCTAssertEqual(classify("went up to 45 pounds"), .logValue("45 pounds"))
    }

    func testQuestionsAndChatterFallThroughToOffScript() {
        // Questions with weights are QUESTIONS — never logs.
        XCTAssertNil(classify("can I do 20 pounds instead?"))
        XCTAssertNil(classify("should I add 5 kilos?"))
        XCTAssertNil(classify("how much salt?"))
        XCTAssertNil(classify("is this the right grip?"))
        // Gym chatter and partial phrases fire nothing.
        XCTAssertNil(classify("nice one man"))
        XCTAssertNil(classify("that was heavy"))
        XCTAssertNil(classify("skip the small talk we were saying"))
        XCTAssertNil(classify(""))
        // A number without a log-verb isn't a log.
        XCTAssertNil(classify("my friend benches 200 pounds easy"))
    }

    func testTimeLeftBeatsTheQuestionGuard() {
        // Question-shaped, but in the vocabulary — must classify.
        XCTAssertEqual(classify("how long"), .timeLeft)
        XCTAssertEqual(classify("what's left"), .timeLeft)
    }

    func testOffScriptGateEscalatesQuestionsNotChatter() {
        let escalates = [
            "how much salt",
            "can I substitute chicken",
            "is this the right grip?",
            "should my back be flat",
            "otto what do I do with my elbows",
            "hey otto, is this too heavy",
            "that felt weird?",
        ]
        for utterance in escalates {
            XCTAssertTrue(
                GuidanceCommandClassifier.looksLikeQuestion(utterance),
                "\(utterance) should escalate"
            )
        }
        let drops = [
            "nice one man",
            "that was heavy",
            "hey nice set",
            "one more song",
            "",
        ]
        for utterance in drops {
            XCTAssertFalse(
                GuidanceCommandClassifier.looksLikeQuestion(utterance),
                "\(utterance) must never make Otto speak uninvited"
            )
        }
    }

    func testSessionStartTriggers() {
        XCTAssertTrue(GuidanceTriggers.matches("Start my workout"))
        XCTAssertTrue(GuidanceTriggers.matches("start today's session"))
        XCTAssertTrue(GuidanceTriggers.matches("Otto, start my session."))
        XCTAssertTrue(GuidanceTriggers.matches("let's train"))
        XCTAssertFalse(GuidanceTriggers.matches("when should I start my workout"))
        XCTAssertFalse(GuidanceTriggers.matches("start a new plan"))
    }

    func testChecklistAndSessionEnds() {
        XCTAssertEqual(classify("check"), .next)
        XCTAssertEqual(classify("that's enough"), .stop)
        XCTAssertEqual(classify("end the workout"), .stop)
        XCTAssertEqual(classify("call it"), .stop)
    }
}
