import XCTest
import HealthKit
@testable import OpenGlasses

/// Stands in for Apple Health: keeps samples by sync identifier and, like HealthKit, lets a sample
/// replace one with the same identifier only when its sync version is higher. Samples written by
/// other apps, and this app's own samples without a ring identifier, sit beside them.
@MainActor
final class FakeRingHealthStore: RingHealthStoring {

    struct Other: Equatable {
        let fromThisApp: Bool
        let syncIdentifier: String?
    }

    private(set) var samples: [String: RingHealthSample] = [:]
    var others: [Other] = []
    var refusal: RingHealthStoreError?
    private(set) var saveCalls = 0

    var all: [RingHealthSample] { samples.values.sorted { ($0.start, $0.syncIdentifier) < ($1.start, $1.syncIdentifier) } }

    func save(_ batch: [RingHealthSample]) async throws {
        saveCalls += 1
        if let refusal { throw refusal }
        for sample in batch {
            if let existing = samples[sample.syncIdentifier], existing.syncVersion >= sample.syncVersion { continue }
            samples[sample.syncIdentifier] = sample
        }
    }

    func deleteSamples(withSyncIdentifierPrefix prefix: String) async throws -> Int {
        let ours = samples.keys.filter { $0.hasPrefix(prefix) }
        ours.forEach { samples[$0] = nil }
        let before = others.count
        others.removeAll { $0.fromThisApp && ($0.syncIdentifier?.hasPrefix(prefix) ?? false) }
        return ours.count + before - others.count
    }
}

/// Plan MZ P1 — the mapping table, sync identifiers, the cursor, the step counter, range checks,
/// deletion, and the HealthKit objects the live store builds.
@MainActor
final class RingHealthWriterTests: XCTestCase {

    private typealias F = HealthFixture
    private let pairing = RingPairingID(rawValue: "pairing-test")
    private var store: FakeRingHealthStore!

    override func setUp() async throws {
        store = FakeRingHealthStore()
    }

    private func writer(cursor: RingSyncCursor = RingSyncCursor()) -> RingHealthWriter {
        RingHealthWriter(store: store, pairingID: pairing, cursor: cursor, calendar: F.calendar)
    }

    private func id(_ kind: RingHealthKind, _ start: Date) -> String {
        "ring.pairing-test.\(kind.rawValue).\(Int(start.timeIntervalSince1970))"
    }

    private func night(from start: Date, light: Int, deep: Int) -> [RingSleepRun] {
        let clock = RingClock(offsetSeconds: 0)
        let first = clock.ringSeconds(for: start)
        let packets = (0..<(light + deep)).map { index in
            RingSleepPacket(ringSeconds: first + UInt32(index) * 900,
                            minutes: Array(repeating: index < light ? .light : .deep, count: 15))
        }
        return RingSleepTimeline.runs(from: packets, clock: clock)
    }

    // MARK: - Heart rate and oxygen

    func testAHeartRateReadingIsOneSampleWithItsSyncIdentifier() async {
        let writer = writer()
        let at = F.at(15, 8)
        let outcome = await writer.write([.heartRate(bpm: 72, at: at)])
        XCTAssertEqual(outcome, .written(count: 1))
        XCTAssertEqual(store.all, [RingHealthSample(start: at, end: at, value: .heartRate(beatsPerMinute: 72),
                                                    syncIdentifier: id(.heartRate, at), syncVersion: 1)])
        XCTAssertEqual(writer.cursor.heartRate, at)
    }

    func testHeartRateOutsideThirtyToTwoTwentyIsDropped() async {
        let base = F.at(15, 8)
        let readings: [RingReading] = [29, 30, 220, 221, 0].enumerated().map {
            .heartRate(bpm: $0.element, at: base.addingTimeInterval(Double($0.offset) * 10))
        }
        _ = await writer().write(readings)
        XCTAssertEqual(store.all.map(\.value), [.heartRate(beatsPerMinute: 30), .heartRate(beatsPerMinute: 220)])
    }

    func testHeartRateIsThinnedToOneEveryFiveSeconds() async {
        let base = F.at(15, 8)
        let readings: [RingReading] = [0, 2, 5, 7, 10.5].map { .heartRate(bpm: 80, at: base.addingTimeInterval($0)) }
        _ = await writer().write(readings.reversed())
        XCTAssertEqual(store.all.map(\.start), [base, base.addingTimeInterval(5), base.addingTimeInterval(10.5)])
    }

    func testOxygenIsAFractionAndOnlySeventyToAHundred() async {
        let base = F.at(15, 8)
        let readings: [RingReading] = [69, 70, 97, 100, 101].enumerated().map {
            .oxygen(percent: $0.element, at: base.addingTimeInterval(Double($0.offset) * 60))
        }
        _ = await writer().write(readings)
        XCTAssertEqual(store.all.map(\.value), [.oxygenSaturation(fraction: 0.70), .oxygenSaturation(fraction: 0.97),
                                                .oxygenSaturation(fraction: 1.00)])
        XCTAssertEqual(store.all.first?.syncIdentifier, id(.oxygenSaturation, base.addingTimeInterval(60)))
    }

    func testReadingsOlderThanTheCursorAreNotWrittenAgain() async {
        let writer = writer(cursor: RingSyncCursor(heartRate: F.at(15, 8), oxygenSaturation: F.at(15, 8)))
        let outcome = await writer.write([.heartRate(bpm: 70, at: F.at(15, 7)), .oxygen(percent: 98, at: F.at(15, 8))])
        XCTAssertEqual(outcome, .nothingToWrite)
        XCTAssertEqual(store.saveCalls, 0)
    }

    // MARK: - Sleep

    func testSleepRunsAreCoreAndDeepSamples() async {
        let runs = night(from: F.at(15, 1, 30), light: 18, deep: 2)
        _ = await writer().write([.sleep(runs)])
        XCTAssertEqual(store.all.map(\.value), [.sleep(.asleepCore), .sleep(.asleepDeep)])
        XCTAssertEqual(store.all[0].start, F.at(15, 1, 30))
        XCTAssertEqual(store.all[0].end, F.at(15, 6))
        XCTAssertEqual(store.all[1].end, F.at(15, 6, 30))
        XCTAssertEqual(store.all[0].syncIdentifier, id(.sleepAnalysis, F.at(15, 1, 30)))
    }

    func testTheSameNightSyncedTwiceIsOneSetOfSamples() async {
        let runs = night(from: F.at(15, 0), light: 8, deep: 4)
        _ = await writer().write([.sleep(runs)])
        let first = store.all
        // A second writer with no cursor (the record was lost), the same pairing, the same night.
        _ = await writer().write([.sleep(runs)])
        XCTAssertEqual(store.all, first)
        XCTAssertEqual(store.all.count, 2)
    }

    func testANightThatGrewReplacesItsShorterCopy() async {
        let writer = writer()
        _ = await writer.write([.sleep(night(from: F.at(15, 0), light: 4, deep: 0))])
        _ = await writer.write([.sleep(night(from: F.at(15, 0), light: 8, deep: 0))])
        XCTAssertEqual(store.all.count, 1)
        XCTAssertEqual(store.all.first?.end, F.at(15, 2))
        XCTAssertEqual(writer.cursor.sleepAnalysis, F.at(15, 2))
    }

    func testTouchingRunsAtTheSameStageAreMerged() {
        let a = RingSleepRun(start: F.at(15, 1), end: F.at(15, 2), stage: .asleepCore)
        let b = RingSleepRun(start: F.at(15, 2), end: F.at(15, 3), stage: .asleepCore)
        let c = RingSleepRun(start: F.at(15, 3), end: F.at(15, 4), stage: .asleepDeep)
        XCTAssertEqual(RingHealthWriter.mergedRuns([c, b, a]),
                       [RingSleepRun(start: F.at(15, 1), end: F.at(15, 3), stage: .asleepCore), c])
    }

    // MARK: - The cursor

    func testARefusedWriteLeavesTheCursorAndTheNextSyncWritesTheSpan() async {
        let writer = writer()
        store.refusal = .protectedDataUnavailable
        let readings: [RingReading] = [.heartRate(bpm: 64, at: F.at(15, 3)), .steps(counter: 1200, at: F.at(15, 9)),
                                       .sleep(night(from: F.at(15, 0), light: 4, deep: 0))]
        let refused = await writer.write(readings)
        XCTAssertEqual(refused, .refused(.protectedDataUnavailable))
        XCTAssertEqual(writer.cursor, RingSyncCursor())
        XCTAssertNil(writer.stepBaseline)
        XCTAssertTrue(store.all.isEmpty)

        store.refusal = nil
        let written = await writer.write(readings)
        XCTAssertEqual(written, .written(count: 3))
        XCTAssertEqual(writer.cursor, RingSyncCursor(heartRate: F.at(15, 3), sleepAnalysis: F.at(15, 1),
                                                     stepCount: F.at(15, 9)))
    }

    /// The cursor holds dates and nothing else: no reading is kept in the pairing record.
    func testTheCursorHoldsDatesOnly() throws {
        let cursor = RingSyncCursor(heartRate: F.at(15, 1), oxygenSaturation: F.at(15, 2),
                                    sleepAnalysis: F.at(15, 3), stepCount: F.at(15, 4))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(cursor)) as? [String: String])
        XCTAssertEqual(Set(object.keys), Set(RingHealthKind.allCases.map(\.rawValue)))
        let formatter = ISO8601DateFormatter()
        XCTAssertTrue(object.values.allSatisfy { formatter.date(from: $0) != nil })
    }

    func testTheCursorNeverMovesBack() {
        var cursor = RingSyncCursor(stepCount: F.at(15, 9))
        cursor.advance(.stepCount, to: F.at(15, 8))
        XCTAssertEqual(cursor.stepCount, F.at(15, 9))
    }

    // MARK: - Steps

    func testStepsAreDifferencesOfTheDayCounter() async {
        let writer = writer()
        _ = await writer.write([.steps(counter: 1000, at: F.at(15, 10))])
        _ = await writer.write([.steps(counter: 1500, at: F.at(15, 11))])
        let unchanged = await writer.write([.steps(counter: 1500, at: F.at(15, 11, 30))])
        XCTAssertEqual(unchanged, .nothingToWrite)
        XCTAssertEqual(writer.cursor.stepCount, F.at(15, 11, 30), "a zero difference still moves the cursor")

        XCTAssertEqual(store.all.map(\.value), [.steps(1000), .steps(500)])
        XCTAssertEqual(store.all[0].start, F.at(15, 0), "the first reading of a day counts from midnight")
        XCTAssertEqual(store.all[0].end, F.at(15, 10))
        XCTAssertEqual(store.all[1].start, F.at(15, 10))
        XCTAssertEqual(store.all[1].end, F.at(15, 11))
    }

    func testAFallingCounterIsAResetAndStartsFromZero() async {
        let writer = writer()
        _ = await writer.write([.steps(counter: 4000, at: F.at(15, 10)), .steps(counter: 250, at: F.at(15, 12))])
        XCTAssertEqual(store.all.map(\.value), [.steps(4000), .steps(250)])
        XCTAssertEqual(store.all[1].start, F.at(15, 10))
        XCTAssertEqual(store.all[1].end, F.at(15, 12))
    }

    func testANewDayStartsFromMidnight() async {
        let writer = writer()
        _ = await writer.write([.steps(counter: 9000, at: F.at(14, 22))])
        _ = await writer.write([.steps(counter: 300, at: F.at(15, 8))])
        XCTAssertEqual(store.all.last?.value, .steps(300))
        XCTAssertEqual(store.all.last?.start, F.at(15, 0))
        // A new day whose counter happens to be higher than last night's is still the day's own.
        _ = await writer.write([.steps(counter: 9500, at: F.at(16, 23))])
        XCTAssertEqual(store.all.last?.value, .steps(9500))
        XCTAssertEqual(store.all.last?.start, F.at(16, 0))
    }

    /// After a relaunch the last counter value is gone; on a day already partly written the first
    /// reading only becomes the baseline, so nothing is counted twice.
    func testAfterARelaunchADayAlreadyWrittenWaitsForASecondReading() async {
        let writer = writer(cursor: RingSyncCursor(stepCount: F.at(15, 9)))
        let first = await writer.write([.steps(counter: 3000, at: F.at(15, 10))])
        XCTAssertEqual(first, .nothingToWrite)
        _ = await writer.write([.steps(counter: 3400, at: F.at(15, 10, 30))])
        XCTAssertEqual(store.all.map(\.value), [.steps(400)])
    }

    func testStepReadingsInOneBatchAreTakenInTimeOrder() async {
        _ = await writer().write([.steps(counter: 1800, at: F.at(15, 12)), .steps(counter: 1000, at: F.at(15, 10))])
        XCTAssertEqual(store.all.map(\.value), [.steps(1000), .steps(800)])
    }

    func testAStepSampleKeepsItsIdentifierAndAHigherVersionWhenItsSpanGrows() async {
        // Refused at 11:00, accepted at 11:30: the second batch covers 10:00 → 11:30 under the
        // same identifier the refused one would have had.
        let writer = writer()
        _ = await writer.write([.steps(counter: 1000, at: F.at(15, 10))])
        store.refusal = .protectedDataUnavailable
        _ = await writer.write([.steps(counter: 1200, at: F.at(15, 11))])
        store.refusal = nil
        _ = await writer.write([.steps(counter: 1300, at: F.at(15, 11, 30))])
        XCTAssertEqual(store.all.last?.syncIdentifier, id(.stepCount, F.at(15, 10)))
        XCTAssertEqual(store.all.last?.value, .steps(300))
        XCTAssertEqual(store.all.last?.syncVersion, Int(F.at(15, 11, 30).timeIntervalSince1970))
    }

    // MARK: - Delete

    func testDeleteRemovesOnlyRingSamplesFromThisApp() async throws {
        let writer = writer()
        _ = await writer.write([.heartRate(bpm: 70, at: F.at(15, 8)), .steps(counter: 100, at: F.at(15, 9))])
        store.others = [
            .init(fromThisApp: true, syncIdentifier: nil),              // a workout from the coach
            .init(fromThisApp: true, syncIdentifier: "ring.an-earlier-pairing.heartRate.1"),
            .init(fromThisApp: false, syncIdentifier: "ring.someone-else.heartRate.1"),
            .init(fromThisApp: false, syncIdentifier: nil),             // a watch
        ]
        let deleted = try await writer.deleteRingReadings()
        XCTAssertEqual(deleted, 3, "this ring's two samples and an earlier ring's one")
        XCTAssertTrue(store.all.isEmpty)
        XCTAssertEqual(store.others, [.init(fromThisApp: true, syncIdentifier: nil),
                                      .init(fromThisApp: false, syncIdentifier: "ring.someone-else.heartRate.1"),
                                      .init(fromThisApp: false, syncIdentifier: nil)])
    }

    // MARK: - Pairing id

    func testThePairingIDIsRandomAndNotAnAddress() {
        let a = RingPairingID.make(), b = RingPairingID.make()
        XCTAssertNotEqual(a, b)
        XCTAssertNotNil(UUID(uuidString: a.rawValue))
        XCTAssertFalse(a.rawValue.contains(":"))
        XCTAssertTrue(RingHealthWriter.syncIdentifier(pairingID: a, kind: .heartRate, start: F.at(15, 1))
            .hasPrefix(RingHealthWriter.syncIdentifierRoot))
    }

    // MARK: - HealthKit

    func testTheShareTypesAreTheFourRingKindsAndNothingElse() {
        let expected: Set<HKSampleType> = [HKQuantityType(.heartRate), HKQuantityType(.oxygenSaturation),
                                           HKCategoryType(.sleepAnalysis), HKQuantityType(.stepCount)]
        XCTAssertEqual(RingHealthWriter.shareTypes, expected)
        XCTAssertFalse(RingHealthWriter.shareTypes.contains(HKQuantityType(.distanceWalkingRunning)),
                       "distance waits for the device pass")
        XCTAssertFalse(RingHealthWriter.shareTypes.contains(HKQuantityType(.activeEnergyBurned)),
                       "the ring's calories are never written")
        XCTAssertTrue(RingHealthWriter.shareTypes.isDisjoint(with: FitnessCoachingTool.healthKitShareTypes),
                      "the ring asks for its own types beside the coach's")
    }

    func testTheLiveStoreBuildsQuantitySamplesWithTheRingDevice() throws {
        let at = F.at(15, 8)
        let heart = HealthKitRingStore.object(for: RingHealthSample(
            start: at, end: at, value: .heartRate(beatsPerMinute: 72), syncIdentifier: "ring.p.heartRate.1",
            syncVersion: 3))
        let quantity = try XCTUnwrap(heart as? HKQuantitySample)
        XCTAssertEqual(quantity.quantityType, HKQuantityType(.heartRate))
        XCTAssertEqual(quantity.quantity.doubleValue(for: .count().unitDivided(by: .minute())), 72)
        XCTAssertEqual(quantity.metadata?[HKMetadataKeySyncIdentifier] as? String, "ring.p.heartRate.1")
        XCTAssertEqual((quantity.metadata?[HKMetadataKeySyncVersion] as? NSNumber)?.intValue, 3)
        XCTAssertEqual(quantity.device?.name, "Smart ring")
        XCTAssertEqual(quantity.device?.model, "SMART_RING")
        XCTAssertNil(quantity.device?.manufacturer)
        XCTAssertNil(quantity.device?.localIdentifier, "never the ring's address or Bluetooth identifier")

        let oxygen = try XCTUnwrap(HealthKitRingStore.object(for: RingHealthSample(
            start: at, end: at, value: .oxygenSaturation(fraction: 0.97), syncIdentifier: "o", syncVersion: 1))
            as? HKQuantitySample)
        XCTAssertEqual(oxygen.quantity.doubleValue(for: .percent()), 0.97, accuracy: 0.0001)

        let steps = try XCTUnwrap(HealthKitRingStore.object(for: RingHealthSample(
            start: F.at(15, 10), end: F.at(15, 11), value: .steps(500), syncIdentifier: "s", syncVersion: 1))
            as? HKQuantitySample)
        XCTAssertEqual(steps.quantity.doubleValue(for: .count()), 500)
        XCTAssertEqual(steps.startDate, F.at(15, 10))
        XCTAssertEqual(steps.endDate, F.at(15, 11))
    }

    func testTheLiveStoreBuildsSleepCategorySamples() throws {
        let sample = try XCTUnwrap(HealthKitRingStore.object(for: RingHealthSample(
            start: F.at(15, 1), end: F.at(15, 2), value: .sleep(.asleepDeep), syncIdentifier: "d", syncVersion: 9))
            as? HKCategorySample)
        XCTAssertEqual(sample.categoryType, HKCategoryType(.sleepAnalysis))
        XCTAssertEqual(sample.value, HKCategoryValueSleepAnalysis.asleepDeep.rawValue)
        XCTAssertEqual(HealthKitSampleReader.stage(for: sample.value), .asleepDeep, "it reads back as it went in")
        XCTAssertEqual(HealthKitRingStore.categoryValue(for: .asleepCore), .asleepCore)
    }
}
