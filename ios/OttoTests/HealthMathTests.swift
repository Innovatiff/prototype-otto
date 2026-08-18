import XCTest

@testable import Otto

/// Pins the deterministic half of the Health write — the estimate and the
/// save threshold. The HealthKit calls themselves are verified on device.
final class HealthMathTests: XCTestCase {

    func testEnergyEstimateIsMetTimesMassTimesHours() {
        // 45 min at MET 5, 80 kg: 5 × 80 × 0.75 = 300 kcal.
        XCTAssertEqual(
            HealthMath.estimatedActiveEnergyKcal(durationSec: 45 * 60, bodyMassKg: 80),
            300,
            accuracy: 0.001
        )
        // No readable body mass falls back to 75 kg, never zero.
        XCTAssertEqual(
            HealthMath.estimatedActiveEnergyKcal(durationSec: 3600, bodyMassKg: nil),
            375,
            accuracy: 0.001
        )
        XCTAssertEqual(
            HealthMath.estimatedActiveEnergyKcal(durationSec: -10, bodyMassKg: 80),
            0,
            accuracy: 0.001
        )
    }

    func testFalseStartsAreNotWorkouts() {
        XCTAssertFalse(HealthMath.shouldSaveWorkout(durationSec: 4 * 60))
        XCTAssertTrue(HealthMath.shouldSaveWorkout(durationSec: 5 * 60))
        XCTAssertTrue(HealthMath.shouldSaveWorkout(durationSec: 50 * 60))
    }
}
