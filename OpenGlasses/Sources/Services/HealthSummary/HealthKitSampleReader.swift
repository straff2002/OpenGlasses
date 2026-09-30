import Foundation
import HealthKit
import UIKit

/// The live `HealthSampleReading`: HealthKit queries for the four read types, nothing written.
///
/// Errors are reduced to the two the tool acts on — the phone is locked (answer from the cache) or
/// Health cannot be read (say so). Anything more specific would only be logged, and the log never
/// sees a value.
@MainActor
final class HealthKitSampleReader: HealthSampleReading {

    private let store: HKHealthStore?

    init() {
        store = HKHealthStore.isHealthDataAvailable() ? HKHealthStore() : nil
    }

    nonisolated static var readTypes: Set<HKObjectType> {
        Set(HealthSummaryReadType.allCases.map(\.objectType))
    }

    func authorizationState() async -> HealthAuthorizationState {
        guard let store else { return .unavailable }
        do {
            switch try await store.statusForAuthorizationRequest(toShare: [], read: Self.readTypes) {
            case .shouldRequest: return .notDetermined
            case .unnecessary: return .requested
            case .unknown: return .notDetermined
            @unknown default: return .notDetermined
            }
        } catch {
            return .unavailable
        }
    }

    func requestAuthorization() async -> Bool {
        // The sheet can only be shown while the app is on screen; from a pocket the request fails,
        // and the tool tells the wearer where to grant access instead.
        guard let store, UIApplication.shared.applicationState == .active else { return false }
        do {
            try await store.requestAuthorization(toShare: [], read: Self.readTypes)
            return true
        } catch {
            return false
        }
    }

    func latestHeartRate(since: Date) async throws -> HeartRateReading? {
        let predicate = HKQuery.predicateForSamples(withStart: since, end: nil, options: [])
        return try await quantitySamples(.heartRate, predicate: predicate, limit: 1).first
    }

    func restingHeartRates(from: Date, to: Date) async throws -> [HeartRateReading] {
        let predicate = HKQuery.predicateForSamples(withStart: from, end: to, options: [])
        return try await quantitySamples(.restingHeartRate, predicate: predicate, limit: 10)
    }

    func sleepSamples(from: Date, to: Date) async throws -> [SleepSample] {
        let store = try readableStore()
        let predicate = HKQuery.predicateForSamples(withStart: from, end: to, options: [])
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis), predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.startDate)])
        do {
            let samples = try await descriptor.result(for: store)
            return samples.compactMap { sample in
                guard let stage = Self.stage(for: sample.value) else { return nil }
                return SleepSample(start: sample.startDate, end: sample.endDate, stage: stage,
                                   sourceID: sample.sourceRevision.source.bundleIdentifier)
            }
        } catch {
            throw Self.mapped(error)
        }
    }

    func cumulativeSteps(from: Date, to: Date) async throws -> Double {
        let store = try readableStore()
        let predicate = HKQuery.predicateForSamples(withStart: from, end: to, options: [])
        let descriptor = HKStatisticsQueryDescriptor(
            predicate: .quantitySample(type: HKQuantityType(.stepCount), predicate: predicate),
            options: .cumulativeSum)
        do {
            return try await descriptor.result(for: store)?.sumQuantity()?.doubleValue(for: .count()) ?? 0
        } catch {
            throw Self.mapped(error)
        }
    }

    // MARK: - Pieces

    private func readableStore() throws -> HKHealthStore {
        guard let store else { throw HealthReadError.unavailable }
        guard UIApplication.shared.isProtectedDataAvailable else {
            throw HealthReadError.protectedDataUnavailable
        }
        return store
    }

    private func quantitySamples(_ identifier: HKQuantityTypeIdentifier, predicate: NSPredicate,
                                 limit: Int) async throws -> [HeartRateReading] {
        let store = try readableStore()
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: HKQuantityType(identifier), predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)],
            limit: limit)
        let perMinute = HKUnit.count().unitDivided(by: .minute())
        do {
            return try await descriptor.result(for: store).map {
                HeartRateReading(beatsPerMinute: $0.quantity.doubleValue(for: perMinute), date: $0.endDate)
            }
        } catch {
            throw Self.mapped(error)
        }
    }

    private static func mapped(_ error: Error) -> HealthReadError {
        if let hkError = error as? HKError, hkError.code == .errorDatabaseInaccessible {
            return .protectedDataUnavailable
        }
        return .unavailable
    }

    static func stage(for value: Int) -> SleepStage? {
        guard let category = HKCategoryValueSleepAnalysis(rawValue: value) else { return nil }
        switch category {
        case .inBed: return .inBed
        case .asleepUnspecified: return .asleepUnspecified
        case .awake: return .awake
        case .asleepCore: return .asleepCore
        case .asleepDeep: return .asleepDeep
        case .asleepREM: return .asleepREM
        @unknown default: return nil
        }
    }
}

extension HealthSummaryReadType {
    var objectType: HKObjectType {
        switch self {
        case .heartRate: return HKQuantityType(.heartRate)
        case .restingHeartRate: return HKQuantityType(.restingHeartRate)
        case .sleepAnalysis: return HKCategoryType(.sleepAnalysis)
        case .stepCount: return HKQuantityType(.stepCount)
        }
    }
}
