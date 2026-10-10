import XCTest
@testable import OpenGlasses

/// Plan HW P1. Field work elsewhere saw short stalls heal by themselves; our detector rebuilds
/// the stream the moment it calls one, and a rebuild is a cold start. Nobody knows whether a
/// short wait would serve us better, so before anything is changed each stall is written down:
/// how long the silence was, whether the old stream showed any life before it was torn down,
/// which rebuild was used and how long it took to show a picture. One line per stall.
///
/// The record decides nothing. These tests drive it with a clock of their own.
final class StallEpisodeRecordTests: XCTestCase {

    private let verdict = Date(timeIntervalSince1970: 4_000_000)

    private func opened(silence: TimeInterval = 1.7, samplesSeen: Int = 900) -> StallEpisodeRecord {
        StallEpisodeRecord(silenceAtVerdict: silence, samplesSeen: samplesSeen)
    }

    // MARK: - A rebuild

    func testARebuildThatShowsAPicture() throws {
        var record = opened()
        record.teardownFinished(tier: .rebuildStream, samplesSeen: 900, at: verdict + 0.4)
        record.rebuildFinished(freshPicture: true, at: verdict + 7.9)

        let line = try XCTUnwrap(record.close())
        XCTAssertEqual(line.ending, .recovered)
        XCTAssertEqual(line.tier, .rebuildStream)
        XCTAssertEqual(line.silenceAtVerdict, 1.7)
        XCTAssertEqual(line.samplesAfterVerdict, 0)
        XCTAssertFalse(line.sampleBeforeTeardown)
        XCTAssertEqual(try XCTUnwrap(line.secondsToPicture), 7.5, accuracy: 0.001,
                       "measured from the end of the teardown, not from the verdict")
    }

    /// The case the record exists for: the stream was called stalled, and then delivered again
    /// before the rebuild had finished taking it down. It was healing when it was cut short.
    func testSamplesThatArriveBeforeTheTeardownAreCounted() throws {
        var record = opened(samplesSeen: 900)
        record.teardownFinished(tier: .rebuildStream, samplesSeen: 912, at: verdict + 0.4)
        record.rebuildFinished(freshPicture: true, at: verdict + 5)

        let line = try XCTUnwrap(record.close())
        XCTAssertEqual(line.samplesAfterVerdict, 12)
        XCTAssertTrue(line.sampleBeforeTeardown)
    }

    func testTheEscalatedRebuildIsNamed() throws {
        var record = opened()
        record.teardownFinished(tier: .resetSession, samplesSeen: 900, at: verdict + 2.1)
        record.rebuildFinished(freshPicture: true, at: verdict + 20)
        XCTAssertEqual(try XCTUnwrap(record.close()).tier, .resetSession)
    }

    func testARebuildThatShowsNoPicture() throws {
        var record = opened()
        record.teardownFinished(tier: .rebuildStream, samplesSeen: 900, at: verdict + 0.4)
        record.rebuildFinished(freshPicture: false, at: verdict + 20.4)

        let line = try XCTUnwrap(record.close())
        XCTAssertEqual(line.ending, .noPicture)
        XCTAssertEqual(line.tier, .rebuildStream)
        XCTAssertNil(line.secondsToPicture, "no picture came, so there is no time to one")
    }

    func testARebuildThatFails() throws {
        var record = opened()
        record.teardownFinished(tier: .rebuildStream, samplesSeen: 903, at: verdict + 0.4)
        record.rebuildFailed()

        let line = try XCTUnwrap(record.close())
        XCTAssertEqual(line.ending, .rebuildFailed)
        XCTAssertEqual(line.tier, .rebuildStream)
        XCTAssertEqual(line.samplesAfterVerdict, 3)
        XCTAssertNil(line.secondsToPicture)
    }

    // MARK: - No rebuild

    /// Frames came back during the wait a later attempt makes before rebuilding. The detector
    /// already logs this as `stallSelfRecovered`; the record says the same thing on its line,
    /// with how many samples it took.
    func testFramesComingBackDuringABackoffWait() throws {
        var record = opened(samplesSeen: 900)
        record.endedWithoutRebuild(.selfRecovered, samplesSeen: 960)

        let line = try XCTUnwrap(record.close())
        XCTAssertEqual(line.ending, .selfRecovered)
        XCTAssertNil(line.tier)
        XCTAssertEqual(line.samplesAfterVerdict, 60)
        XCTAssertFalse(line.sampleBeforeTeardown, "there was no teardown")
        XCTAssertNil(line.secondsToPicture)
    }

    func testRecoveryGivingUp() throws {
        var record = opened(silence: 5.2)
        record.endedWithoutRebuild(.gaveUp, samplesSeen: 900)

        let line = try XCTUnwrap(record.close())
        XCTAssertEqual(line.ending, .gaveUp)
        XCTAssertNil(line.tier)
        XCTAssertEqual(line.silenceAtVerdict, 5.2)
        XCTAssertEqual(line.samplesAfterVerdict, 0)
    }

    func testTheWaitBeingCancelled() throws {
        var record = opened()
        record.endedWithoutRebuild(.cancelled, samplesSeen: 900)
        XCTAssertEqual(try XCTUnwrap(record.close()).ending, .cancelled)
    }

    /// An episode that closes with nothing noted says so, rather than borrowing another
    /// ending's name.
    func testAnEpisodeNobodyFinishedIsLoggedAsUnfinished() throws {
        var record = opened()
        XCTAssertEqual(try XCTUnwrap(record.close()).ending, .unfinished)
    }

    func testACountThatWentBackwardsIsZeroNotNegative() throws {
        var record = opened(samplesSeen: 900)
        record.endedWithoutRebuild(.selfRecovered, samplesSeen: 10)
        XCTAssertEqual(try XCTUnwrap(record.close()).samplesAfterVerdict, 0)
    }

    // MARK: - Exactly one line

    func testEveryEndingProducesExactlyOneLine() {
        let endings: [(String, (inout StallEpisodeRecord) -> Void)] = [
            ("recovered", { record in
                record.teardownFinished(tier: .rebuildStream, samplesSeen: 900, at: self.verdict)
                record.rebuildFinished(freshPicture: true, at: self.verdict + 3)
            }),
            ("noPicture", { record in
                record.teardownFinished(tier: .resetSession, samplesSeen: 900, at: self.verdict)
                record.rebuildFinished(freshPicture: false, at: self.verdict + 20)
            }),
            ("rebuildFailed", { record in
                record.teardownFinished(tier: .rebuildStream, samplesSeen: 900, at: self.verdict)
                record.rebuildFailed()
            }),
            ("selfRecovered", { $0.endedWithoutRebuild(.selfRecovered, samplesSeen: 930) }),
            ("gaveUp", { $0.endedWithoutRebuild(.gaveUp, samplesSeen: 900) }),
            ("cancelled", { $0.endedWithoutRebuild(.cancelled, samplesSeen: 900) }),
            ("unfinished", { _ in }),
        ]
        for (name, play) in endings {
            var record = opened()
            play(&record)
            var lines: [StallEpisodeRecord.Line] = []
            for _ in 0..<3 {
                if let line = record.close() { lines.append(line) }
            }
            XCTAssertEqual(lines.count, 1, name)
            XCTAssertEqual(lines.first?.ending.rawValue, name)
        }
    }

    // MARK: - The line as logged

    func testTheLoggedLineCarriesBothDurationsUnderTheirOwnNames() throws {
        var record = opened(silence: 1.74, samplesSeen: 900)
        record.teardownFinished(tier: .rebuildStream, samplesSeen: 904, at: verdict + 0.4)
        record.rebuildFinished(freshPicture: true, at: verdict + 4.6)

        let encoded = PrivacyEventEncoder.encode(try XCTUnwrap(record.close()).log())

        XCTAssertEqual(encoded,
                       "[capture] camera source=glasses event=stallEpisode state=recovered "
                           + "detail=rebuildStream count=4 silence=1.7s elapsed=4.2s")
    }

    func testALineWithNoRebuildLeavesOutWhatDidNotHappen() throws {
        var record = opened(silence: 5.0, samplesSeen: 900)
        record.endedWithoutRebuild(.gaveUp, samplesSeen: 900)

        let encoded = PrivacyEventEncoder.encode(try XCTUnwrap(record.close()).log())

        XCTAssertEqual(encoded,
                       "[capture] camera source=glasses event=stallEpisode state=gaveUp "
                           + "count=0 silence=5.0s")
    }
}
