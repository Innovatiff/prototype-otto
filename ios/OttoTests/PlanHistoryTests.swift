import XCTest

@testable import Otto

/// Pins the version-chain walk: newest → oldest via supersedes, stopping
/// at a missing link and never looping on corrupt data.
final class PlanHistoryTests: XCTestCase {

    private func summary(_ id: String, version: Int, supersedes: String?) -> PlanSummary {
        PlanSummary(
            id: id,
            meta: PlanMeta(domain: "fitness", goal: "get stronger", horizonDays: 56, version: version),
            status: version == 3 ? .active : .superseded,
            supersedes: supersedes,
            sessionCount: 4,
            scheduleEntryCount: 32,
            createdAt: Date(timeIntervalSince1970: 1_785_715_200 + Double(version) * 86_400)
        )
    }

    func testChainWalksNewestToOldest() {
        let summaries = [
            summary("p3", version: 3, supersedes: "p2"),
            summary("p1", version: 1, supersedes: nil),
            summary("p2", version: 2, supersedes: "p1"),
        ]
        let chain = PlansModel.versionChain(activeId: "p3", summaries: summaries)
        XCTAssertEqual(chain.map(\.id), ["p3", "p2", "p1"])
    }

    func testBrokenLinkEndsTheChain() {
        let summaries = [
            summary("p3", version: 3, supersedes: "p-missing"),
            summary("p1", version: 1, supersedes: nil),
        ]
        let chain = PlansModel.versionChain(activeId: "p3", summaries: summaries)
        XCTAssertEqual(chain.map(\.id), ["p3"])
    }

    func testCycleTerminates() {
        let summaries = [
            summary("p2", version: 2, supersedes: "p1"),
            summary("p1", version: 1, supersedes: "p2"),
        ]
        let chain = PlansModel.versionChain(activeId: "p2", summaries: summaries)
        XCTAssertEqual(chain.map(\.id), ["p2", "p1"])
    }

    func testWeekMathClampsToSpan() {
        let created = summary("p1", version: 1, supersedes: nil)
        // Day 0 → week 1.
        XCTAssertEqual(PlansModel.week(of: created, now: created.createdAt), 1)
        // Day 15 → week 3.
        XCTAssertEqual(
            PlansModel.week(of: created, now: created.createdAt.addingTimeInterval(15 * 86_400)),
            3
        )
        // Far past the horizon clamps to the final week.
        XCTAssertEqual(
            PlansModel.week(of: created, now: created.createdAt.addingTimeInterval(400 * 86_400)),
            8
        )
        XCTAssertEqual(PlansModel.weekCount(horizonDays: 56), 8)
        XCTAssertEqual(PlansModel.weekCount(horizonDays: 57), 9)
    }
}
