import XCTest
@testable import OpenGlasses

/// Plan FS PR2 — what a vault link may be, what the app may say about it, and what the review
/// sheet decides before any of it reaches a screen.
final class VaultLinkPolicyTests: XCTestCase {

    // MARK: - The URL table

    func testTheLinkPolicyTable() {
        // Accepted.
        for accepted in ["https://manuals.example.com/v/acme.vaultarchive",
                         "https://manuals.example.com:8443/v/acme.vaultarchive",
                         "openglasses://vault?src=https%3A%2F%2Fmanuals.example.com%2Fv%2Facme.vaultarchive"] {
            guard case .success(let url) = VaultLinkPolicy.resolve(accepted) else {
                return XCTFail("\(accepted) should resolve")
            }
            XCTAssertEqual(url.scheme, "https")
        }

        // Refused, each for its own stated reason.
        let refusals: [(String, VaultLinkPolicy.Refusal)] = [
            ("http://manuals.example.com/acme.vaultarchive", .insecureScheme("http")),
            ("ftp://manuals.example.com/acme.vaultarchive", .insecureScheme("ftp")),
            ("https://buyer:token@manuals.example.com/acme.vaultarchive", .credentialsInURL),
            ("openglasses://vault", .missingSource),
            ("openglasses://vault?src=", .missingSource),
            ("openglasses://vault?src=http%3A%2F%2Fmanuals.example.com%2Fa", .insecureScheme("http")),
            ("openglasses://vault?src=https%3A%2F%2Fa.example.com%2Fa&install=1",
             .unexpectedParameters(["install"])),
            ("openglasses://skillpack?url=https%3A%2F%2Fa.example.com%2Fa", .notAVaultLink),
            ("", .notAVaultLink),
        ]
        for (raw, expected) in refusals {
            guard case .failure(let refusal) = VaultLinkPolicy.resolve(raw) else {
                return XCTFail("\(raw) should be refused")
            }
            XCTAssertEqual(refusal, expected, "\(raw)")
        }
    }

    func testOnlyTheHostIsEverRendered() throws {
        let url = try XCTUnwrap(URL(string: "https://manuals.example.com/d/ZZ9PLURAL/acme.vaultarchive?order=QX55TOKEN"))
        let shown = VaultLinkPolicy.displayHost(url)
        XCTAssertEqual(shown, "manuals.example.com")
        // Asserted on tokens that exist nowhere but in this URL's path and query, so the claim is
        // about the link and not about a word the host happens to share.
        XCTAssertFalse(shown.contains("ZZ9PLURAL"))
        XCTAssertFalse(shown.contains("QX55TOKEN"))
    }

    func testAPortIsKeptBecauseItIsPartOfTheSite() throws {
        let url = try XCTUnwrap(URL(string: "https://manuals.example.com:8443/a/b"))
        XCTAssertEqual(VaultLinkPolicy.displayHost(url), "manuals.example.com:8443")
    }

    func testARedirectToAnotherSiteIsNotTheSameSite() throws {
        let asked = try XCTUnwrap(URL(string: "https://manuals.example.com/a"))
        XCTAssertTrue(VaultLinkPolicy.isSameHost(asked, try XCTUnwrap(URL(string: "https://MANUALS.example.com/b"))))
        XCTAssertFalse(VaultLinkPolicy.isSameHost(asked, try XCTUnwrap(URL(string: "https://cdn.elsewhere.test/b"))))
        XCTAssertFalse(VaultLinkPolicy.isSameHost(asked, try XCTUnwrap(URL(string: "https://manuals.example.com:8443/b"))))
    }

    // MARK: - Who may install an unsigned vault

    func testMedicalModeAndTheOrganizationFlagBothForbidUnsigned() {
        XCTAssertTrue(VaultLinkInstallPolicy
            .resolve(medicalMode: false, organizationAllowsUnsigned: true).allowsUnsigned)

        let medical = VaultLinkInstallPolicy.resolve(medicalMode: true, organizationAllowsUnsigned: true)
        XCTAssertFalse(medical.allowsUnsigned)
        XCTAssertEqual(medical.unsigned, .forbiddenByMedicalMode)
        XCTAssertNotNil(medical.refusalMessage)

        let org = VaultLinkInstallPolicy.resolve(medicalMode: false, organizationAllowsUnsigned: false)
        XCTAssertEqual(org.unsigned, .forbiddenByOrganizationProfile)
        XCTAssertNotNil(org.refusalMessage)

        // Medical wins the wording when both apply: it is the one the reader cannot turn off here.
        XCTAssertEqual(VaultLinkInstallPolicy
            .resolve(medicalMode: true, organizationAllowsUnsigned: false).unsigned,
                       .forbiddenByMedicalMode)
    }

    func testTheOrganizationFlagDefaultsToAllowedOnAPhoneWithNoProfile() {
        let key = "organizationAllowsUnsignedVaults"
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertTrue(Config.organizationAllowsUnsignedVaults)
        Config.organizationAllowsUnsignedVaults = false
        XCTAssertFalse(Config.organizationAllowsUnsignedVaults)
    }

    // MARK: - The review sheet's decisions

    private func review(_ verification: VaultArchiveVerification,
                        policy: VaultLinkInstallPolicy = .init(unsigned: .allowedWithAcknowledgement),
                        bytes: Int = 4 * 1024 * 1024, cellular: Bool = false,
                        installedVersion: String? = nil) -> VaultLinkReview {
        VaultLinkReview(vaultName: "Acme RTU Service", vaultVersion: "1.2.0", vaultId: "acme_rtu",
                        host: "manuals.example.com", totalBytes: bytes,
                        manuals: ["RTU-500 Service Manual"], includesOriginalPDFs: false,
                        verification: verification, policy: policy, isOnCellular: cellular,
                        cellularWarningBytes: Config.vaultLinkCellularWarningBytes,
                        installedVersion: installedVersion)
    }

    func testASignedReviewNamesThePublisherAndInstallsOnOneConfirmation() {
        let review = review(.signed(publisherId: "acme", publisherName: "Acme Manuals"))
        XCTAssertEqual(review.signedLine, "Signed by Acme Manuals")
        XCTAssertNil(review.warningBlock)
        XCTAssertNil(review.refusal)
        XCTAssertFalse(review.requiresAcknowledgement)
        XCTAssertTrue(review.allowsInstall(acknowledged: false))
    }

    func testAnUnverifiedReviewWarnsAndNeedsASecondAcknowledgement() {
        for verification: VaultArchiveVerification in [.unverified(.notSigned),
                                                        .unverified(.unknownPublisher(claimedId: "x"))] {
            let review = review(verification)
            XCTAssertNil(review.signedLine, "an unverified archive never claims a publisher")
            XCTAssertEqual(review.warningBlock, VaultLinkReview.unverifiedWarning)
            XCTAssertTrue(review.requiresAcknowledgement)
            XCTAssertFalse(review.allowsInstall(acknowledged: false),
                           "the install button must stay disabled until the box is ticked")
            XCTAssertTrue(review.allowsInstall(acknowledged: true))
        }
    }

    func testTheWarningBlockSaysAllFourThings() {
        let block = VaultLinkReview.unverifiedWarning.joined(separator: " ").lowercased()
        XCTAssertTrue(block.contains("isn't signed"))
        XCTAssertTrue(block.contains("altered"))
        XCTAssertTrue(block.contains("steer the assistant"))
        XCTAssertTrue(block.contains("know and trust the source"))
    }

    func testEveryReviewSaysWhatAVaultDoes() {
        XCTAssertTrue(VaultLinkReview.groundingSentence.contains("guide the assistant's answers"))
    }

    func testARefusedArchiveHasNoInstallAndNoAcknowledgement() {
        let refusals: [VaultArchiveVerification.Refusal] = [
            .signatureInvalid, .contentsAltered("documents/manual.txt"),
            .revokedPublisher("Acme Manuals"), .headerDoesNotMatchVault("x"),
        ]
        for refusal in refusals {
            let review = review(.refused(refusal))
            XCTAssertNotNil(review.refusal, "\(refusal) must say why")
            XCTAssertFalse(review.requiresAcknowledgement)
            XCTAssertFalse(review.allowsInstall(acknowledged: true),
                           "\(refusal) must not be overridable by acknowledging it")
        }
    }

    func testAPolicyThatForbidsUnsignedRefusesRatherThanAsking() {
        for policy in [VaultLinkInstallPolicy(unsigned: .forbiddenByMedicalMode),
                       VaultLinkInstallPolicy(unsigned: .forbiddenByOrganizationProfile)] {
            let review = review(.unverified(.notSigned), policy: policy)
            XCTAssertEqual(review.refusal, policy.refusalMessage)
            XCTAssertFalse(review.allowsInstall(acknowledged: true))
        }
        // …and leaves a signed archive alone.
        let signed = review(.signed(publisherId: "acme", publisherName: "Acme Manuals"),
                            policy: VaultLinkInstallPolicy(unsigned: .forbiddenByMedicalMode))
        XCTAssertNil(signed.refusal)
        XCTAssertTrue(signed.allowsInstall(acknowledged: false))
    }

    func testTheCellularWarningAppearsOnlyAboveTheThreshold() {
        XCTAssertNil(review(.unverified(.notSigned), bytes: 1_000, cellular: true).cellularWarning)
        XCTAssertNil(review(.unverified(.notSigned),
                            bytes: Config.vaultLinkCellularWarningBytes, cellular: false).cellularWarning)
        let warned = review(.unverified(.notSigned),
                            bytes: Config.vaultLinkCellularWarningBytes, cellular: true)
        XCTAssertNotNil(warned.cellularWarning)
        XCTAssertTrue(warned.cellularWarning?.contains("cellular") == true)
    }

    func testAnUpdateSaysWhatItReplaces() {
        let fresh = review(.signed(publisherId: "acme", publisherName: "Acme Manuals"))
        XCTAssertEqual(fresh.installButtonTitle, "Install vault")
        XCTAssertNil(fresh.updateNote)

        let update = review(.signed(publisherId: "acme", publisherName: "Acme Manuals"),
                            installedVersion: "1.0.0")
        XCTAssertEqual(update.installButtonTitle, "Update from v1.0.0")
        XCTAssertTrue(update.updateNote?.contains("edits to the core files are kept") == true)
    }

    func testTheManualsSummarySaysWhetherTheOriginalsCame() {
        let text = review(.unverified(.notSigned))
        XCTAssertEqual(text.manualsSummary, "1 manual, already read for search")

        let withOriginals = VaultLinkReview(
            vaultName: "A", vaultVersion: "1", vaultId: "a", host: "h", totalBytes: 1,
            manuals: ["One", "Two"], includesOriginalPDFs: true,
            verification: .unverified(.notSigned),
            policy: .init(unsigned: .allowedWithAcknowledgement), isOnCellular: false,
            cellularWarningBytes: Config.vaultLinkCellularWarningBytes)
        XCTAssertEqual(withOriginals.manualsSummary,
                       "2 manuals, already read for search, with the manufacturers' PDFs")

        let none = VaultLinkReview(
            vaultName: "A", vaultVersion: "1", vaultId: "a", host: "h", totalBytes: 1,
            manuals: [], includesOriginalPDFs: false, verification: .unverified(.notSigned),
            policy: .init(unsigned: .allowedWithAcknowledgement), isOnCellular: false,
            cellularWarningBytes: Config.vaultLinkCellularWarningBytes)
        XCTAssertTrue(none.manualsSummary.contains("No manuals"))
    }

    // MARK: - Nothing written down carries the link

    func testTheAuditNoteCarriesTheHostAndNotTheLink() {
        let note = review(.signed(publisherId: "acme", publisherName: "Acme Manuals")).auditNote
        XCTAssertTrue(note.contains("host=manuals.example.com"))
        XCTAssertFalse(note.contains("https://"))
        XCTAssertFalse(note.contains("ZZ9PLURAL"))
    }

    // MARK: - The badge

    func testTheBadgeIsWhatTheReceiptAndThePublisherListAmountTo() {
        let signedReceipt = VaultReceipt(publisherId: "acme", publisherName: "Acme Manuals",
                                         verification: .signed, sourceHost: "manuals.example.com",
                                         receivedAt: Date(), archiveSHA256: "ab")
        let unsignedReceipt = VaultReceipt(publisherId: nil, publisherName: nil,
                                           verification: .unverified, sourceHost: "manuals.example.com",
                                           receivedAt: Date(), archiveSHA256: "ab")
        let active = VaultPublisher(id: "acme", name: "Acme Manuals", publicKey: "AAAA")
        let revoked = VaultPublisher(id: "acme", name: "Acme Manuals", publicKey: "AAAA", status: .revoked)

        XCTAssertNil(VaultSourceBadge.resolve(receipt: nil, publishers: [active]),
                     "a vault that did not come from a link is not badged at all")
        XCTAssertNil(VaultSourceBadge.resolve(receipt: signedReceipt, publishers: [active]))
        XCTAssertEqual(VaultSourceBadge.resolve(receipt: unsignedReceipt, publishers: [active]),
                       .unverifiedSource)
        XCTAssertEqual(VaultSourceBadge.resolve(receipt: signedReceipt, publishers: [revoked]),
                       .revokedPublisher("Acme Manuals"))
    }

    func testTheBadgeLinesAreTheOnesTheRecordCarries() {
        XCTAssertEqual(VaultSourceBadge.unverifiedSource.label, "Unverified source")
        XCTAssertEqual(VaultSourceBadge.unverifiedSource.recordLine(vaultName: "Acme RTU Service"),
                       "Reference vault: Acme RTU Service — unverified source.")
        XCTAssertTrue(VaultSourceBadge.revokedPublisher("Acme Manuals")
            .recordLine(vaultName: "Acme RTU Service").contains("no longer listed"))
    }

    func testAReceiptIsOnlySignedWhenASignatureActuallyVerified() {
        let now = Date()
        let signed = VaultReceipt.make(
            verification: .signed(publisherId: "acme", publisherName: "Acme Manuals"),
            host: "manuals.example.com", now: now, archiveSHA256: "ab")
        XCTAssertEqual(signed.verification, .signed)
        XCTAssertEqual(signed.publisherId, "acme")

        let claimed = VaultReceipt.make(verification: .unverified(.unknownPublisher(claimedId: "acme")),
                                        host: "manuals.example.com", now: now, archiveSHA256: "ab")
        XCTAssertEqual(claimed.verification, .unverified)
        XCTAssertNil(claimed.publisherId, "a claimed publisher is never written down as one")
        XCTAssertNil(claimed.publisherName)
    }
}
