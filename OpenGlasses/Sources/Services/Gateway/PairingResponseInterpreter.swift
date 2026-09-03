import Foundation

/// Live pairing/connection state, surfaced to the gateway settings UI.
enum PairingStatus: Equatable {
    case disconnected
    case connecting
    /// Bootstrap accepted; the device is awaiting approval on the gateway.
    case waitingApproval
    /// Connected and authenticated (newly paired, or an already-valid token).
    case paired
    case error(String)
}

/// The result of interpreting a gateway message: the new status, plus any device token the
/// gateway issued (which the caller persists), the parsed hello when the gateway sent one, and
/// the pairing-request bookkeeping a 2.0 gateway attaches to a pending approval.
struct PairingOutcome: Equatable {
    let status: PairingStatus
    let deviceToken: String?
    var hello: GatewayHello? = nil
    /// `error.details.requestId` — what an operator approves on the gateway host.
    var pairingRequestId: String? = nil
    /// `error.details.recommendedNextStep` — the gateway's own retry guidance.
    var recommendedNextStep: String? = nil
    /// `error.details.pauseReconnect` — the gateway asked us not to hammer it.
    var pauseReconnect: Bool = false
}

/// Pure mapping from a gateway `res`/`event` JSON to a `PairingOutcome`. No I/O — exhaustively
/// tested against the success, pending-approval, and failure shapes of both the pre-2.0 and the
/// 2.0 gateway.
enum PairingResponseInterpreter {

    /// Interpret a `res` response to the connect handshake.
    static func interpretResponse(_ json: [String: Any]) -> PairingOutcome {
        let ok = json["ok"] as? Bool ?? false

        if ok {
            // 2.0: `hello-ok` carries the issued device token under `auth.deviceToken`.
            if let hello = GatewayHello.parse(response: json) {
                return PairingOutcome(status: .paired, deviceToken: hello.deviceToken, hello: hello)
            }
            // Pre-2.0: a device token in the result means pairing just completed.
            if let result = json["result"] as? [String: Any],
               let token = (result["token"] as? String), !token.isEmpty {
                return PairingOutcome(status: .paired, deviceToken: token)
            }
            // Otherwise it's an ordinary authenticated connect (shared token / already paired).
            return PairingOutcome(status: .paired, deviceToken: nil)
        }

        let error = json["error"] as? [String: Any]
        let details = error?["details"] as? [String: Any]
        let message = (error?["message"] as? String) ?? "Connection failed"
        let detailCode = details?["code"] as? String
        if detailCode == "PAIRING_REQUIRED" || isPendingApproval(code: error?["code"], message: message) {
            return PairingOutcome(
                status: .waitingApproval,
                deviceToken: nil,
                pairingRequestId: details?["requestId"] as? String,
                recommendedNextStep: details?["recommendedNextStep"] as? String,
                pauseReconnect: details?["pauseReconnect"] as? Bool ?? false
            )
        }
        return PairingOutcome(status: .error(message), deviceToken: nil,
                              recommendedNextStep: details?["recommendedNextStep"] as? String)
    }

    /// Interpret a `device.paired` event payload (the pre-2.0 gateway approved out-of-band).
    static func interpretPairedEvent(_ payload: [String: Any]) -> PairingOutcome? {
        guard let token = payload["token"] as? String, !token.isEmpty else { return nil }
        return PairingOutcome(status: .paired, deviceToken: token)
    }

    /// True when an error means "waiting for the user to approve this device on the gateway".
    /// Tolerates the code being a string (`"pairing_pending"`) or the message mentioning it.
    static func isPendingApproval(code: Any?, message: String) -> Bool {
        if let codeString = code as? String,
           codeString == "pairing_pending" || codeString == "pairing_required"
            || codeString == "PAIRING_REQUIRED" {
            return true
        }
        let lower = message.lowercased()
        return lower.contains("pairing") || lower.contains("approval") || lower.contains("approve")
    }
}
