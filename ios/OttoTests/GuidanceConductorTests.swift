import XCTest

@testable import Otto

/// Records everything the conductor says and plays, in order, plus the
/// events the UI would receive.
private actor GuidanceRecorder {
    private(set) var lines: [String] = []
    private(set) var events: [String] = []

    func say(_ text: String) { lines.append("say:\(text)") }
    func clip(_ clip: CachedClip) { lines.append("clip:\(String(describing: clip))") }
    func event(_ event: GuidanceEvent) {
        switch event {
        case .began(let title, let resumed):
            events.append("began:\(title):\(resumed)")
        case .stepChanged(let index, let total, _):
            events.append("step:\(index)/\(total)")
        case .resting:
            events.append("resting")
        case .paused(let paused):
            events.append("paused:\(paused)")
        case .finished(let early, _):
            events.append("finished:\(early)")
        }
    }

    func waitForLines(count: Int, timeout: TimeInterval = 6) async -> [String] {
        let deadline = Date().addingTimeInterval(timeout)
        while lines.count < count && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return lines
    }

    func waitForEvent(_ needle: String, timeout: TimeInterval = 6) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !events.contains(needle) && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return events.contains(needle)
    }
}

/// Records backstop arms/cancels in order.
private actor FakeBackstop: GuidanceBackstopping {
    private(set) var log: [String] = []

    func arm(fireIn: TimeInterval, stepTitle: String) async {
        log.append("arm:\(stepTitle)")
    }

    func cancel() async {
        log.append("cancel")
    }

    func waitFor(count: Int, timeout: TimeInterval = 6) async -> [String] {
        let deadline = Date().addingTimeInterval(timeout)
        while log.count < count && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return log
    }
}

final class GuidanceConductorTests: XCTestCase {

    private var directory: URL!
    private var store: GuidanceStore!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appending(path: "conductor-tests-\(UUID().uuidString)")
        store = GuidanceStore(directory: directory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func template(steps: [Step]) -> Session {
        Session(id: "upper-a", title: "Upper A", estimatedMinutes: 45, steps: steps)
    }

    private var threeStepTemplate: Session {
        template(steps: [
            Step(id: "s1", type: .prompt, title: "Prep", cue: "Pat the salmon dry.", completion: .manual),
            Step(
                id: "s2", type: .counted, title: "Press", cue: "Brace and go.",
                target: StepTarget(sets: 2, reps: 8, load: 20), completion: .manual
            ),
            Step(
                id: "s3", type: .timed, title: "Hold", cue: "Hold one minute.",
                target: StepTarget(durationSec: 1), completion: .auto
            ),
        ])
    }

    private func makeConductor(
        template: Session,
        progression: Progression? = nil,
        resumeFrom: GuidanceSnapshot? = nil,
        recorder: GuidanceRecorder
    ) -> GuidanceConductor {
        GuidanceConductor(
            planId: "p1",
            template: template,
            progression: progression,
            store: store,
            resumeFrom: resumeFrom,
            restOverride: 0.25,
            speak: { await recorder.say($0) },
            play: { await recorder.clip($0) }
        )
    }

    private func watch(_ conductor: GuidanceConductor, into recorder: GuidanceRecorder) async {
        let stream = await conductor.events()
        Task {
            for await event in stream {
                await recorder.event(event)
            }
        }
    }

    // MARK: - The full hands-free walk

    func testFullSessionSpeaksCuesOnceWithClipsAndSilence() async {
        let recorder = GuidanceRecorder()
        let conductor = makeConductor(
            template: threeStepTemplate,
            progression: Progression(loadMultiplier: 1.05),
            recorder: recorder
        )
        await watch(conductor, into: recorder)
        await conductor.start()

        var lines = await recorder.waitForLines(count: 2)
        XCTAssertEqual(Array(lines.prefix(2)), [
            "say:Upper A. 3 steps, about 45 minutes.",
            "say:Pat the salmon dry.",
        ])

        // Prompt done → counted begins with the RESOLVED target (20 × 1.05
        // = 21) and the cue verbatim, exactly once.
        await conductor.handle(.next)
        lines = await recorder.waitForLines(count: 4)
        XCTAssertEqual(Array(lines.suffix(2)), [
            "say:2 sets of 8 at 21 kilos.",
            "say:Brace and go.",
        ])

        // Set 1 done → inner rest → "Time." → last set called.
        await conductor.handle(.next)
        lines = await recorder.waitForLines(count: 6)
        XCTAssertEqual(Array(lines.suffix(2)), ["clip:timeUp", "say:Last set."])

        // Last set done → BETWEEN-STEP rest (counted work earns one) → the
        // timed step's cue → its second runs out → session complete.
        await conductor.handle(.next)
        lines = await recorder.waitForLines(count: 11)
        XCTAssertEqual(Array(lines.suffix(5)), [
            "clip:rest",
            "clip:timeUp",
            "say:Hold one minute.",
            "clip:timeUp",
            "clip:sessionDone",
        ])

        let finished = await recorder.waitForEvent("finished:false")
        XCTAssertTrue(finished)
        let events = await recorder.events
        XCTAssertEqual(events.first, "began:Upper A:false")
        XCTAssertTrue(events.contains("step:0/3"))
        XCTAssertTrue(events.contains("resting"))
        XCTAssertTrue(events.contains("step:2/3"))
        XCTAssertNil(store.load(), "a finished session leaves no resume file")
    }

    // MARK: - Resume

    func testResumeSpeaksPickupIntroAndStartsAtSavedStep() async {
        let recorder = GuidanceRecorder()
        let snapshot = GuidanceSnapshot(
            planId: "p1", sessionId: "upper-a", sessionTitle: "Upper A", totalSteps: 3,
            currentStepIndex: 1, startedAt: Date(), updatedAt: Date(),
            completedSteps: ["s1"], skippedSteps: [], loggedValues: [:], pausedAt: nil
        )
        let conductor = makeConductor(
            template: threeStepTemplate, resumeFrom: snapshot, recorder: recorder
        )
        await conductor.start()
        let lines = await recorder.waitForLines(count: 3)
        XCTAssertEqual(lines[0], "say:Upper A, picking up at step 2 of 3.")
        XCTAssertEqual(Array(lines.suffix(2)), [
            "say:2 sets of 8 at 20 kilos.",
            "say:Brace and go.",
        ])
    }

    // MARK: - Session-level commands

    func testSkipBackLogAndStop() async {
        let recorder = GuidanceRecorder()
        let conductor = makeConductor(template: threeStepTemplate, recorder: recorder)
        await watch(conductor, into: recorder)
        await conductor.start()
        _ = await recorder.waitForLines(count: 2)

        // Skip the prompt → counted begins.
        await conductor.handle(.skip)
        var lines = await recorder.waitForLines(count: 5)
        XCTAssertEqual(lines[2], "clip:skipped")
        XCTAssertEqual(Array(lines.suffix(2)), [
            "say:2 sets of 8 at 20 kilos.",
            "say:Brace and go.",
        ])

        // Back → the prompt again, un-marked; back again → first-step clip.
        await conductor.handle(.back)
        lines = await recorder.waitForLines(count: 7)
        XCTAssertEqual(Array(lines.suffix(2)), ["clip:goingBack", "say:Pat the salmon dry."])
        await conductor.handle(.back)
        lines = await recorder.waitForLines(count: 8)
        XCTAssertEqual(lines.last, "clip:firstStepAlready")

        // Log a value, then stop early: saved, spoken, event emitted.
        await conductor.handle(.logValue("135 pounds"))
        lines = await recorder.waitForLines(count: 9)
        XCTAssertEqual(lines.last, "clip:logged")
        await conductor.handle(.stop)
        lines = await recorder.waitForLines(count: 10)
        XCTAssertEqual(lines.last, "clip:stoppedEarly")
        let finished = await recorder.waitForEvent("finished:true")
        XCTAssertTrue(finished)
        let snapshot = await conductor.currentSnapshot()
        XCTAssertEqual(snapshot.loggedValues["s1"], "135 pounds")
        XCTAssertEqual(snapshot.skippedSteps, [], "back un-marked the skip")
        XCTAssertNil(store.load())
    }

    // MARK: - The notification backstop

    func testBackstopArmsAndClearsAroundTimerLifecycle() async {
        let recorder = GuidanceRecorder()
        let backstop = FakeBackstop()
        let conductor = GuidanceConductor(
            planId: "p1",
            template: template(steps: [
                Step(
                    id: "t1", type: .timed, title: "Hold", cue: "Hold.",
                    target: StepTarget(durationSec: 1), completion: .auto
                )
            ]),
            progression: nil,
            store: store,
            backstop: backstop,
            restOverride: 0.25,
            speak: { await recorder.say($0) },
            play: { await recorder.clip($0) }
        )
        await conductor.start()
        var log = await backstop.waitFor(count: 1)
        XCTAssertEqual(log, ["arm:Hold"], "a running timer arms its terminated-app backstop")

        await conductor.handle(.pause)
        log = await backstop.waitFor(count: 2)
        XCTAssertEqual(log.last, "cancel", "pausing clears the backstop")

        await conductor.handle(.resume)
        log = await backstop.waitFor(count: 3)
        XCTAssertEqual(log.last, "arm:Hold", "resuming re-arms at the new deadline")

        // The timer completes in-app: cleared at zero, and again by finish —
        // the notification can only ever fire for a dead app.
        log = await backstop.waitFor(count: 5)
        XCTAssertEqual(log, ["arm:Hold", "cancel", "arm:Hold", "cancel", "cancel"])
        let lines = await recorder.waitForLines(count: 4)
        XCTAssertEqual(Array(lines.suffix(2)), ["clip:timeUp", "clip:sessionDone"])
    }

    // MARK: - Pause freezes the clock

    func testPauseHoldsATimerAndResumeFinishesIt() async {
        let recorder = GuidanceRecorder()
        let conductor = makeConductor(
            template: template(steps: [
                Step(
                    id: "t1", type: .timed, title: "Hold", cue: "Hold.",
                    target: StepTarget(durationSec: 1), completion: .auto
                )
            ]),
            recorder: recorder
        )
        await watch(conductor, into: recorder)
        await conductor.start()
        _ = await recorder.waitForLines(count: 2)

        await conductor.handle(.pause)
        var lines = await recorder.waitForLines(count: 3)
        XCTAssertEqual(lines.last, "clip:paused")
        try? await Task.sleep(for: .milliseconds(1300))
        lines = await recorder.lines
        XCTAssertFalse(lines.contains("clip:timeUp"), "a paused timer stays silent")

        await conductor.handle(.resume)
        lines = await recorder.waitForLines(count: 6)
        XCTAssertEqual(lines[3], "clip:resumed")
        XCTAssertEqual(Array(lines.suffix(2)), ["clip:timeUp", "clip:sessionDone"])
        let finished = await recorder.waitForEvent("finished:false")
        XCTAssertTrue(finished)
    }
}
