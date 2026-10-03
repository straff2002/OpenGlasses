import Foundation

/// The decisions of joining an office by scanning its code (Contracts/commissioning.md), with no
/// clock, storage, key or network of their own: the caller passes what the phone knows and what
/// the transport answered, and gets back what happens next.
///
/// The phone's own values are the authority throughout (contract §4): its enrolment and its
/// identities come from its storage, an office's code never chooses them, and an approval naming
/// any other enrolment is refused even though the transport has checked it too.
enum OfficeCommissioningFlow {

    /// Why the phone stops before it connects to the office.
    enum NotStarted: Equatable, Sendable {
        /// This build has no office transport.
        case unsupportedBuild
        /// Not an office code Avenkin can read, or one that failed its checks.
        case malformed
        /// The office's code is past its fifteen minutes (or not yet live on this phone's clock).
        case expired
        /// The phone is managed by another organisation (contract §4). Named when known.
        case enrolledElsewhere(organization: String?)
        /// The phone could not read its own transport identity or application key.
        case noIdentity
    }

    /// Why a started exchange ended without this phone joining the office.
    enum Failure: Equatable, Sendable {
        /// The redemption could not be built, signed or sealed.
        case couldNotAnswer
        /// The office's answer could not be read.
        case unreadableAnswer
        /// The approval names an enrolment other than the one this phone chose.
        case approvalForAnotherPhone
        /// The profile in the approval is for another organisation than the code named.
        case otherOrganisationsSetup
        /// The vendor-signed profile and licence did not verify; the text says why.
        case setupDidNotVerify(String)
        /// The administrator-signed peer binding did not verify. Nothing was applied.
        case bindingDidNotVerify
        /// The profile could not be applied; the text says why.
        case notApplied(String)
        /// The profile is in force but the office binding could not be kept.
        case bindingNotKept
    }

    /// What the phone knows about its own enrolment before it answers an office.
    struct CurrentEnrolment: Equatable, Sendable {
        /// Whether a verified organisation profile is in force.
        var isManaged: Bool
        /// The office organisation of the profile in force, when it is a schema-2 profile.
        var organizationID: String?
        var organizationName: String?

        static let none = CurrentEnrolment(isManaged: false, organizationID: nil, organizationName: nil)
    }

    // MARK: - Before connecting

    /// Contract §4: a phone already enrolled to another organisation refuses before connecting. A
    /// profile with no office organisation (an earlier, hosted profile) cannot be shown to be the
    /// same organisation, so it is treated as another one.
    static func beforeConnecting(_ invitation: OfficeCommissioning.Invitation,
                                 current: CurrentEnrolment, now: Int64) -> NotStarted? {
        guard now >= invitation.issuedAt, now < invitation.expiresAt else { return .expired }
        if current.isManaged, current.organizationID != invitation.organizationID {
            return .enrolledElsewhere(organization: current.organizationName)
        }
        return nil
    }

    /// The redemption's `existingEnrolment`: empty, or the organisation already in force. Called
    /// only after `beforeConnecting` has let the invitation through, so it is the same one.
    static func existingEnrolment(_ current: CurrentEnrolment) -> String {
        current.isManaged ? (current.organizationID ?? "") : ""
    }

    /// Which words to use for a code the transport refused. The unauthenticated contents are read
    /// only to tell "expired" from "not a code we can read"; nothing else depends on them.
    static func unreadable(qrText: String, now: Int64) -> NotStarted {
        let text = qrText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix(OfficeCommissioning.qrPrefix) else { return .malformed }
        var encoded = String(text.dropFirst(OfficeCommissioning.qrPrefix.count))
            .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while encoded.count % 4 != 0 { encoded += "=" }
        struct Envelope: Decodable { let payload: String }
        struct Window: Decodable { let issuedAt: Int64; let expiresAt: Int64 }
        guard let envelopeBytes = Data(base64Encoded: encoded),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: envelopeBytes),
              let payload = Data(base64Encoded: envelope.payload),
              let window = try? JSONDecoder().decode(Window.self, from: payload) else { return .malformed }
        return now >= window.expiresAt ? .expired : .malformed
    }

    // MARK: - The redemption

    static let redemptionDomain = Data("Avenkin.CommissionRedemption.v1\0".utf8)

    /// The bytes the phone signs must be exactly the domain, a zero byte and the payload it seals,
    /// so what the office verifies is what this phone meant to send.
    static func checkedSigningInput(_ input: OfficeCommissioning.SigningInput) -> (payload: Data, signingInput: Data)? {
        guard let payload = Data(base64Encoded: input.payload), !payload.isEmpty,
              let signingInput = Data(base64Encoded: input.signingInput),
              signingInput == redemptionDomain + payload else { return nil }
        return (payload, signingInput)
    }

    // MARK: - Waiting for the office

    enum AfterAnswer: Equatable, Sendable {
        case keepWaiting
        case approved(OfficeCommissioning.Approval)
        case refused(OfficeCommissioning.RefusalReason)
        case expired
        case failed(Failure)
    }

    /// What one answer from the office means. The approval's echoed enrolment must be the one this
    /// phone chose; the transport checks that too, but this phone's own value decides.
    static func afterAnswer(_ decision: OfficeCommissioning.Decision, chosenEnrolmentID: String,
                            expiresAt: Int64, now: Int64) -> AfterAnswer {
        switch decision {
        case .awaiting:
            return now >= expiresAt ? .expired : .keepWaiting
        case .approved(let approval):
            guard approval.enrolmentID == chosenEnrolmentID else { return .failed(.approvalForAnotherPhone) }
            return .approved(approval)
        case .refused(let reason):
            return .refused(reason)
        }
    }

    /// Failed exchanges in a row that are retried without interrupting the person: a network blip
    /// while someone at the office reads the code should not end the exchange.
    static let quietRetries = 2

    enum AfterNetworkFailure: Equatable, Sendable {
        case tryAgainQuietly
        /// Ask the person; a retry sends the same redemption again.
        case offerRetry
        case expired
    }

    static func afterNetworkFailure(consecutive: Int, expiresAt: Int64, now: Int64) -> AfterNetworkFailure {
        if now >= expiresAt { return .expired }
        return consecutive <= quietRetries ? .tryAgainQuietly : .offerRetry
    }

    /// Whether to ask the office again now.
    static func shouldAsk(expiresAt: Int64, now: Int64) -> Bool { now < expiresAt }

    // MARK: - The approval

    /// The vendor-signed profile in an approval must be for the organisation the code named.
    static func setupMatchesInvitation(profileOrganizationID: String?,
                                       invitation: OfficeCommissioning.Invitation) -> Bool {
        profileOrganizationID == invitation.organizationID
    }

    // MARK: - The comparison code

    private static let crockford = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// The code's three groups of four, for showing large. Nil for anything that is not a code.
    static func comparisonGroups(_ code: String) -> [String]? {
        let groups = code.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard groups.count == 3,
              groups.allSatisfy({ $0.count == 4 && $0.allSatisfy(crockford.contains) }) else { return nil }
        return groups
    }
}
