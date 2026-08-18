import XCTest

@testable import Otto

/// Pins the guided-session state machine: legal transitions, rejected
/// illegal ones, persistence on EVERY transition, kill-and-resume, and the
/// resume offer. No model, no network — the happy path is a state machine.
final class GuidanceSessionTests: XCTestCase {

    private var directory: URL!
    private var store: GuidanceStore!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appending(path: "guidance-tests-\(UUID().uuidString)")
        store = GuidanceStore(directory: directory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func step(_ id: String, type: StepType = .counted) -> Step {
        Step(
            id: id,
            type: type,
            title: "Step \(id)",
            cue: "Cue for \(id).",
            target: StepTarget(sets: 3, reps: 8, load: 20),
            completion: .manual
        )
    }

    private func session(stepCount: Int = 3) -> Session {
        Session(
            id: "upper-a",
            title: "Upper A",
            estimatedMinutes: 45,
            steps: (1...stepCount).map { step("s\($0)") }
        )
    }

    private func makeSession(resumeFrom: GuidanceSnapshot? = nil) -> GuidanceSession {
        GuidanceSession(planId: "p1", session: session(), store: store, resumeFrom: resumeFrom)
    }

    // MARK: - The happy path

    func testFullSessionWalksTheDiagram() async {
        let guidance = makeSession()
        let started = await guidance.start()
        XCTAssertTrue(started)
        XCTAssertEqual(await guidance.state, .announcing)

        await guidance.announcementFinished()
        XCTAssertEqual(await guidance.state, .stepActive)
        XCTAssertEqual(await guidance.currentStep?.id, "s1")

        // Step 1 completes into a rest.
        await guidance.beginCompleting()
        XCTAssertEqual(await guidance.state, .stepCompleting)
        await guidance.advance(throughRest: true)
        XCTAssertEqual(await guidance.state, .resting)
        // The index already points at the NEXT step — a kill during rest
        // resumes where the user actually is.
        XCTAssertEqual(await guidance.currentStep?.id, "s2")

        await guidance.restFinished()
        XCTAssertEqual(await guidance.state, .stepActive)

        // Step 2 completes straight into step 3, no rest.
        await guidance.beginCompleting()
        await guidance.advance(throughRest: false)
        XCTAssertEqual(await guidance.state, .stepActive)
        XCTAssertEqual(await guidance.currentStep?.id, "s3")

        // Last step finishes the session and clears the disk.
        await guidance.beginCompleting()
        await guidance.advance(throughRest: true)
        XCTAssertEqual(await guidance.state, .finished)
        XCTAssertNil(store.load())
        let snapshot = await guidance.currentSnapshot
        XCTAssertEqual(snapshot.completedSteps, ["s1", "s2", "s3"])
    }

    func testIllegalTransitionsAreRejectedWithoutStateChange() async {
        let guidance = makeSession()
        // Can't complete or advance before starting.
        XCTAssertFalse(await guidance.beginCompleting())
        XCTAssertFalse(await guidance.advance(throughRest: false))
        XCTAssertFalse(await guidance.restFinished())
        XCTAssertFalse(await guidance.announcementFinished())
        XCTAssertEqual(await guidance.state, .notStarted)

        await guidance.start()
        XCTAssertFalse(await guidance.start(), "double start must be rejected")
        await guidance.announcementFinished()
        // advance without beginCompleting is rejected; skip from resting too.
        XCTAssertFalse(await guidance.advance(throughRest: false))
        await guidance.beginCompleting()
        await guidance.advance(throughRest: true)
        XCTAssertFalse(await guidance.skip(), "skip is a stepActive action, not a resting one")
        XCTAssertEqual(await guidance.state, .resting)
    }

    // MARK: - Persistence and resume

    func testEveryTransitionPersistsAndResumeRestoresPosition() async {
        let guidance = makeSession()
        await guidance.start()
        await guidance.announcementFinished()
        await guidance.beginCompleting()
        await guidance.advance(throughRest: true)
        // Logged during the rest: the value belongs to the set just done.
        await guidance.log(value: "135 pounds", forStepId: nil)

        // What disk holds right now is what a killed app would reload.
        let saved = store.load()
        XCTAssertEqual(saved?.currentStepIndex, 1)
        XCTAssertEqual(saved?.completedSteps, ["s1"])
        XCTAssertEqual(saved?.sessionTitle, "Upper A")
        XCTAssertEqual(saved?.loggedValues["s1"], "135 pounds")

        // "Force-quit mid-session. Reopen." — a fresh actor from the
        // snapshot starts at the same step with history intact.
        let resumed = GuidanceSession(
            planId: "p1", session: session(), store: store, resumeFrom: saved
        )
        await resumed.start()
        await resumed.announcementFinished()
        XCTAssertEqual(await resumed.state, .stepActive)
        XCTAssertEqual(await resumed.currentStep?.id, "s2")
        XCTAssertEqual(await resumed.currentSnapshot.completedSteps, ["s1"])
    }

    func testMismatchedResumeSnapshotIsIgnored() async {
        var foreign = freshSnapshot()
        foreign.sessionId = "someone-elses-session"
        let guidance = GuidanceSession(
            planId: "p1", session: session(), store: store, resumeFrom: foreign
        )
        XCTAssertEqual(await guidance.currentSnapshot.currentStepIndex, 0)
        XCTAssertEqual(await guidance.currentSnapshot.sessionId, "upper-a")
    }

    func testPendingResumeExpiresStaleSnapshots() {
        var snapshot = freshSnapshot()
        snapshot.updatedAt = Date().addingTimeInterval(-13 * 3600)
        store.save(snapshot)
        XCTAssertNil(store.pendingResume(), "13-hour-old session is dead")
        XCTAssertNil(store.load(), "stale snapshot is cleared, never offered twice")

        snapshot.updatedAt = Date().addingTimeInterval(-3600)
        store.save(snapshot)
        XCTAssertEqual(store.pendingResume()?.sessionId, "upper-a")
    }

    // MARK: - Pause, back, skip, early end

    func testPauseIsOrthogonalAndPersisted() async {
        let guidance = makeSession()
        XCTAssertFalse(await guidance.pause(), "nothing to pause before start")
        await guidance.start()
        await guidance.announcementFinished()
        XCTAssertTrue(await guidance.pause())
        XCTAssertFalse(await guidance.pause(), "double pause rejected")
        XCTAssertEqual(await guidance.state, .stepActive, "pause is not a state-machine node")
        XCTAssertNotNil(store.load()?.pausedAt)
        XCTAssertTrue(await guidance.resume())
        XCTAssertNil(store.load()?.pausedAt)
    }

    func testBackReturnsAndUnmarksSoRedoCountsOnce() async {
        let guidance = makeSession()
        await guidance.start()
        await guidance.announcementFinished()
        XCTAssertFalse(await guidance.back(), "no step before the first")
        await guidance.beginCompleting()
        await guidance.advance(throughRest: true)
        // Back out of the rest returns to the completed step, unmarked.
        XCTAssertTrue(await guidance.back())
        XCTAssertEqual(await guidance.state, .stepActive)
        XCTAssertEqual(await guidance.currentStep?.id, "s1")
        XCTAssertEqual(await guidance.currentSnapshot.completedSteps, [])
    }

    func testSkipMarksAndEndEarlyClearsDisk() async {
        let guidance = makeSession()
        await guidance.start()
        await guidance.announcementFinished()
        XCTAssertTrue(await guidance.skip())
        XCTAssertEqual(await guidance.currentSnapshot.skippedSteps, ["s1"])
        XCTAssertEqual(await guidance.currentStep?.id, "s2")

        XCTAssertTrue(await guidance.endEarly())
        XCTAssertEqual(await guidance.state, .finished)
        XCTAssertNil(store.load())
        XCTAssertFalse(await guidance.endEarly(), "already finished")
        // The in-memory snapshot survives for the SessionRecord (Step 8).
        XCTAssertEqual(await guidance.currentSnapshot.skippedSteps, ["s1"])
    }

    // MARK: - The resume offer

    func testResumeOfferLine() {
        var snapshot = freshSnapshot()
        snapshot.currentStepIndex = 4
        XCTAssertEqual(
            snapshot.resumeOfferLine,
            "You were 4 steps into Upper A. Pick up where you left off?"
        )
        snapshot.currentStepIndex = 1
        XCTAssertEqual(
            snapshot.resumeOfferLine,
            "You were 1 step into Upper A. Pick up where you left off?"
        )
        snapshot.currentStepIndex = 0
        XCTAssertEqual(
            snapshot.resumeOfferLine,
            "You'd just started Upper A. Pick up where you left off?"
        )
    }

    private func freshSnapshot() -> GuidanceSnapshot {
        GuidanceSnapshot(
            planId: "p1",
            sessionId: "upper-a",
            sessionTitle: "Upper A",
            totalSteps: 3,
            currentStepIndex: 1,
            startedAt: Date(),
            updatedAt: Date(),
            completedSteps: ["s1"],
            skippedSteps: [],
            loggedValues: [:],
            pausedAt: nil
        )
    }
}
