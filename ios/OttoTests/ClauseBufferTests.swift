import XCTest

@testable import Otto

/// Runs the shared segmentation vectors (ClauseBufferVectors.json) against
/// the real ClauseBuffer. The same vectors validated the reference
/// implementation the rules were designed with — if these fail, the Swift
/// drifted from the pinned behavior, not the other way around.
final class ClauseBufferTests: XCTestCase {

    private struct Vectors: Decodable {
        let cases: [Case]
    }

    private struct Case: Decodable {
        let name: String
        let tokens: [String]
        let expected: [String]
    }

    func testSegmentationVectors() async throws {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "ClauseBufferVectors", withExtension: "json"),
            "ClauseBufferVectors.json missing from the test bundle"
        )
        let vectors = try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
        XCTAssertFalse(vectors.cases.isEmpty)

        for testCase in vectors.cases {
            let buffer = ClauseBuffer()
            for token in testCase.tokens {
                buffer.ingest(token)
            }
            buffer.finish()

            var got: [String] = []
            for await unit in buffer.units {
                got.append(unit)
            }
            XCTAssertEqual(got, testCase.expected, testCase.name)
        }
    }

    func testCancelDiscardsTheTail() async {
        let buffer = ClauseBuffer()
        buffer.ingest("Hello world. And then some")
        buffer.cancel()

        var got: [String] = []
        for await unit in buffer.units {
            got.append(unit)
        }
        // The complete sentence was already emitted; the barge-in discard
        // drops only the unfinished tail.
        XCTAssertEqual(got, ["Hello world."])
    }

    func testLateIngestAfterFinishIsIgnored() async {
        let buffer = ClauseBuffer()
        buffer.ingest("Done.")
        buffer.finish()
        buffer.ingest("Too late.")

        var got: [String] = []
        for await unit in buffer.units {
            got.append(unit)
        }
        XCTAssertEqual(got, ["Done."])
    }
}
