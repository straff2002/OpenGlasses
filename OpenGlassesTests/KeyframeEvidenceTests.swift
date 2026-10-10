import XCTest
@testable import OpenGlasses

/// Plan HW P0. Two things about the glasses stream cannot be learnt at a desk: whether it marks
/// its non-keyframes with the `NotSync` attachment at all, and how many samples lie between
/// pictures a decoder can start on. Each is one log line per stream, and this is the rule for
/// when a stream has shown enough to write it: once, at the first sample that settles the
/// question, and never as a guess.
final class KeyframeEvidenceTests: XCTestCase {

    private typealias Kind = NALUnitInspector.PictureKind
    private typealias Finding = KeyframeEvidence.Finding
    private let idr = Kind.randomAccess(nalType: 19, leadingMayBeUndecodable: false)
    private let cra = Kind.randomAccess(nalType: 21, leadingMayBeUndecodable: true)
    private let trailing = Kind.nonRandomAccess(nalType: 1)

    // MARK: - Which source told the truth

    /// The field report, confirmed: a frame the video says is not a keyframe, carrying nothing
    /// that says so. The attachment rule would have passed it.
    func testANonKeyframeWithNoAttachmentIsTheParsersFinding() {
        var evidence = KeyframeEvidence()
        XCTAssertEqual(evidence.observe(idr, notSync: nil, parameterSetsInBand: true), [],
                       "both sources call the first picture a keyframe, which settles nothing")
        XCTAssertEqual(evidence.observe(trailing, notSync: nil, parameterSetsInBand: false),
                       [.source(.parser, samples: 2, notSync: nil)])
    }

    /// An attachment that is there and says "sync" on a non-keyframe is wrong in the same way.
    func testANonKeyframeMarkedSyncIsTheParsersFindingToo() {
        var evidence = KeyframeEvidence()
        XCTAssertEqual(evidence.observe(trailing, notSync: false, parameterSetsInBand: false),
                       [.source(.parser, samples: 1, notSync: false)])
    }

    /// The stream does mark its non-keyframes, so either source would have done.
    func testANonKeyframeMarkedNotSyncIsBoth() {
        var evidence = KeyframeEvidence()
        XCTAssertEqual(evidence.observe(idr, notSync: nil, parameterSetsInBand: false), [])
        XCTAssertEqual(evidence.observe(trailing, notSync: true, parameterSetsInBand: false),
                       [.source(.both, samples: 2, notSync: true)])
    }

    func testLeadingPicturesCountAsNonKeyframes() {
        var skipped = KeyframeEvidence()
        XCTAssertEqual(skipped.observe(.leadingSkipped(nalType: 8), notSync: nil,
                                       parameterSetsInBand: false),
                       [.source(.parser, samples: 1, notSync: nil)])
        var decodable = KeyframeEvidence()
        XCTAssertEqual(decodable.observe(.leadingDecodable(nalType: 7), notSync: true,
                                         parameterSetsInBand: false),
                       [.source(.both, samples: 1, notSync: true)])
    }

    /// A picture the video says a decoder can start on, marked as not a sync sample.
    func testARandomAccessPictureMarkedNotSyncIsADisagreement() {
        var evidence = KeyframeEvidence()
        XCTAssertEqual(evidence.observe(idr, notSync: true, parameterSetsInBand: false),
                       [.source(.disagree, samples: 1, notSync: true)])
    }

    /// A random-access picture with no `NotSync` is a keyframe by both accounts, and would be
    /// whether or not the stream ever sets the attachment. It is never the deciding sample.
    func testAgreementOnAKeyframeSettlesNothing() {
        var evidence = KeyframeEvidence()
        for _ in 0..<100 {
            XCTAssertEqual(evidence.observe(idr, notSync: false, parameterSetsInBand: false)
                .filter(isSource), [])
        }
    }

    /// A stream the parser cannot read at all is running on the attachment rule, and the log
    /// should say so rather than say nothing.
    func testThirtyUnreadableSamplesMeanTheAttachmentIsInForce() {
        var evidence = KeyframeEvidence()
        for _ in 0..<(KeyframeEvidence.unparseableLimit - 1) {
            XCTAssertEqual(evidence.observe(.unparseable, notSync: nil,
                                            parameterSetsInBand: false), [])
        }
        XCTAssertEqual(evidence.observe(.unparseable, notSync: true, parameterSetsInBand: false),
                       [.source(.attachment, samples: 30, notSync: true)])
    }

    /// The odd unreadable sample in a readable stream does not make it an unreadable stream: the
    /// first readable non-keyframe gets there first.
    func testAReadableSampleSettlesItBeforeTheUnreadableOnesAddUp() {
        var evidence = KeyframeEvidence()
        for _ in 0..<10 {
            XCTAssertEqual(evidence.observe(.unparseable, notSync: nil,
                                            parameterSetsInBand: false), [])
        }
        XCTAssertEqual(evidence.observe(trailing, notSync: nil, parameterSetsInBand: false),
                       [.source(.parser, samples: 11, notSync: nil)])
        for _ in 0..<100 {
            XCTAssertEqual(evidence.observe(.unparseable, notSync: nil,
                                            parameterSetsInBand: false), [])
        }
    }

    /// One line per stream. Whatever arrives after the question is settled, it is not asked
    /// again.
    func testTheSourceIsReportedOncePerStream() {
        var evidence = KeyframeEvidence()
        XCTAssertEqual(evidence.observe(trailing, notSync: nil, parameterSetsInBand: false).count, 1)
        XCTAssertEqual(evidence.observe(trailing, notSync: true, parameterSetsInBand: false), [])
        XCTAssertEqual(evidence.observe(idr, notSync: true, parameterSetsInBand: false)
            .filter(isSource), [])
        XCTAssertEqual(evidence.observe(trailing, notSync: nil, parameterSetsInBand: false), [])
    }

    // MARK: - The distance between keyframes

    /// The second random-access picture gives the distance from the first, which is the length
    /// of a group of pictures. The field note's stream would read 45 here.
    func testTheSecondRandomAccessPictureGivesTheInterval() {
        var evidence = KeyframeEvidence()
        _ = evidence.observe(idr, notSync: nil, parameterSetsInBand: true)
        for _ in 0..<44 {
            XCTAssertEqual(evidence.observe(trailing, notSync: true, parameterSetsInBand: false)
                .filter(isInterval), [])
        }
        XCTAssertEqual(evidence.observe(idr, notSync: nil, parameterSetsInBand: true),
                       [.interval(samples: 45, pictureName: "idr", parameterSetsInBand: true)])
    }

    /// The count starts at the first random-access picture, not at the first sample: a stream
    /// joined mid-GOP must not report a short first interval.
    func testTheIntervalIsMeasuredFromTheFirstRandomAccessPicture() {
        var evidence = KeyframeEvidence()
        for _ in 0..<7 { _ = evidence.observe(trailing, notSync: nil, parameterSetsInBand: false) }
        _ = evidence.observe(cra, notSync: nil, parameterSetsInBand: false)
        for _ in 0..<29 { _ = evidence.observe(trailing, notSync: nil, parameterSetsInBand: false) }
        XCTAssertEqual(evidence.observe(cra, notSync: nil, parameterSetsInBand: false),
                       [.interval(samples: 30, pictureName: "cra", parameterSetsInBand: false)])
    }

    /// The line names the picture that closed the interval and whether it carried its own
    /// parameter sets.
    func testTheIntervalNamesThePictureAndItsParameterSets() {
        var evidence = KeyframeEvidence()
        _ = evidence.observe(idr, notSync: nil, parameterSetsInBand: true)
        XCTAssertEqual(
            evidence.observe(.randomAccess(nalType: 16, leadingMayBeUndecodable: true),
                             notSync: nil, parameterSetsInBand: false),
            [.interval(samples: 1, pictureName: "bla", parameterSetsInBand: false)])
    }

    func testTheIntervalIsReportedOncePerStream() {
        var evidence = KeyframeEvidence()
        _ = evidence.observe(idr, notSync: nil, parameterSetsInBand: false)
        XCTAssertEqual(evidence.observe(idr, notSync: nil, parameterSetsInBand: false).count, 1)
        XCTAssertEqual(evidence.observe(idr, notSync: nil, parameterSetsInBand: false), [])
        XCTAssertEqual(evidence.observe(idr, notSync: nil, parameterSetsInBand: false), [])
    }

    /// One sample can settle both questions, and then both lines are due.
    func testOneSampleCanSettleBoth() {
        var evidence = KeyframeEvidence()
        _ = evidence.observe(idr, notSync: nil, parameterSetsInBand: false)
        XCTAssertEqual(evidence.observe(idr, notSync: true, parameterSetsInBand: false),
                       [.source(.disagree, samples: 2, notSync: true),
                        .interval(samples: 1, pictureName: "idr", parameterSetsInBand: false)])
    }

    // MARK: - Per stream

    /// A new stream is a new question: it may come from different glasses, or the same ones
    /// after an update.
    func testANewStreamReportsAgain() {
        var evidence = KeyframeEvidence()
        _ = evidence.observe(idr, notSync: nil, parameterSetsInBand: false)
        _ = evidence.observe(trailing, notSync: nil, parameterSetsInBand: false)
        _ = evidence.observe(idr, notSync: nil, parameterSetsInBand: false)
        XCTAssertEqual(evidence.samplesObserved, 3)

        evidence.reset()
        XCTAssertEqual(evidence.samplesObserved, 0)
        XCTAssertEqual(evidence.observe(idr, notSync: nil, parameterSetsInBand: false), [],
                       "the first random-access picture of the new stream, not the third of the old")
        XCTAssertEqual(evidence.observe(trailing, notSync: true, parameterSetsInBand: false),
                       [.source(.both, samples: 2, notSync: true)])
        XCTAssertEqual(evidence.observe(idr, notSync: nil, parameterSetsInBand: false),
                       [.interval(samples: 2, pictureName: "idr", parameterSetsInBand: false)])
    }

    /// The four words are the log's vocabulary and the plan's; a rename here is a rename there.
    func testTheSourceWordsAreTheLogsVocabulary() {
        XCTAssertEqual(KeyframeEvidence.Source.parser.rawValue, "parser")
        XCTAssertEqual(KeyframeEvidence.Source.attachment.rawValue, "attachment")
        XCTAssertEqual(KeyframeEvidence.Source.both.rawValue, "both")
        XCTAssertEqual(KeyframeEvidence.Source.disagree.rawValue, "disagree")
    }

    // MARK: - Helpers

    private func isSource(_ finding: Finding) -> Bool {
        if case .source = finding { return true }
        return false
    }

    private func isInterval(_ finding: Finding) -> Bool {
        if case .interval = finding { return true }
        return false
    }
}
