import Foundation

/// The seam between joining an office by its code and the connection that carries the exchange
/// (Contracts/commissioning.md). Each method mirrors one function of the gomobile package
/// `mobilecore` and returns exactly the text that function returns. The contract's exact-byte
/// encoding and the TLS connection pinned to the office's transport identity live behind it, in
/// Go; this phone's keys, its enrolment and every decision stay on the Swift side.
///
/// The app's implementation is `OfficeCommissionMobilecoreTransport`, in the opt-in office
/// transport build only. Tests drive the flow through a fake.
protocol OfficeCommissionTransport: Sendable {
    /// `CommissionReadQR`: checks the scanned text and the invitation inside it (signature,
    /// lifetime, private address, office ID derivation). Returns `OfficeCommissioning.Invitation`
    /// as JSON; throws for anything that is not a live invitation.
    func readQR(_ qrText: String, now: Int64) async throws -> String

    /// `CommissionRedemptionSigningInput`: the redemption payload and the exact bytes the phone
    /// signs with its application key (domain, zero byte, payload), as
    /// `OfficeCommissioning.SigningInput` JSON. `phoneApplicationKey` is standard base64.
    func redemptionSigningInput(invitationEnvelope: String, enrolmentID: String,
                                phoneTransportID: String, phoneApplicationKey: String,
                                appVersion: String, appBuild: String,
                                existingEnrolment: String, now: Int64) async throws -> String

    /// `CommissionSealRedemption`: the redemption envelope, from the payload and its signature
    /// (both standard base64).
    func sealRedemption(invitationEnvelope: String, payloadBase64: String,
                        signatureBase64: String) async throws -> String

    /// `CommissionComparison`: the code both screens show, `XXXX-XXXX-XXXX`.
    func comparison(invitationEnvelope: String, redemptionEnvelope: String) async throws -> String

    /// `CommissionExchange`: one request to the office, pinned to the invitation's office
    /// transport identity. Returns `{"status":"awaiting"}`, an approval or a refusal, already
    /// checked against this invitation and redemption. The caller repeats it until decided.
    func exchange(invitationEnvelope: String, redemptionEnvelope: String) async throws -> String
}

/// What the transport's JSON answers mean on the phone. Decoding only: none of these values is
/// trusted for more than the contract gives it.
enum OfficeCommissioning {
    /// The QR text's prefix. Not a URL scheme the app registers: only the in-app scanner acts on it.
    static let qrPrefix = "avenkin-commission:"
    /// How often the phone asks the office again while a person decides.
    static let pollInterval: UInt64 = 2_000_000_000

    /// Whether scanned text is an office's invitation rather than an organisation enrolment code.
    /// Only the routing looks at this; the transport checks the text itself, exactly as scanned.
    static func isCommissioningCode(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(qrPrefix)
    }

    /// The invitation, as `CommissionReadQR` returns it after checking it.
    struct Invitation: Decodable, Equatable, Sendable {
        let invitationEnvelope: String
        let invitationSHA256: String
        let organizationID: String
        let officeID: String
        /// Standard base64 of the office's 32-byte Ed25519 application key.
        let officeApplicationKey: String
        let officeTransportID: String
        /// The bootstrap listener, `a.b.c.d:port`. A route hint, never authority.
        let address: String
        let issuedAt: Int64
        let expiresAt: Int64
    }

    /// The redemption payload and the bytes to sign, as `CommissionRedemptionSigningInput` returns them.
    struct SigningInput: Decodable, Equatable, Sendable {
        let payload: String
        let signingInput: String
    }

    /// The office's approval: three artefacts the phone verifies with the code it already has.
    struct Approval: Equatable, Sendable {
        let enrolmentID: String
        let profileDocument: String
        let licenceCode: String
        let peerBinding: String
        let decisionEnvelope: String
    }

    /// The closed set of reasons an office may give (contract §2.5).
    enum RefusalReason: String, CaseIterable, Equatable, Sendable {
        case expired
        case alreadyUsed = "already_used"
        case wrongOrganisation = "wrong_organisation"
        case refusedByPerson = "refused_by_person"
        case policy
    }

    enum Decision: Equatable, Sendable {
        case awaiting
        case approved(Approval)
        case refused(RefusalReason)
    }

    enum DecodingFailure: Error, Equatable {
        case malformed
    }

    static func decodeInvitation(_ json: String) throws -> Invitation {
        guard let invitation = try? JSONDecoder().decode(Invitation.self, from: Data(json.utf8)) else {
            throw DecodingFailure.malformed
        }
        return invitation
    }

    static func decodeSigningInput(_ json: String) throws -> SigningInput {
        guard let input = try? JSONDecoder().decode(SigningInput.self, from: Data(json.utf8)) else {
            throw DecodingFailure.malformed
        }
        return input
    }

    static func decodeDecision(_ json: String) throws -> Decision {
        struct Answer: Decodable {
            let status: String
            let enrolmentID: String?
            let profileDocument: String?
            let licenceCode: String?
            let peerBinding: String?
            let decisionEnvelope: String?
            let reason: String?
        }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: Data(json.utf8)) else {
            throw DecodingFailure.malformed
        }
        switch answer.status {
        case "awaiting":
            return .awaiting
        case "approved":
            guard let enrolmentID = answer.enrolmentID, let profileDocument = answer.profileDocument,
                  let licenceCode = answer.licenceCode, let peerBinding = answer.peerBinding,
                  let decisionEnvelope = answer.decisionEnvelope,
                  !profileDocument.isEmpty, !licenceCode.isEmpty, !peerBinding.isEmpty else {
                throw DecodingFailure.malformed
            }
            return .approved(Approval(enrolmentID: enrolmentID, profileDocument: profileDocument,
                                      licenceCode: licenceCode, peerBinding: peerBinding,
                                      decisionEnvelope: decisionEnvelope))
        case "refused":
            guard let reason = answer.reason.flatMap(RefusalReason.init(rawValue:)) else {
                throw DecodingFailure.malformed
            }
            return .refused(reason)
        default:
            throw DecodingFailure.malformed
        }
    }
}
