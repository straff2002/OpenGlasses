import Foundation

#if AVENKIN_OFFICE_TRANSPORT
import Mobilecore
#endif

/// The app's `OfficeCommissionTransport`: the commissioning functions of the embedded mobile
/// core, which hold the contract's encoding and the TLS connection pinned to the office's
/// transport identity. Only the opt-in office transport build links that core; any other build
/// has no transport, and joining an office by its code says so.
enum OfficeCommissionMobilecoreTransport {
    static func makeIfAvailable() -> (any OfficeCommissionTransport)? {
        #if AVENKIN_OFFICE_TRANSPORT
        return Bridge()
        #else
        return nil
        #endif
    }

    #if AVENKIN_OFFICE_TRANSPORT
    /// Each gomobile function returns a string and reports failure through its last argument. The
    /// calls block (the exchange is a network request), so each runs off the caller's thread.
    private struct Bridge: OfficeCommissionTransport {
        func readQR(_ qrText: String, now: Int64) async throws -> String {
            try await call { MobilecoreCommissionReadQR(qrText, now, $0) }
        }

        func redemptionSigningInput(invitationEnvelope: String, enrolmentID: String,
                                    phoneTransportID: String, phoneApplicationKey: String,
                                    appVersion: String, appBuild: String,
                                    existingEnrolment: String, now: Int64) async throws -> String {
            try await call {
                MobilecoreCommissionRedemptionSigningInput(
                    invitationEnvelope, enrolmentID, phoneTransportID, phoneApplicationKey,
                    appVersion, appBuild, existingEnrolment, now, $0)
            }
        }

        func sealRedemption(invitationEnvelope: String, payloadBase64: String,
                            signatureBase64: String) async throws -> String {
            try await call { MobilecoreCommissionSealRedemption(invitationEnvelope, payloadBase64, signatureBase64, $0) }
        }

        func comparison(invitationEnvelope: String, redemptionEnvelope: String) async throws -> String {
            try await call { MobilecoreCommissionComparison(invitationEnvelope, redemptionEnvelope, $0) }
        }

        func exchange(invitationEnvelope: String, redemptionEnvelope: String) async throws -> String {
            try await call { MobilecoreCommissionExchange(invitationEnvelope, redemptionEnvelope, $0) }
        }

        private func call(_ body: @escaping @Sendable (NSErrorPointer) -> String) async throws -> String {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    var error: NSError?
                    let value = body(&error)
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: value)
                    }
                }
            }
        }
    }
    #endif
}
