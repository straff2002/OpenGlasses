import XCTest
@testable import OpenGlasses

/// Plan MQ H2: a model's fit judged against the process's kill limit (copied weights) or Metal's
/// working set (mapped weights), with about a gigabyte kept back on a 6 GB phone.
final class LocalMemoryBudgetTests: XCTestCase {

    private let gib: Int64 = 1_024 * 1_024 * 1_024
    private let mib: Int64 = 1_024 * 1_024

    private func readings(available: Int64, footprint: Int64, metal: Int64 = 0, ram: Double = 8) -> LocalMemoryBudget.Readings {
        .init(availableBytes: available, footprintBytes: footprint, recommendedWorkingSetBytes: metal, marketingRAMGB: ram)
    }

    func testTheKillLimitIsWhatIsLeftPlusWhatIsHeld() {
        XCTAssertEqual(LocalMemoryBudget.killLimit(readings(available: 5 * gib, footprint: 300 * mib)), 5 * gib + 300 * mib)
        XCTAssertNil(LocalMemoryBudget.killLimit(readings(available: 0, footprint: 300 * mib)),
                     "no per-process limit (simulator, Mac): unknown, not zero")
    }

    func testASixGigabytePhoneKeepsAGigabyteBack() {
        XCTAssertEqual(LocalMemoryBudget.reserveBytes(marketingRAMGB: 6), gib)
        XCTAssertEqual(LocalMemoryBudget.reserveBytes(marketingRAMGB: 4), gib)
        XCTAssertEqual(LocalMemoryBudget.reserveBytes(marketingRAMGB: 8), LocalModelBudget.admissionComfortMarginBytes)
        XCTAssertEqual(LocalMemoryBudget.reserveBytes(marketingRAMGB: 12), LocalModelBudget.admissionComfortMarginBytes)
    }

    func testCopiedWeightsAreJudgedAgainstTheKillLimit() {
        // An 8 GB phone, 6 GB limit: 300 MB held + 3.5 GB weights + 768 MB working + 512 MB reserve fits.
        let roomy = LocalMemoryBudget.fit(weightsBytes: 3_550 * mib, workingBytes: 768 * mib, backing: .copied,
                                          readings: readings(available: 6 * gib - 300 * mib, footprint: 300 * mib))
        XCTAssertEqual(roomy.judgedAgainst, .killLimit)
        XCTAssertEqual(roomy.limitBytes, 6 * gib)
        XCTAssertEqual(roomy.neededBytes, 300 * mib + 3_550 * mib + 768 * mib + 512 * mib)
        XCTAssertTrue(roomy.fits)
        // The same model on a 6 GB phone with a 4 GB limit: the gigabyte reserve tips it.
        let tight = LocalMemoryBudget.fit(weightsBytes: 2_600 * mib, workingBytes: 768 * mib, backing: .copied,
                                          readings: readings(available: 4 * gib - 300 * mib, footprint: 300 * mib, ram: 6))
        XCTAssertEqual(tight.reserveBytes, gib)
        XCTAssertFalse(tight.fits, "2.6 GB + 0.75 GB + 0.3 GB held fits 4 GB, but not with the reserve")
        XCTAssertLessThan(tight.spareBytes, 0)
    }

    func testMappedWeightsAreJudgedAgainstMetalsWorkingSet() {
        // The weights don't count against the footprint, but must sit in the GPU's working set.
        let fit = LocalMemoryBudget.fit(weightsBytes: 4 * gib, workingBytes: 768 * mib, backing: .mapped,
                                        readings: readings(available: 3 * gib, footprint: 200 * mib, metal: 4 * gib))
        XCTAssertFalse(fit.fits)
        XCTAssertEqual(fit.judgedAgainst, .metalWorkingSet)
        let small = LocalMemoryBudget.fit(weightsBytes: 1 * gib, workingBytes: 768 * mib, backing: .mapped,
                                          readings: readings(available: 3 * gib, footprint: 200 * mib, metal: 4 * gib))
        XCTAssertTrue(small.fits)
        // The tighter of the two limits is the one reported.
        XCTAssertEqual(small.judgedAgainst, .killLimit)
        // A working set that can't fit the footprint fails on the kill limit, whatever the GPU holds.
        let starved = LocalMemoryBudget.fit(weightsBytes: 1 * gib, workingBytes: 768 * mib, backing: .mapped,
                                            readings: readings(available: 600 * mib, footprint: 200 * mib, metal: 4 * gib))
        XCTAssertFalse(starved.fits)
        XCTAssertEqual(starved.judgedAgainst, .killLimit)
    }

    func testNoReadingMeansNotJudgedRatherThanRefused() {
        let copied = LocalMemoryBudget.fit(weightsBytes: 3 * gib, workingBytes: 768 * mib, backing: .copied,
                                           readings: readings(available: 0, footprint: 0))
        XCTAssertEqual(copied.judgedAgainst, .unknown)
        XCTAssertTrue(copied.fits)
        XCTAssertEqual(copied.spareBytes, 0)
        let mapped = LocalMemoryBudget.fit(weightsBytes: 3 * gib, workingBytes: 768 * mib, backing: .mapped,
                                           readings: readings(available: 0, footprint: 0, metal: 0))
        XCTAssertEqual(mapped.judgedAgainst, .unknown)
    }

    func testThePeakIsReportedAgainstTheSameLimit() {
        XCTAssertEqual(LocalMemoryBudget.headroomAtPeak(peakFootprintBytes: 5 * gib, killLimitBytes: 6 * gib), gib)
        XCTAssertEqual(LocalMemoryBudget.headroomAtPeak(peakFootprintBytes: 7 * gib, killLimitBytes: 6 * gib), -gib)
        XCTAssertNil(LocalMemoryBudget.headroomAtPeak(peakFootprintBytes: 5 * gib, killLimitBytes: nil))
    }

    /// The adapter judges later readings against the limit measured once, so a resident model's own
    /// pages don't raise it.
    func testTheAdapterHoldsTheLimitFixed() {
        let later = LocalMemoryReadings.againstProcessLimit()
        if let limit = LocalMemoryReadings.processKillLimit {
            XCTAssertEqual(LocalMemoryBudget.killLimit(later), limit)
        } else {
            XCTAssertEqual(later.availableBytes, 0, "the simulator reports no per-process limit")
        }
    }
}
