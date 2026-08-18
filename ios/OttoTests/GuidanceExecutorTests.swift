import XCTest

@testable import Otto

/// Records everything an executor says or signals, in order.
private actor OutputRecorder: GuidanceOutputting {
    private(set) var events: [String] = []

    func speak(_ text: String) async { events.append("speak:\(text)") }
    func play(_ clip: CachedClip) async { events.append("clip:\(String(describing: clip))") }
    func stepCompleted() async { events.append("completed") }

    /// Polls until `count` events have arrived (timers are real, short).
    func waitFor(count: Int, timeout: TimeInterval = 4) async -> [String] {
        let deadline = Date().addingTimeInterval(timeout)
        while events.count < count && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return events
    }
}

final class GuidanceExecutorTests: XCTestCase {

    private func step(
        _ type: StepType,
        cue: String = "Brace and go.",
        target: StepTarget? = StepTarget(sets: 3, reps: 8, load: 20),
        id: String = "s1"
    ) -> Step {
        Step(id: id, type: type, title: "Step", cue: cue, target: target, completion: .manual)
    }

    // MARK: - TimedCore (pure, deterministic)

    func testTimedCoreWarningAndPauseMath() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var core = TimedCore(seconds: 60, now: t0)
        XCTAssertEqual(core.nextWakeup(now: t0).delay, 50, accuracy: 0.001)
        XCTAssertTrue(core.nextWakeup(now: t0).isWarning)
        XCTAssertEqual(core.remaining(now: t0.addingTimeInterval(20)), 40, accuracy: 0.001)

        // Pause freezes remaining regardless of the clock.
        core.pause(now: t0.addingTimeInterval(20))
        XCTAssertTrue(core.isPaused)
        XCTAssertEqual(core.remaining(now: t0.addingTimeInterval(500)), 40, accuracy: 0.001)
        // Resume re-anchors the deadline.
        core.resume(now: t0.addingTimeInterval(100))
        XCTAssertFalse(core.isPaused)
        XCTAssertEqual(core.remaining(now: t0.addingTimeInterval(100)), 40, accuracy: 0.001)

        core.markWarned()
        XCTAssertFalse(core.nextWakeup(now: t0.addingTimeInterval(100)).isWarning)
    }

    func testShortTimersNeverWarn() {
        let t0 = Date()
        let core = TimedCore(seconds: 10, now: t0)
        let wakeup = core.nextWakeup(now: t0)
        XCTAssertFalse(wakeup.isWarning)
        XCTAssertEqual(wakeup.delay, 10, accuracy: 0.001)
    }

    // MARK: - TimedExecutor (real, short timers)

    func testCountdownWarnsAnnouncesZeroAndAutoAdvances() async {
        let recorder = OutputRecorder()
        let timer = TimedExecutor(output: recorder)
        await timer.startCountdown(seconds: 0.5, warningLead: 0.2, minimumForWarning: 0.3)
        let events = await recorder.waitFor(count: 3)
        XCTAssertEqual(events, ["clip:tenSeconds", "clip:timeUp", "completed"])
    }

    func testDoneEndsTimerEarlyWithoutZeroClip() async {
        let recorder = OutputRecorder()
        let timer = TimedExecutor(output: recorder)
        await timer.begin(step(.timed, cue: "Twelve minutes. Heads down.", target: StepTarget(durationSec: 720)))
        let result = await timer.handleVoiceCommand(.next)
        XCTAssertEqual(result, .completed)
        try? await Task.sleep(for: .milliseconds(150))
        let events = await recorder.events
        XCTAssertEqual(events, ["speak:Twelve minutes. Heads down."], "no clips after an early done")
        let remaining = await timer.remainingSeconds
        XCTAssertNil(remaining)
    }

    func testPauseFreezesAndResumeFinishes() async {
        let recorder = OutputRecorder()
        let timer = TimedExecutor(output: recorder)
        await timer.startCountdown(seconds: 0.4, warningLead: 10, minimumForWarning: 12)
        XCTAssertEqual(await timer.handleVoiceCommand(.pause), .passToSession)
        try? await Task.sleep(for: .milliseconds(600))
        let frozen = await recorder.events
        XCTAssertEqual(frozen, [], "a paused timer announces nothing")
        let held = await timer.remainingSeconds
        XCTAssertEqual(held ?? 0, 0.4, accuracy: 0.15)

        XCTAssertEqual(await timer.handleVoiceCommand(.resume), .passToSession)
        let events = await recorder.waitFor(count: 2)
        XCTAssertEqual(events, ["clip:timeUp", "completed"])
    }

    // MARK: - CountedExecutor

    func testSetsFlowWithRestHandoff() async {
        let recorder = OutputRecorder()
        let counted = CountedExecutor(output: recorder, restSeconds: 0.3)
        await counted.begin(step(.counted))
        var events = await recorder.events
        XCTAssertEqual(events, ["speak:3 sets of 8 at 20 kilos.", "speak:Brace and go."])

        // Set 1 done → rest runs → "Time." → next set called.
        XCTAssertEqual(await counted.handleVoiceCommand(.next), .handled)
        events = await recorder.waitFor(count: 4)
        XCTAssertEqual(Array(events.suffix(2)), ["clip:timeUp", "speak:Set 2 of 3."])

        // Set 2 done → rest → last set.
        XCTAssertEqual(await counted.handleVoiceCommand(.next), .handled)
        events = await recorder.waitFor(count: 6)
        XCTAssertEqual(Array(events.suffix(2)), ["clip:timeUp", "speak:Last set."])

        // Last set done → the step completes; nothing more is spoken.
        XCTAssertEqual(await counted.handleVoiceCommand(.next), .completed)
    }

    func testDoneDuringRestSkipsAheadToTheNextSet() async {
        let recorder = OutputRecorder()
        let counted = CountedExecutor(output: recorder, restSeconds: 30)
        await counted.begin(step(.counted))
        _ = await counted.handleVoiceCommand(.next)     // set 1 done, rest starts
        XCTAssertEqual(await counted.handleVoiceCommand(.next), .handled)
        let events = await recorder.events
        // Straight to the set call — no "Time." clip from a cancelled rest.
        XCTAssertEqual(events.last, "speak:Set 2 of 3.")
        XCTAssertFalse(events.contains("clip:timeUp"))
    }

    func testCountedAnswersTimeLeftAndPassesSessionCommands() async {
        let recorder = OutputRecorder()
        let counted = CountedExecutor(output: recorder, restSeconds: 30)
        await counted.begin(step(.counted))
        XCTAssertEqual(await counted.handleVoiceCommand(.timeLeft), .handled)
        var events = await recorder.events
        XCTAssertEqual(events.last, "speak:Set 1 of 3.")

        _ = await counted.handleVoiceCommand(.next)     // rest running
        XCTAssertEqual(await counted.handleVoiceCommand(.timeLeft), .handled)
        events = await recorder.events
        XCTAssertTrue(events.last?.hasSuffix("left.") ?? false)

        XCTAssertEqual(await counted.handleVoiceCommand(.skip), .passToSession)
        XCTAssertEqual(await counted.handleVoiceCommand(.logValue("135 pounds")), .passToSession)
        await counted.cancel()
    }

    func testReferenceWeightSpeaksWithTheTarget() async {
        let recorder = OutputRecorder()
        let counted = CountedExecutor(output: recorder, restSeconds: 30, reference: "135 pounds")
        await counted.begin(step(.counted))
        let events = await recorder.events
        XCTAssertEqual(events, [
            "speak:3 sets of 8 at 20 kilos.",
            "speak:Last time: 135 pounds.",
            "speak:Brace and go.",
        ])
        await counted.cancel()
    }

    func testStatusLinesAnchorTheReturnFromAQuestion() async {
        let recorder = OutputRecorder()
        let counted = CountedExecutor(output: recorder, restSeconds: 30)
        await counted.begin(step(.counted))
        let anchor = await counted.statusLine()
        XCTAssertEqual(anchor, "Set 1 of 3, 8 reps.")

        let checklist = ChecklistExecutor(output: recorder)
        await checklist.begin(step(.checklist, cue: "Knife. Board. Towel.", target: nil))
        _ = await checklist.handleVoiceCommand(.next)
        let item = await checklist.statusLine()
        XCTAssertEqual(item, "Item 2 of 3.")

        let prompt = PromptExecutor(output: recorder)
        await prompt.begin(step(.prompt, cue: "Pat dry.", target: nil))
        let none = await prompt.statusLine()
        XCTAssertNil(none, "a prompt has no position worth speaking")
    }

    // MARK: - ChecklistExecutor

    func testChecklistReadsOneItemAtATime() async {
        let recorder = OutputRecorder()
        let checklist = ChecklistExecutor(output: recorder)
        await checklist.begin(
            step(.checklist, cue: "Chicken thighs. Soy sauce. Honey and garlic.", target: nil)
        )
        var events = await recorder.events
        XCTAssertEqual(events, ["speak:Chicken thighs."], "never the whole list at once")

        XCTAssertEqual(await checklist.handleVoiceCommand(.next), .handled)
        XCTAssertEqual(await checklist.handleVoiceCommand(.timeLeft), .handled)
        events = await recorder.events
        XCTAssertEqual(Array(events.suffix(2)), ["speak:Soy sauce.", "speak:Item 2 of 3."])

        XCTAssertEqual(await checklist.handleVoiceCommand(.next), .handled)
        XCTAssertEqual(await checklist.handleVoiceCommand(.next), .completed)
    }

    // MARK: - PromptExecutor

    func testPromptSpeaksOnceAndWaits() async {
        let recorder = OutputRecorder()
        let prompt = PromptExecutor(output: recorder)
        await prompt.begin(step(.prompt, cue: "Pat the salmon dry.", target: nil))
        XCTAssertEqual(await prompt.handleVoiceCommand(.repeatCue), .handled)
        let events = await recorder.events
        XCTAssertEqual(events, ["speak:Pat the salmon dry.", "speak:Pat the salmon dry."])
        XCTAssertEqual(await prompt.handleVoiceCommand(.next), .completed)
        XCTAssertEqual(await prompt.handleVoiceCommand(.stop), .passToSession)
    }

    // MARK: - Phrases and progression math

    func testPhrases() {
        XCTAssertEqual(
            GuidancePhrases.targetLine(StepTarget(sets: 3, reps: 8, load: 22.5)),
            "3 sets of 8 at 22.5 kilos."
        )
        XCTAssertEqual(GuidancePhrases.targetLine(StepTarget(reps: 12)), "12 reps.")
        XCTAssertNil(GuidancePhrases.targetLine(StepTarget(durationSec: 300)))
        XCTAssertNil(GuidancePhrases.targetLine(nil))
        XCTAssertEqual(GuidancePhrases.setLine(current: 2, total: 3), "Set 2 of 3.")
        XCTAssertEqual(GuidancePhrases.setLine(current: 3, total: 3), "Last set.")
        XCTAssertEqual(GuidancePhrases.remainingLine(seconds: 90), "1 minute 30 left.")
        XCTAssertEqual(GuidancePhrases.remainingLine(seconds: 60), "1 minute left.")
        XCTAssertEqual(GuidancePhrases.remainingLine(seconds: 45), "45 seconds left.")
        XCTAssertEqual(
            GuidancePhrases.checklistItems(from: "One line only"),
            ["One line only."]
        )
        XCTAssertEqual(
            GuidancePhrases.checklistItems(from: "First.\nSecond thing. Third?"),
            ["First.", "Second thing.", "Third?"]
        )
    }

    func testProgressionResolution() {
        let base = step(.counted)
        let deload = GuidanceMath.resolved(
            step: base,
            progression: Progression(loadMultiplier: 0.6, note: "deload")
        )
        XCTAssertEqual(deload.target?.load, 12)
        XCTAssertEqual(deload.cue, base.cue, "cue stays verbatim, always")

        let smallBump = GuidanceMath.resolved(
            step: base,
            progression: Progression(loadMultiplier: 1.025)
        )
        XCTAssertEqual(smallBump.target?.load, 20.5, "loads round to the nearest half kilo")

        let repsFloor = GuidanceMath.resolved(
            step: base,
            progression: Progression(repsDelta: -20, setsDelta: 1)
        )
        XCTAssertEqual(repsFloor.target?.reps, 1)
        XCTAssertEqual(repsFloor.target?.sets, 4)

        XCTAssertEqual(GuidanceMath.resolved(step: base, progression: nil), base)
    }

    func testFactoryDispatchesByStepType() {
        let recorder = OutputRecorder()
        XCTAssertTrue(StepExecutors.make(for: step(.timed), output: recorder) is TimedExecutor)
        XCTAssertTrue(StepExecutors.make(for: step(.counted), output: recorder) is CountedExecutor)
        XCTAssertTrue(StepExecutors.make(for: step(.checklist), output: recorder) is ChecklistExecutor)
        XCTAssertTrue(StepExecutors.make(for: step(.prompt), output: recorder) is PromptExecutor)
    }
}
