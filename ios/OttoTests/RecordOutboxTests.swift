import XCTest

@testable import Otto

/// Pins store-and-forward: an offline session's record survives on disk
/// and flushes later; the server confirming removes exactly what it took.
final class RecordOutboxTests: XCTestCase {

    private var directory: URL!
    private var outbox: RecordOutbox!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appending(path: "outbox-tests-\(UUID().uuidString)")
        outbox = RecordOutbox(directory: directory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func pending(_ planId: String, sessionId: String = "lower-a") -> PendingRecord {
        PendingRecord(
            planId: planId,
            upload: SessionRecordUpload(
                sessionId: sessionId,
                startedAt: Date(timeIntervalSince1970: 1_785_715_200),
                completedAt: Date(timeIntervalSince1970: 1_785_718_000),
                completedSteps: ["s1"],
                skippedSteps: [],
                loggedValues: ["s1": "135 pounds"],
                durationSec: 2800,
                endedEarly: false
            )
        )
    }

    func testAppendSurvivesReload() async {
        await outbox.append(pending("p1"))
        await outbox.append(pending("p2"))
        // A fresh instance (a relaunched app) sees both, in order.
        let reloaded = RecordOutbox(directory: directory)
        let records = await reloaded.load()
        XCTAssertEqual(records.map(\.planId), ["p1", "p2"])
        XCTAssertEqual(records.first?.upload.loggedValues["s1"], "135 pounds")
    }

    func testFlushRemovesOnlyWhatTheServerConfirmed() async {
        await outbox.append(pending("p1"))
        await outbox.append(pending("p2"))
        await outbox.append(pending("p3"))
        // The middle one fails — it stays, order preserved.
        let remaining = await outbox.flush { record in record.planId != "p2" }
        XCTAssertEqual(remaining, 1)
        let kept = await outbox.load()
        XCTAssertEqual(kept.map(\.planId), ["p2"])

        // Total failure (airplane mode) keeps everything.
        let offline = await outbox.flush { _ in false }
        XCTAssertEqual(offline, 1)

        // Success drains the file entirely.
        let drained = await outbox.flush { _ in true }
        XCTAssertEqual(drained, 0)
        let empty = await outbox.load()
        XCTAssertEqual(empty, [])
    }
}
