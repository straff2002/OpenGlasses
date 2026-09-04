import XCTest
@testable import OpenGlasses

/// Maps gateway `res`/`event` JSON to a `PairingOutcome` — the pure interpretation the live
/// `OpenClawEventClient` applies. JSON via `JSONSerialization` so `NSNumber`/`Bool` bridging
/// matches production.
final class PairingResponseInterpreterTests: XCTestCase {

    private func json(_ string: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: string.data(using: .utf8)!)) as? [String: Any] ?? [:]
    }

    func testApprovedResponseWithDeviceTokenPairs() {
        let outcome = PairingResponseInterpreter.interpretResponse(json("""
        {"ok":true,"result":{"token":"device-xyz"}}
        """))
        XCTAssertEqual(outcome.status, .paired)
        XCTAssertEqual(outcome.deviceToken, "device-xyz")
    }

    func testOkWithoutTokenIsAuthenticatedConnect() {
        let outcome = PairingResponseInterpreter.interpretResponse(json(#"{"ok":true}"#))
        XCTAssertEqual(outcome.status, .paired)
        XCTAssertNil(outcome.deviceToken)
    }

    func testPendingApprovalByCode() {
        let outcome = PairingResponseInterpreter.interpretResponse(json("""
        {"ok":false,"error":{"code":"pairing_pending","message":"nope"}}
        """))
        XCTAssertEqual(outcome.status, .waitingApproval)
        XCTAssertNil(outcome.deviceToken)
    }

    func testPendingApprovalByMessage() {
        let outcome = PairingResponseInterpreter.interpretResponse(json("""
        {"ok":false,"error":{"message":"Device pairing requires approval"}}
        """))
        XCTAssertEqual(outcome.status, .waitingApproval)
    }

    func testGenericErrorSurfacesMessage() {
        let outcome = PairingResponseInterpreter.interpretResponse(json("""
        {"ok":false,"error":{"code":"token_invalid","message":"Bad token"}}
        """))
        XCTAssertEqual(outcome.status, .error("Bad token"))
    }

    func testErrorWithNoMessageStillFails() {
        let outcome = PairingResponseInterpreter.interpretResponse(json(#"{"ok":false}"#))
        if case .error = outcome.status { /* ok */ } else {
            XCTFail("Expected an error status, got \(outcome.status)")
        }
    }

    func testPairedEventWithToken() {
        let outcome = PairingResponseInterpreter.interpretPairedEvent(json(#"{"token":"evt-tok"}"#))
        XCTAssertEqual(outcome?.status, .paired)
        XCTAssertEqual(outcome?.deviceToken, "evt-tok")
    }

    func testPairedEventWithoutTokenIsNil() {
        XCTAssertNil(PairingResponseInterpreter.interpretPairedEvent(json("{}")))
    }

    func testIsPendingApprovalHelper() {
        XCTAssertTrue(PairingResponseInterpreter.isPendingApproval(code: "pairing_required", message: ""))
        XCTAssertTrue(PairingResponseInterpreter.isPendingApproval(code: nil, message: "Please APPROVE the device"))
        XCTAssertFalse(PairingResponseInterpreter.isPendingApproval(code: "other", message: "denied"))
    }

    // MARK: - 2.0 gateway shapes

    func testHelloOkCarriesTheDeviceTokenAndCatalog() {
        let outcome = PairingResponseInterpreter.interpretResponse(json("""
        {"type":"res","id":"c","ok":true,"payload":{"type":"hello-ok","protocol":4,
          "server":{"version":"2026.8.2","connId":"x"},
          "features":{"methods":["sessions.send"],"events":["chat"]},"snapshot":{},
          "auth":{"role":"operator","scopes":["operator.read"],"deviceToken":"dev-2"},
          "policy":{"maxPayload":1,"maxBufferedBytes":1,"tickIntervalMs":1}}}
        """))
        XCTAssertEqual(outcome.status, .paired)
        XCTAssertEqual(outcome.deviceToken, "dev-2", "2.0 issues the token under auth.deviceToken")
        XCTAssertTrue(outcome.hello?.supports("sessions.send") ?? false)
    }

    func testPairingRequiredDetailsAreSurfaced() {
        let outcome = PairingResponseInterpreter.interpretResponse(json("""
        {"type":"res","id":"c","ok":false,"error":{"code":"INVALID_REQUEST","message":"device not paired",
          "details":{"code":"PAIRING_REQUIRED","reason":"not-paired","requestId":"req-77",
                     "recommendedNextStep":"wait_then_retry","pauseReconnect":true}}}
        """))
        XCTAssertEqual(outcome.status, .waitingApproval)
        XCTAssertEqual(outcome.pairingRequestId, "req-77")
        XCTAssertEqual(outcome.recommendedNextStep, "wait_then_retry")
        XCTAssertTrue(outcome.pauseReconnect)
        XCTAssertNil(outcome.deviceToken)
    }

    func testStaleSignatureIsAnErrorNotAPendingApproval() {
        let outcome = PairingResponseInterpreter.interpretResponse(json("""
        {"type":"res","id":"c","ok":false,"error":{"code":"INVALID_REQUEST","message":"device signature expired",
          "details":{"code":"DEVICE_AUTH_INVALID","reason":"device-signature-stale"}}}
        """))
        XCTAssertEqual(outcome.status, .error("device signature expired"))
    }
}
