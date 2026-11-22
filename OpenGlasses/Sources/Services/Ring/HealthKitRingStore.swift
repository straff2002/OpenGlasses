import Foundation
import HealthKit
import UIKit

// The only HealthKit code for the ring: the rest of `Services/Ring/` builds and tests without it.

extension RingHealthWriter {
    /// The Health types the ring writes, declared once. The ring's settings ask for exactly these
    /// when a ring is paired (Plan MZ P2), as the permission gate does for the fitness coach.
    nonisolated static var shareTypes: Set<HKSampleType> {
        Set(RingHealthKind.allCases.map(\.sampleType))
    }
}

extension RingHealthKind {
    var sampleType: HKSampleType {
        switch self {
        case .heartRate: return HKQuantityType(.heartRate)
        case .oxygenSaturation: return HKQuantityType(.oxygenSaturation)
        case .sleepAnalysis: return HKCategoryType(.sleepAnalysis)
        case .stepCount: return HKQuantityType(.stepCount)
        }
    }
}

/// The live `RingHealthStoring`: saves ring samples to HealthKit and deletes them again.
///
/// Every sample has the app as its source and a device named "Smart ring" (model `SMART_RING`, no
/// maker, no identifier), and carries its sync identifier and version so a re-sync replaces rather
/// than duplicates. Nothing here logs, and an error is reduced to the three the writer acts on.
@MainActor
final class HealthKitRingStore: RingHealthStoring {

    nonisolated static var device: HKDevice {
        HKDevice(name: "Smart ring", manufacturer: nil, model: "SMART_RING", hardwareVersion: nil,
                 firmwareVersion: nil, softwareVersion: nil, localIdentifier: nil, udiDeviceIdentifier: nil)
    }

    private let store: HKHealthStore?

    init() {
        store = HKHealthStore.isHealthDataAvailable() ? HKHealthStore() : nil
    }

    func save(_ samples: [RingHealthSample]) async throws {
        let store = try writableStore()
        guard !samples.isEmpty else { return }
        do {
            try await store.save(samples.map(Self.object(for:)))
        } catch {
            throw Self.mapped(error)
        }
    }

    func deleteSamples(withSyncIdentifierPrefix prefix: String) async throws -> Int {
        let store = try writableStore()
        let ours = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForObjects(from: HKSource.default()),
            HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeySyncIdentifier),
        ])
        var deleted = 0
        do {
            for kind in RingHealthKind.allCases {
                let descriptor = HKSampleQueryDescriptor(
                    predicates: [.sample(type: kind.sampleType, predicate: ours)], sortDescriptors: [])
                let matches = try await descriptor.result(for: store).filter {
                    ($0.metadata?[HKMetadataKeySyncIdentifier] as? String)?.hasPrefix(prefix) == true
                }
                guard !matches.isEmpty else { continue }
                try await store.delete(matches)
                deleted += matches.count
            }
        } catch {
            throw Self.mapped(error)
        }
        return deleted
    }

    // MARK: - Pieces

    private func writableStore() throws -> HKHealthStore {
        guard let store else { throw RingHealthStoreError.unavailable }
        guard UIApplication.shared.isProtectedDataAvailable else {
            throw RingHealthStoreError.protectedDataUnavailable
        }
        return store
    }

    /// The HealthKit object for a sample. Pure: building it touches no store.
    nonisolated static func object(for sample: RingHealthSample) -> HKSample {
        let metadata: [String: Any] = [
            HKMetadataKeySyncIdentifier: sample.syncIdentifier,
            HKMetadataKeySyncVersion: NSNumber(value: sample.syncVersion),
        ]
        switch sample.value {
        case .heartRate(let beatsPerMinute):
            return quantity(.heartRate, HKQuantity(unit: .count().unitDivided(by: .minute()),
                                                   doubleValue: beatsPerMinute), sample, metadata)
        case .oxygenSaturation(let fraction):
            return quantity(.oxygenSaturation, HKQuantity(unit: .percent(), doubleValue: fraction),
                            sample, metadata)
        case .steps(let count):
            return quantity(.stepCount, HKQuantity(unit: .count(), doubleValue: count), sample, metadata)
        case .sleep(let stage):
            return HKCategorySample(type: HKCategoryType(.sleepAnalysis), value: categoryValue(for: stage).rawValue,
                                    start: sample.start, end: sample.end, device: device, metadata: metadata)
        }
    }

    private nonisolated static func quantity(_ identifier: HKQuantityTypeIdentifier, _ quantity: HKQuantity,
                                             _ sample: RingHealthSample, _ metadata: [String: Any]) -> HKSample {
        HKQuantitySample(type: HKQuantityType(identifier), quantity: quantity, start: sample.start,
                         end: sample.end, device: device, metadata: metadata)
    }

    nonisolated static func categoryValue(for stage: SleepStage) -> HKCategoryValueSleepAnalysis {
        switch stage {
        case .inBed: return .inBed
        case .asleepUnspecified: return .asleepUnspecified
        case .awake: return .awake
        case .asleepCore: return .asleepCore
        case .asleepDeep: return .asleepDeep
        case .asleepREM: return .asleepREM
        }
    }

    private static func mapped(_ error: Error) -> RingHealthStoreError {
        if let error = error as? RingHealthStoreError { return error }
        guard let hkError = error as? HKError else { return .unavailable }
        switch hkError.code {
        case .errorDatabaseInaccessible: return .protectedDataUnavailable
        case .errorAuthorizationDenied, .errorAuthorizationNotDetermined: return .notAuthorized
        default: return .unavailable
        }
    }
}
