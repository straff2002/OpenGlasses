import Foundation

/// Why Health did not take a batch.
enum RingHealthStoreError: Error, Equatable, Sendable {
    /// The phone is locked and Health's store is encrypted until it is unlocked.
    case protectedDataUnavailable
    /// The wearer has not allowed the app to write this kind of data.
    case notAuthorized
    /// No Health store, or the write failed for a reason the wearer cannot act on.
    case unavailable
}

/// The Health seam the writer uses. The live one is `HealthKitRingStore`; tests use a fake.
@MainActor
protocol RingHealthStoring: AnyObject {
    /// Save the samples, each with the app as its source and the ring as its device. A sample whose
    /// sync identifier is already in Health replaces it only with a higher sync version.
    func save(_ samples: [RingHealthSample]) async throws
    /// Delete every sample this app wrote whose sync identifier starts with `prefix`, and nothing
    /// else. Returns how many were deleted.
    func deleteSamples(withSyncIdentifierPrefix prefix: String) async throws -> Int
}

/// How a write went.
enum RingHealthWriteOutcome: Equatable, Sendable {
    /// Nothing new or plausible to write (the cursor may still have moved past a zero step count).
    case nothingToWrite
    case written(count: Int)
    /// Health refused the batch; the cursor stays and the next sync reads the span again.
    case refused(RingHealthStoreError)
}

/// Writes what the ring measured to Apple Health (Plan MZ §1, P1).
///
/// - Heart rate: one sample per reading, at most one per 5 s, 30–220 bpm only.
/// - Oxygen: the final result only, 70–100 %, stored as a fraction.
/// - Sleep: runs at the same stage merged into one sample, light as core and deep as deep.
/// - Steps: the difference between two readings of the ring's day counter, as an interval sample
///   from the earlier reading to the later. A counter that falls, or a reading on a new day,
///   starts again from zero.
/// - Distance and calories: not written.
///
/// Every sample carries a sync identifier `ring.<pairing id>.<kind>.<start>`, so the same night
/// synced twice is one set of samples. The cursor moves only once Health accepts the batch.
@MainActor
final class RingHealthWriter {

    nonisolated static let heartRateRange = 30...220
    nonisolated static let oxygenRange = 70...100
    /// Readings closer together than this are thinned to the first.
    nonisolated static let heartRateSpacing: TimeInterval = 5
    /// Every ring sample's sync identifier starts with this, whichever ring wrote it.
    nonisolated static let syncIdentifierRoot = "ring."

    let pairingID: RingPairingID
    private(set) var cursor: RingSyncCursor
    /// The last step-counter reading, in memory only.
    private(set) var stepBaseline: RingStepBaseline?

    private let store: RingHealthStoring
    private let calendar: Calendar
    private var tail: Task<Void, Never>?

    init(store: RingHealthStoring, pairingID: RingPairingID, cursor: RingSyncCursor = RingSyncCursor(),
         calendar: Calendar = .current) {
        self.store = store
        self.pairingID = pairingID
        self.cursor = cursor
        self.calendar = calendar
    }

    /// Write readings. Calls are taken one at a time, so two syncs never difference the same
    /// step reading twice.
    func write(_ readings: [RingReading]) async -> RingHealthWriteOutcome {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            return await self.perform(readings)
        }
        tail = Task { _ = await task.value }
        return await task.value
    }

    /// Delete every ring reading this app wrote to Health, from this ring or an earlier one, and
    /// nothing else (Plan MZ decision 7).
    func deleteRingReadings() async throws -> Int {
        try await store.deleteSamples(withSyncIdentifierPrefix: Self.syncIdentifierRoot)
    }

    private func perform(_ readings: [RingReading]) async -> RingHealthWriteOutcome {
        let batch = Self.batch(for: readings, pairingID: pairingID, cursor: cursor,
                               stepBaseline: stepBaseline, calendar: calendar)
        guard !batch.isEmpty else {
            cursor = batch.cursorAfter
            stepBaseline = batch.stepBaselineAfter
            return .nothingToWrite
        }
        do {
            try await store.save(batch.samples)
        } catch {
            return .refused(error as? RingHealthStoreError ?? .unavailable)
        }
        cursor = batch.cursorAfter
        stepBaseline = batch.stepBaselineAfter
        return .written(count: batch.samples.count)
    }

    // MARK: - The batch (pure)

    nonisolated static func syncIdentifier(pairingID: RingPairingID, kind: RingHealthKind, start: Date) -> String {
        "\(syncIdentifierRoot)\(pairingID.rawValue).\(kind.rawValue).\(Int64(start.timeIntervalSince1970.rounded(.down)))"
    }

    /// A workout's heart rate as samples to attach to the saved workout (Plan MZ §5): the readings
    /// between `start` and `end`, with the range, the thinning and the sync identifiers of the
    /// standalone writes and one version higher, so each replaces its standalone copy in Health
    /// rather than adding a second.
    nonisolated static func workoutHeartRateSamples(_ readings: [RingReading], pairingID: RingPairingID,
                                                    from start: Date, to end: Date) -> [RingHealthSample] {
        let inside = readings.filter { reading in
            if case .heartRate(_, let at) = reading { return at >= start && at <= end }
            return false
        }
        return batch(for: inside, pairingID: pairingID, cursor: RingSyncCursor(), stepBaseline: nil,
                     calendar: .current).samples.map {
            RingHealthSample(start: $0.start, end: $0.end, value: $0.value,
                             syncIdentifier: $0.syncIdentifier, syncVersion: $0.syncVersion + 1)
        }
    }

    nonisolated static func batch(for readings: [RingReading], pairingID: RingPairingID,
                                  cursor: RingSyncCursor, stepBaseline: RingStepBaseline?,
                                  calendar: Calendar) -> RingHealthBatch {
        var samples: [RingHealthSample] = []
        var next = cursor

        func sample(_ value: RingHealthValue, _ start: Date, _ end: Date, version: Int) -> RingHealthSample {
            RingHealthSample(start: start, end: end, value: value,
                             syncIdentifier: syncIdentifier(pairingID: pairingID, kind: value.kind, start: start),
                             syncVersion: version)
        }

        // Heart rate: plausible, newer than the cursor, thinned to one per `heartRateSpacing`.
        var lastHeartRate = cursor.heartRate
        let heartRates = readings.compactMap { reading -> (Int, Date)? in
            if case .heartRate(let bpm, let at) = reading { return (bpm, at) }
            return nil
        }.sorted { $0.1 < $1.1 }
        for (bpm, at) in heartRates where heartRateRange.contains(bpm) {
            if let last = lastHeartRate, at.timeIntervalSince(last) < heartRateSpacing { continue }
            samples.append(sample(.heartRate(beatsPerMinute: Double(bpm)), at, at, version: 1))
            lastHeartRate = at
            next.advance(.heartRate, to: at)
        }

        // Oxygen: plausible results newer than the cursor.
        let oxygen = readings.compactMap { reading -> (Int, Date)? in
            if case .oxygen(let percent, let at) = reading { return (percent, at) }
            return nil
        }.sorted { $0.1 < $1.1 }
        for (percent, at) in oxygen where oxygenRange.contains(percent) {
            if let last = next.oxygenSaturation, at <= last { continue }
            samples.append(sample(.oxygenSaturation(fraction: Double(percent) / 100), at, at, version: 1))
            next.advance(.oxygenSaturation, to: at)
        }

        // Sleep: staged runs, touching runs at the same stage merged, ending after the cursor. A
        // run that has grown since it was written keeps its start, so its identifier, and replaces
        // the shorter copy with a higher version.
        let runs = mergedRuns(readings.flatMap { reading -> [RingSleepRun] in
            if case .sleep(let runs) = reading { return runs }
            return []
        })
        for run in runs {
            if let last = cursor.sleepAnalysis, run.end <= last { continue }
            samples.append(sample(.sleep(run.stage), run.start, run.end,
                                  version: Int(run.end.timeIntervalSince1970.rounded(.down))))
            next.advance(.sleepAnalysis, to: run.end)
        }

        // Steps: differences between counter readings.
        var baseline = stepBaseline
        let counters = readings.compactMap { reading -> RingStepBaseline? in
            if case .steps(let counter, let at) = reading, counter >= 0 {
                return RingStepBaseline(counter: counter, date: at)
            }
            return nil
        }.sorted { $0.date < $1.date }
        for reading in counters {
            guard let span = stepSpan(reading, after: baseline, cursor: next.stepCount, calendar: calendar)
            else { continue }
            if span.steps > 0 {
                samples.append(sample(.steps(Double(span.steps)), span.start, reading.date,
                                      version: Int(reading.date.timeIntervalSince1970.rounded(.down))))
            }
            baseline = reading
            next.advance(.stepCount, to: reading.date)
        }

        return RingHealthBatch(samples: samples, cursorAfter: next, stepBaselineAfter: baseline)
    }

    /// The steps a counter reading adds, and from when. Nil for a reading no newer than the last.
    ///
    /// With a baseline from the same day, the steps are the difference; a counter below the
    /// baseline was reset and counts from zero since the baseline. On a new day the counter is the
    /// day's own count, from midnight. With no baseline (the app has just started), a day the
    /// cursor has not reached yet is the counter from midnight; a day already partly written has
    /// an unknown starting count, so this reading only becomes the baseline.
    nonisolated static func stepSpan(_ reading: RingStepBaseline, after baseline: RingStepBaseline?,
                                     cursor: Date?, calendar: Calendar) -> (steps: Int, start: Date)? {
        let dayStart = calendar.startOfDay(for: reading.date)
        if let baseline {
            guard reading.date > baseline.date else { return nil }
            guard baseline.date >= dayStart else { return (reading.counter, dayStart) }
            if reading.counter >= baseline.counter {
                return (reading.counter - baseline.counter, baseline.date)
            }
            return (reading.counter, baseline.date)
        }
        if let cursor {
            guard reading.date > cursor else { return nil }
            if cursor >= dayStart { return (0, cursor) }
        }
        return (reading.counter, dayStart)
    }

    /// Sort runs and merge those that touch or overlap at the same stage.
    nonisolated static func mergedRuns(_ runs: [RingSleepRun]) -> [RingSleepRun] {
        var merged: [RingSleepRun] = []
        for run in runs.filter({ $0.end > $0.start && $0.stage.isStaged }).sorted(by: { $0.start < $1.start }) {
            if let last = merged.last, last.stage == run.stage, run.start <= last.end {
                merged[merged.count - 1] = RingSleepRun(start: last.start, end: max(last.end, run.end),
                                                        stage: run.stage)
            } else {
                merged.append(run)
            }
        }
        return merged
    }
}
