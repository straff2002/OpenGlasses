import XCTest
@testable import OpenGlasses

/// The recorded job's road to the office: every transition, and the two things the machine exists
/// to keep — delivered is not acknowledged, and a receipt seen again changes nothing.
final class BundleSyncStateTests: XCTestCase {
    private typealias S = BundleSyncState
    private typealias Phase = BundleSyncState.Phase
    private typealias Event = BundleSyncState.Event

    private let bundleID = "0123456789abcdef0123456789abcdef"
    private let manifest = String(repeating: "a", count: 64)
    private let total: Int64 = 3_000

    private func received(bundle: String? = nil, manifest digest: String? = nil) -> Event {
        .receipt(S.Receipt(bundleID: bundle ?? bundleID, manifestSHA256: digest ?? manifest, status: .received))
    }

    private func refused(_ reason: S.RefusalReason = .digest) -> Event {
        .receipt(S.Receipt(bundleID: bundleID, manifestSHA256: manifest, status: .refused(reason)))
    }

    /// A state brought to a phase by the events that lead there.
    private func state(_ events: Event...) -> S {
        var state = S(bundleID: bundleID)
        for event in events { XCTAssertTrue(state.apply(event), "\(event) from \(state.phase)") }
        return state
    }

    private var recording: S { state() }
    private var preparing: S { state(.recordingStopped) }
    private var waitingToPrepare: S { state(.recordingStopped, .preparationDeferred) }
    private var sealed: S { state(.recordingStopped, .sealed(manifestSHA256: manifest, totalBytes: total)) }
    private var waiting: S { sealed.after(.notEligible(.noNetwork)) }
    private var transferring: S { sealed.after(.transferStarted) }
    private var delivered: S { transferring.after(.allChunksServed) }
    private var acknowledged: S { delivered.after(received()) }
    private var trimmed: S { acknowledged.after(.mediaTrimmed) }
    private var failed: S { delivered.after(refused(.digest)) }
    private var expired: S { delivered.after(.expiryReached) }
    private var expiredBeforeSealing: S { preparing.after(.expiryReached) }

    // MARK: - The road

    func testTheWholeRoadFromRecordingToTrimmed() {
        var state = S(bundleID: bundleID)
        XCTAssertEqual(state.phase, .recording)
        XCTAssertTrue(state.apply(.recordingStopped))
        XCTAssertEqual(state.phase, .preparing)
        XCTAssertTrue(state.apply(.sealed(manifestSHA256: manifest, totalBytes: total)))
        XCTAssertEqual(state.phase, .sealed)
        XCTAssertEqual(state.manifestSHA256, manifest)
        XCTAssertTrue(state.apply(.notEligible(.waitingForPower)))
        XCTAssertEqual(state.phase, .waiting(.notEligible(.waitingForPower)))
        XCTAssertTrue(state.apply(.transferStarted))
        XCTAssertEqual(state.phase, .transferring(sentBytes: 0, totalBytes: total))
        XCTAssertTrue(state.apply(.progress(sentBytes: 1_000)))
        XCTAssertEqual(state.phase, .transferring(sentBytes: 1_000, totalBytes: total))
        XCTAssertTrue(state.apply(.allChunksServed))
        XCTAssertEqual(state.phase, .delivered)
        XCTAssertFalse(state.isAcknowledged)
        XCTAssertTrue(state.apply(received()))
        XCTAssertEqual(state.phase, .acknowledged)
        XCTAssertTrue(state.isAcknowledged)
        XCTAssertTrue(state.apply(.mediaTrimmed))
        XCTAssertEqual(state.phase, .trimmed)
        XCTAssertTrue(state.isAcknowledged)
    }

    // MARK: - Every transition

    /// Each phase, each event, and the phase it leads to — nil where the event does not apply.
    func testEveryPhaseAndEventLeadsWhereTheTableSays() {
        let phases: [(String, S)] = [
            ("recording", recording), ("preparing", preparing), ("waiting to prepare", waitingToPrepare),
            ("sealed", sealed), ("waiting", waiting), ("transferring", transferring), ("delivered", delivered),
            ("acknowledged", acknowledged), ("trimmed", trimmed), ("failed", failed), ("expired", expired),
        ]
        let sealing = Event.sealed(manifestSHA256: manifest, totalBytes: total)
        let events: [(String, Event)] = [
            ("recordingStopped", .recordingStopped), ("preparationDeferred", .preparationDeferred),
            ("preparationResumed", .preparationResumed), ("sealed", sealing), ("notEligible", .notEligible(.officeNotReachable)),
            ("transferStarted", .transferStarted), ("progress", .progress(sentBytes: 2_000)),
            ("allChunksServed", .allChunksServed), ("received", received()), ("refused", refused(.policy)),
            ("mediaTrimmed", .mediaTrimmed), ("expiryReached", .expiryReached), ("keepWaiting", .keepWaiting),
        ]
        let away = Phase.waiting(.notEligible(.officeNotReachable))
        let table: [String: [String: Phase]] = [
            "recording": ["recordingStopped": .preparing],
            "preparing": ["preparationDeferred": .waiting(.openAppToPrepare), "sealed": .sealed, "expiryReached": .expired],
            "waiting to prepare": ["preparationResumed": .preparing, "expiryReached": .expired],
            "sealed": ["notEligible": away, "transferStarted": .transferring(sentBytes: 0, totalBytes: total),
                       "received": .acknowledged, "refused": .failed(.policy), "expiryReached": .expired],
            "waiting": ["notEligible": away, "transferStarted": .transferring(sentBytes: 0, totalBytes: total),
                        "received": .acknowledged, "refused": .failed(.policy), "expiryReached": .expired],
            "transferring": ["notEligible": away, "progress": .transferring(sentBytes: 2_000, totalBytes: total),
                             "allChunksServed": .delivered, "received": .acknowledged, "refused": .failed(.policy),
                             "expiryReached": .expired],
            "delivered": ["received": .acknowledged, "refused": .failed(.policy), "expiryReached": .expired],
            "acknowledged": ["received": .acknowledged, "mediaTrimmed": .trimmed],
            "trimmed": ["received": .trimmed],
            "failed": ["received": .acknowledged, "refused": .failed(.policy), "keepWaiting": .sealed],
            "expired": ["received": .acknowledged, "keepWaiting": .sealed],
        ]
        for (phaseName, start) in phases {
            for (eventName, event) in events {
                let expected = table[phaseName]?[eventName]
                XCTAssertEqual(start.applying(event)?.phase, expected, "\(eventName) in \(phaseName)")
                // An event that does not apply leaves the state exactly as it was.
                var applied = start
                let changed = applied.apply(event)
                if let expected {
                    XCTAssertEqual(applied.phase, expected, "\(eventName) in \(phaseName)")
                    XCTAssertEqual(changed, applied != start, "\(eventName) in \(phaseName)")
                } else {
                    XCTAssertFalse(changed, "\(eventName) in \(phaseName)")
                    XCTAssertEqual(applied, start, "\(eventName) in \(phaseName)")
                }
            }
        }
    }

    // MARK: - Delivered is not acknowledged

    func testEveryChunkServedIsDeliveredAndNothingMore() {
        let state = delivered
        XCTAssertEqual(state.phase, .delivered)
        XCTAssertEqual(state.sentBytes, total)
        XCTAssertFalse(state.isAcknowledged)
        XCTAssertNil(state.applying(.mediaTrimmed), "media is not trimmed on the transport's word")
    }

    func testOnlyAcknowledgedCanBeTrimmed() {
        for state in [recording, preparing, waitingToPrepare, sealed, waiting, transferring, delivered, failed, expired,
                      expiredBeforeSealing, trimmed] {
            XCTAssertNil(state.applying(.mediaTrimmed), "\(state.phase)")
            XCTAssertFalse(state.phase == .acknowledged)
        }
        XCTAssertEqual(acknowledged.applying(.mediaTrimmed)?.phase, .trimmed)
    }

    func testAReceiptForAnotherBundleOrAnotherManifestIsNotThisRecordingsReceipt() {
        for state in [sealed, waiting, transferring, delivered, failed, expired] {
            XCTAssertNil(state.applying(received(bundle: "ffffffffffffffffffffffffffffffff")), "\(state.phase)")
            XCTAssertNil(state.applying(received(manifest: String(repeating: "b", count: 64))), "\(state.phase)")
        }
    }

    func testBeforeSealingThereIsNothingAReceiptCouldBeAbout() {
        for state in [recording, preparing, waitingToPrepare, expiredBeforeSealing] {
            XCTAssertNil(state.applying(received()), "\(state.phase)")
            XCTAssertNil(state.applying(refused()), "\(state.phase)")
        }
    }

    func testTheOfficesReceiptAcknowledgesHoweverThePhoneThoughtTheTransferWasGoing() {
        // The phone never heard that the last chunk was served; the office has everything.
        var state = transferring.after(.progress(sentBytes: 1_000)).after(.notEligible(.noNetwork))
        XCTAssertTrue(state.apply(received()))
        XCTAssertEqual(state.phase, .acknowledged)
        XCTAssertEqual(state.sentBytes, total)
    }

    // MARK: - A receipt seen again

    func testAReplayedReceiptChangesNothing() {
        var state = acknowledged
        let before = state
        XCTAssertEqual(state.applying(received()), before)
        XCTAssertFalse(state.apply(received()))
        XCTAssertEqual(state, before)

        var later = trimmed
        XCTAssertFalse(later.apply(received()))
        XCTAssertEqual(later.phase, .trimmed, "a replay does not bring the media back into question")
    }

    func testARefusalCannotTakeBackAnAcknowledgement() {
        XCTAssertNil(acknowledged.applying(refused()))
        XCTAssertNil(trimmed.applying(refused()))
    }

    // MARK: - Refused and expired

    func testEachRefusalReasonTheContractNamesIsCarried() {
        XCTAssertEqual(Set(S.RefusalReason.allCases.map(\.rawValue)), ["signature", "binding", "digest", "too_large", "policy"])
        for reason in S.RefusalReason.allCases {
            XCTAssertEqual(delivered.applying(refused(reason))?.phase, .failed(reason))
        }
    }

    func testARefusedRecordingIsSentAgainFromTheStartWhenTheTechnicianKeepsWaiting() {
        var state = failed
        XCTAssertEqual(state.sentBytes, total)
        XCTAssertTrue(state.apply(.keepWaiting))
        XCTAssertEqual(state.phase, .sealed)
        XCTAssertEqual(state.sentBytes, 0)
        XCTAssertEqual(state.manifestSHA256, manifest)
    }

    func testAnExpiredRecordingGoesBackToWhereItWas() {
        XCTAssertEqual(expired.applying(.keepWaiting)?.phase, .sealed)
        XCTAssertEqual(expired.applying(.keepWaiting)?.sentBytes, total, "what was served stays served")
        XCTAssertEqual(expiredBeforeSealing.applying(.keepWaiting)?.phase, .preparing)
        XCTAssertEqual(waitingToPrepare.applying(.expiryReached)?.applying(.keepWaiting)?.phase, .preparing)
    }

    func testARefusalDoesNotAnswerAnExpiredRecording() {
        XCTAssertNil(expired.applying(refused()))
    }

    // MARK: - Progress

    func testProgressNeverGoesDownOrPastTheTotalAndSurvivesAnInterruption() {
        var state = transferring
        XCTAssertTrue(state.apply(.progress(sentBytes: 2_000)))
        XCTAssertFalse(state.apply(.progress(sentBytes: 1_000)), "a finished chunk is not unsent")
        XCTAssertFalse(state.apply(.progress(sentBytes: 3_001)))
        XCTAssertFalse(state.apply(.progress(sentBytes: 2_000)), "the same count again changes nothing")
        XCTAssertEqual(state.sentBytes, 2_000)

        XCTAssertTrue(state.apply(.notEligible(.officeNotReachable)))
        XCTAssertEqual(state.sentBytes, 2_000)
        XCTAssertTrue(state.apply(.transferStarted))
        XCTAssertEqual(state.phase, .transferring(sentBytes: 2_000, totalBytes: total))
    }

    func testAManifestWithNothingInItDoesNotSeal() {
        XCTAssertNil(preparing.applying(.sealed(manifestSHA256: manifest, totalBytes: 0)))
        XCTAssertNil(preparing.applying(.sealed(manifestSHA256: "", totalBytes: total)))
    }

    func testTheReasonForWaitingCanChange() {
        var state = waiting
        XCTAssertTrue(state.apply(.notEligible(.waitingForPower)))
        XCTAssertEqual(state.phase, .waiting(.notEligible(.waitingForPower)))
        XCTAssertFalse(state.apply(.notEligible(.waitingForPower)))
    }

    func testWaitingToPrepareIsNotWaitingToSend() {
        XCTAssertNil(waitingToPrepare.applying(.transferStarted))
        XCTAssertNil(waitingToPrepare.applying(.notEligible(.noNetwork)))
        XCTAssertNil(waiting.applying(.preparationResumed))
    }

    func testEachWaitReasonIsASentence() {
        XCTAssertEqual(S.WaitReason.openAppToPrepare.explanation, "Open Avenkin to prepare the recording.")
        XCTAssertEqual(S.WaitReason.notEligible(.noNetwork).explanation, SyncEligibility.Reason.noNetwork.explanation)
    }
}

private extension BundleSyncState {
    /// The state after an event that must apply.
    func after(_ event: Event) -> BundleSyncState {
        guard let next = applying(event) else {
            XCTFail("\(event) does not apply in \(phase)")
            return self
        }
        return next
    }
}
