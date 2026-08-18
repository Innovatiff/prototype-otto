import Foundation
import HealthKit

/// Deterministic pieces of the workout write, kept pure for tests.
enum HealthMath {

    /// Strength-training MET. Conservative middle of the 3.5-6 range;
    /// honest for guided sessions with real rests.
    static let strengthTrainingMET = 5.0

    /// Assumed mass when Health has no body-mass sample we may read.
    static let fallbackBodyMassKg = 75.0

    /// A workout shorter than this is a false start, not history.
    static let minimumSaveSeconds: TimeInterval = 5 * 60

    /// kcal = MET × kg × hours — the standard estimate, deterministic.
    static func estimatedActiveEnergyKcal(
        durationSec: TimeInterval,
        bodyMassKg: Double?
    ) -> Double {
        let mass = bodyMassKg ?? fallbackBodyMassKg
        let hours = max(0, durationSec) / 3600
        return strengthTrainingMET * mass * hours
    }

    static func shouldSaveWorkout(durationSec: TimeInterval) -> Bool {
        durationSec >= minimumSaveSeconds
    }
}

/// HealthKit, additive and never required: a denied permission changes
/// nothing about a session except that no workout is saved.
///
/// PRIVACY CONTRACT (Apple enforces this; so do we — see PRIVACY.md):
/// health data never leaves this device — never Otto's servers, never
/// iCloud, never analytics. If a future turn uses a health number as model
/// context, it is ephemeral for that single turn and never persisted
/// server-side.
actor HealthService {

    nonisolated static var isAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    private let store = HKHealthStore()
    private var builder: HKWorkoutBuilder?
    private var workoutStartedAt: Date?

    /// Everything Otto reads, requested once, in context — the first time a
    /// fitness session starts, never at launch. Broad enough that later
    /// phases (sleep in the brief) never re-prompt.
    private static let readTypes: Set<HKObjectType> = [
        HKObjectType.workoutType(),
        HKQuantityType(.activeEnergyBurned),
        HKQuantityType(.bodyMass),
        HKQuantityType(.stepCount),
        HKCategoryType(.sleepAnalysis),
    ]

    private static let shareTypes: Set<HKSampleType> = [HKObjectType.workoutType()]

    /// In-context authorization. Returns whether workouts can be WRITTEN —
    /// read grants aren't queryable by design, and don't gate anything.
    func requestAuthorization() async -> Bool {
        guard Self.isAvailable else { return false }
        try? await store.requestAuthorization(toShare: Self.shareTypes, read: Self.readTypes)
        return store.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized
    }

    // MARK: - The workout write (fitness sessions only)

    /// Starts collecting when a fitness session begins. No-op without
    /// authorization — the session itself runs identically either way.
    func beginWorkout(at start: Date) async {
        guard Self.isAvailable, builder == nil else { return }
        guard store.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized else { return }
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .traditionalStrengthTraining
        configuration.locationType = .indoor
        let builder = HKWorkoutBuilder(
            healthStore: store,
            configuration: configuration,
            device: .local()
        )
        do {
            try await builder.beginCollection(at: start)
            self.builder = builder
            workoutStartedAt = start
        } catch {
            self.builder = nil
            workoutStartedAt = nil
        }
    }

    /// Finishes and saves on completion — duration plus estimated active
    /// energy (MET-based, using the latest readable body mass). Sessions
    /// under five minutes are discarded as false starts. Failures discard
    /// silently; Health is additive.
    func finishWorkout(at end: Date) async {
        guard let builder, let start = workoutStartedAt else { return }
        self.builder = nil
        workoutStartedAt = nil

        let duration = end.timeIntervalSince(start)
        guard HealthMath.shouldSaveWorkout(durationSec: duration) else {
            try? await builder.endCollection(at: end)
            return
        }

        let kcal = HealthMath.estimatedActiveEnergyKcal(
            durationSec: duration,
            bodyMassKg: await latestBodyMassKg()
        )
        let energy = HKQuantitySample(
            type: HKQuantityType(.activeEnergyBurned),
            quantity: HKQuantity(unit: .kilocalorie(), doubleValue: kcal),
            start: start,
            end: end
        )
        do {
            try await builder.addSamples([energy])
            try await builder.endCollection(at: end)
            _ = try await builder.finishWorkout()
        } catch {
            // Nothing to do — the session's own record (Step 8) is the
            // source of truth; Health is a mirror.
        }
    }

    /// The most recent body-mass sample, if readable — feeds the energy
    /// estimate. Read on device, used on device.
    private func latestBodyMassKg() async -> Double? {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: HKQuantityType(.bodyMass))],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)],
            limit: 1
        )
        guard let sample = try? await descriptor.result(for: store).first else { return nil }
        return sample.quantity.doubleValue(for: .gramUnit(with: .kilo))
    }
}
