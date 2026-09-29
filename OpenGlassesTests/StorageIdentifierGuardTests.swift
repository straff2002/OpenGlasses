import XCTest
@testable import OpenGlasses

/// Pins every stored or signed identifier that happens to be spelled like the product's name, so a
/// rename cannot reach them.
///
/// The keychain service holding **every stored API key** is the literal `"OpenGlasses"`. It looks
/// like the product name, so a find-and-replace during a rename would change it and silently empty
/// the keychain on the next launch. The App Group, the conversation-key account, the signing domains,
/// the store product ids, the job file type and a few wire ids carry the same risk: each one is
/// already written into a Keychain, a container, a signature, an App Store Connect record or a file
/// someone has been sent, and none of those follow a rename.
///
/// Same drift-guard shape as `TelemetryOptOutGuardTests`: constants the app reads are compared
/// through `@testable import`; the copies a constant cannot reach (entitlements, `Info.plist`, the
/// project spec, the signing scripts, the watch targets, the desktop contracts) are read from the
/// repository. Every failure names what the change would break.
///
/// The `avenkin.*` signed kinds are pinned too. They are already spelled with the new name, and are
/// signing domains all the same: they must never become "Avenkin Office".
final class StorageIdentifierGuardTests: XCTestCase {

    // MARK: - The legacy spelling
    //
    // Assembled from pieces on purpose. The rename this suite guards against is a find-and-replace
    // of the old product name; written out whole, the expected values below would be rewritten by
    // the same replace, alongside the code they check, and the suite would pass over the damage.

    /// The lower-case slug, as in `com.<slug>.app`.
    private static let slug = "open" + "glasses"
    /// The capitalised name, as in the keychain service.
    private static let name = "Open" + "Glasses"

    private static let appGroup = "group.com.\(slug).app"
    private static let bundleIdentifier = "com.\(slug).app"

    // MARK: - Repo anchor
    //
    // `#filePath` is baked in at compile time, so it resolves the same on a developer machine and
    // in CI, and the simulator shares the host filesystem. Same anchor as `TelemetryOptOutGuardTests`.

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)   // <repo>/OpenGlassesTests/<thisfile>.swift
            .deletingLastPathComponent()  // <repo>/OpenGlassesTests
            .deletingLastPathComponent()  // <repo>
    }

    private func sourceText(_ relativePath: String) throws -> String {
        let url = Self.repoRoot.appendingPathComponent(relativePath)
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            XCTFail("\(relativePath) could not be read — the guard lost sight of an identifier it pins")
            throw error
        }
    }

    private func plist(_ relativePath: String) throws -> [String: Any] {
        let data = try Data(contentsOf: Self.repoRoot.appendingPathComponent(relativePath))
        let parsed = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return try XCTUnwrap(parsed as? [String: Any], "\(relativePath) is not a dictionary")
    }

    /// Every `.swift` file under the given repository directories.
    private func swiftFiles(under directories: [String]) -> [(path: String, text: String)] {
        var files: [(String, String)] = []
        for directory in directories {
            let root = Self.repoRoot.appendingPathComponent(directory)
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
            else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let relative = url.path.replacingOccurrences(of: Self.repoRoot.path + "/", with: "")
                files.append((relative, text))
            }
        }
        return files
    }

    // MARK: - Keychain storage keys

    func testKeychainServiceIsPinned() {
        XCTAssertEqual(KeychainService.storageService, Self.name,
                       "KeychainService.storageService changed. It is the Keychain service every "
                           + "stored item is filed under: changing it loses every stored API key, "
                           + "auth token and saved-model secret on the next launch.")
    }

    func testConversationKeyIsPinned() {
        XCTAssertEqual(ConversationEncryptionService.storageAccount, "com.\(Self.slug).conversation-key",
                       "ConversationEncryptionService.storageAccount changed. The conversation "
                           + "encryption key is looked up by it: changing it makes encrypted "
                           + "conversation history unreadable.")
        XCTAssertEqual(ConversationEncryptionService.storageService, Self.name,
                       "ConversationEncryptionService.storageService changed. Changing it makes "
                           + "encrypted conversation history unreadable.")
    }

    func testScopedKeyServiceIsPinned() {
        XCTAssertEqual(KeychainScopedKeyStore.storageService, "\(Self.name).ScopedKey",
                       "KeychainScopedKeyStore.storageService changed. The per-class erasure keys "
                           + "are looked up by it: changing it makes enrolled face templates and "
                           + "scoped conversation content unreadable, an erasure nobody asked for.")
    }

    // MARK: - Signing domains

    private func text(_ data: Data) -> String? { String(data: data, encoding: .utf8) }

    func testOrgProfileSigningDomainsArePinned() {
        XCTAssertEqual(text(ProfileVerification.profileSigningDomain), "\(Self.slug).org-profile.v1\n",
                       "ProfileVerification.profileSigningDomain changed. Every issued org profile "
                           + "was signed over it: changing it stops every one verifying.")
        XCTAssertEqual(text(ProfileVerification.revocationSigningDomain), "\(Self.slug).org-revocation.v1\n",
                       "ProfileVerification.revocationSigningDomain changed. Every issued revocation "
                           + "stops verifying, so a revoked profile would be honoured again.")
        XCTAssertEqual(ConfigProfile.formatId, "\(Self.slug).org-profile",
                       "ConfigProfile.formatId changed. It is inside every issued profile's signed "
                           + "payload: changing it refuses every issued profile as malformed.")
        XCTAssertEqual(ProfileRevocation.formatId, "\(Self.slug).org-revocation",
                       "ProfileRevocation.formatId changed. Changing it refuses every issued "
                           + "revocation, so a revoked profile would be honoured again.")
    }

    func testAdminCardSigningDomainIsPinned() {
        XCTAssertEqual(AdminSecrets.cardSigningDomain, "\(Self.slug).admin-card.v1\n",
                       "AdminSecrets.cardSigningDomain changed. Every issued admin card would stop "
                           + "matching its profile's verifier, locking administrators out.")
    }

    func testActivationKeyDomainsArePinned() {
        XCTAssertEqual(ActivationKey.fileIdSigningDomain, "\(Self.slug).activation-id.v1\n",
                       "ActivationKey.fileIdSigningDomain changed. Every issued activation key would "
                           + "look for a file nothing was published under, and stop activating.")
        XCTAssertEqual(ActivationKey.sealingSigningDomain, "\(Self.slug).activation-key.v1",
                       "ActivationKey.sealingSigningDomain changed. Every issued activation key would "
                           + "derive the wrong key and fail to open its licence.")
    }

    func testAuditExportSchemaIsPinned() {
        XCTAssertEqual(AuditLogExportDocument.schemaSigningDomain, "\(Self.slug).audit.v1",
                       "AuditLogExportDocument.schemaSigningDomain changed. Audit exports already "
                           + "held by reviewers would no longer match what the app emits; a real "
                           + "schema change bumps the version, never the name.")
    }

    /// The scripts that mint profiles, admin cards and activation keys must produce byte-identical
    /// domains. They are scripts, not app code, so a constant cannot reach them.
    func testSigningScriptsMirrorTheDomains() throws {
        let orgProfile = try sourceText("Scripts/make-org-profile.swift")
        for literal in ["\"\(Self.slug).org-profile.v1\\n\"",
                        "\"\(Self.slug).org-revocation.v1\\n\"",
                        "\"\(Self.slug).admin-card.v1\\n\"",
                        "\"\(Self.slug).org-profile\"",
                        "\"\(Self.slug).org-revocation\""] {
            XCTAssertTrue(orgProfile.contains(literal),
                          "Scripts/make-org-profile.swift no longer mints with \(literal). Profiles, "
                              + "revocations and admin cards it issues would stop verifying on phones.")
        }

        let licence = try sourceText("Scripts/generate-field-license.swift")
        for literal in ["\"\(Self.slug).activation-id.v1\\n\"",
                        "\"\(Self.slug).activation-key.v1\""] {
            XCTAssertTrue(licence.contains(literal),
                          "Scripts/generate-field-license.swift no longer derives with \(literal). "
                              + "Activation keys it issues would stop activating on phones.")
        }
    }

    // MARK: - Store product ids

    func testStoreProductIdsArePinned() {
        let expected: [(String, String)] = [
            (StoreKitService.medicalMonthlyId, "com.\(Self.slug).medical_compliance_monthly"),
            (StoreKitService.medicalAnnualId, "com.\(Self.slug).medical_compliance_annual"),
            (StoreKitService.fieldAssistId, "com.\(Self.slug).field_assist"),
            (StoreKitService.fieldAssistMonthlyId, "com.\(Self.slug).field_assist_monthly"),
            (StoreKitService.fieldAssistAnnualId, "com.\(Self.slug).field_assist_annual"),
            (VaultPackManifest.productPrefix, "com.\(Self.slug).vault."),
        ]
        for (actual, pinned) in expected {
            XCTAssertEqual(actual, pinned,
                           "A store product id changed (\(pinned)). Product ids can never be renamed "
                               + "in App Store Connect: changing it strands every subscriber and "
                               + "purchaser, who would lose Field Assist, Medical Compliance or a pack.")
        }
    }

    // MARK: - The job file

    func testJobFileTypeIsPinned() throws {
        let uti = "com.\(Self.slug).app.job"
        let mime = "application/vnd.\(Self.slug).job+json"
        XCTAssertEqual(JobFile.typeIdentifier, uti,
                       "JobFile.typeIdentifier changed. Job files already sent would stop opening in the app.")
        XCTAssertEqual(JobFile.format, "\(Self.slug).job",
                       "JobFile.format changed. Job files offices have already sent would be refused.")

        let info = try plist("OpenGlasses/Info.plist")
        let exported = (info["UTExportedTypeDeclarations"] as? [[String: Any]]) ?? []
        let declaration = exported.first { $0["UTTypeIdentifier"] as? String == uti }
        XCTAssertNotNil(declaration,
                        "OpenGlasses/Info.plist no longer exports \(uti). Job files already sent "
                            + "would stop opening in the app.")
        let tags = declaration?["UTTypeTagSpecification"] as? [String: Any]
        XCTAssertEqual(tags?["public.mime-type"] as? [String], [mime],
                       "OpenGlasses/Info.plist no longer tags \(uti) with \(mime). Job files mailed "
                           + "with that type would stop opening in the app.")

        let documentTypes = (info["CFBundleDocumentTypes"] as? [[String: Any]]) ?? []
        let handled = documentTypes.flatMap { ($0["LSItemContentTypes"] as? [String]) ?? [] }
        XCTAssertTrue(handled.contains(uti),
                      "OpenGlasses/Info.plist no longer claims \(uti) as a document type. Job files "
                          + "already sent would stop opening in the app.")
    }

    // MARK: - Wire identifiers

    func testWireIdentifiersArePinned() throws {
        XCTAssertEqual(MCPClient.idempotencyMetaKey, "nz.co.skunkworks.\(Self.slug)/idempotency-key",
                       "MCPClient.idempotencyMetaKey changed. MCP servers that key idempotency on it "
                           + "would stop recognising retries and could run a tool call twice.")

        let bounded = try sourceText("OpenGlasses/Sources/Services/Security/BoundedHTTPClient.swift")
        for label in ["nz.co.\(Self.slug).bounded-http.verify", "nz.co.\(Self.slug).bounded-http.connection"] {
            XCTAssertTrue(bounded.contains("\"\(label)\""),
                          "BoundedHTTPClient no longer uses \(label). Log correlation keyed on it "
                              + "would stop matching.")
        }
    }

    // MARK: - App Group

    func testAppGroupConstantsArePinned() {
        let breaks = "The widget, Control and extensions would lose the data they share with the app."
        XCTAssertEqual(SharedAppState.appGroup, Self.appGroup, "SharedAppState.appGroup changed. \(breaks)")
        XCTAssertEqual(DeepLinkTrust.appGroupID, Self.appGroup,
                       "DeepLinkTrust.appGroupID changed. The widgets' deep-link trust token would "
                           + "be unreachable, so every widget link would be refused.")
        XCTAssertEqual(SharedTeleprompterInbox.appGroupID, Self.appGroup,
                       "SharedTeleprompterInbox.appGroupID changed. Scripts shared from other apps "
                           + "would be written where the app never looks.")
    }

    /// The watch targets compile none of the phone's shared files, so each keeps its own literal.
    func testWatchAppGroupLiteralsArePinned() throws {
        for path in ["OpenGlassesWatch/WatchConnectivityService.swift",
                     "OpenGlassesWatchWidget/OpenGlassesWatchWidget.swift"] {
            XCTAssertTrue(try sourceText(path).contains("private let appGroupId = \"\(Self.appGroup)\""),
                          "\(path) no longer names the App Group \(Self.appGroup). Whatever the watch "
                              + "stores under the suite would be stranded under the old name.")
        }
    }

    func testEntitlementsCarryTheAppGroup() throws {
        for path in ["OpenGlasses/OpenGlasses.entitlements",
                     "GlassesActivityWidget/GlassesActivityWidget.entitlements",
                     "OpenGlassesShareExtension/OpenGlassesShareExtension.entitlements",
                     "OpenGlassesWatch/OpenGlassesWatch.entitlements",
                     "OpenGlassesWatchWidget/OpenGlassesWatchWidget.entitlements"] {
            let groups = try plist(path)["com.apple.security.application-groups"] as? [String]
            XCTAssertEqual(groups, [Self.appGroup],
                           "\(path) no longer grants \(Self.appGroup). That target would lose the "
                               + "data it shares with the app.")
        }

        // XcodeGen writes those files from the spec, so the spec carries the same three copies.
        let spec = try sourceText("project.base.yml")
        let copies = spec.components(separatedBy: "- \(Self.appGroup)\n").count - 1
        XCTAssertGreaterThanOrEqual(copies, 3,
                                    "project.base.yml no longer grants \(Self.appGroup) to the app, "
                                        + "the widget and the Share Extension. The next project "
                                        + "generation would drop it and they would lose shared data.")

        // The watch app writes its state to the suite and the watch widget's complications read
        // it; without the group each process gets its own container and the complications never
        // change.
        let watchSpec = try sourceText("project.watch.yml")
        let watchCopies = watchSpec.components(separatedBy: "- \(Self.appGroup)\n").count - 1
        XCTAssertGreaterThanOrEqual(watchCopies, 2,
                                    "project.watch.yml no longer grants \(Self.appGroup) to the watch "
                                        + "app and the watch widget. The next project generation would "
                                        + "drop it and the complications would stop following the app.")
    }

    /// A partial rename — one literal changed, the others not — is the failure that is hardest to
    /// see, because each file still compiles. Every App Group literal in any target must agree.
    func testNoSwiftSourceNamesAnotherAppGroup() {
        let files = swiftFiles(under: ["OpenGlasses/Sources", "GlassesActivityWidget",
                                       "OpenGlassesShareExtension", "OpenGlassesWatch",
                                       "OpenGlassesWatchWidget"])
        XCTAssertFalse(files.isEmpty, "no Swift sources found — the repository anchor is wrong")
        let literal = try! NSRegularExpression(pattern: #""(group\.[A-Za-z0-9.\-]+)""#)
        for file in files {
            let range = NSRange(file.text.startIndex..., in: file.text)
            for match in literal.matches(in: file.text, range: range) {
                guard let groupRange = Range(match.range(at: 1), in: file.text) else { continue }
                let group = String(file.text[groupRange])
                XCTAssertEqual(group, Self.appGroup,
                               "\(file.path) names the App Group \(group). Every target must use "
                                   + "\(Self.appGroup), or it loses the data it shares with the others.")
            }
        }
    }

    // MARK: - Bundle identifiers

    func testBundleIdentifiersArePinned() throws {
        let base = try sourceText("project.base.yml")
        XCTAssertTrue(base.contains("bundleIdPrefix: com.\(Self.slug)\n"),
                      "project.base.yml's bundleIdPrefix changed. It becomes a different app to Apple: "
                          + "a new App ID, the Field Assist products stranded, universal links invalid.")
        XCTAssertTrue(base.contains("PRODUCT_BUNDLE_IDENTIFIER: \(Self.bundleIdentifier)\n"),
                      "project.base.yml no longer builds \(Self.bundleIdentifier). It becomes a "
                          + "different app to Apple: a new App ID and every purchase stranded.")

        for path in ["project.base.yml", "project.watch.yml", "project.tests.yml"] {
            for line in try sourceText(path).split(separator: "\n") where line.contains("PRODUCT_BUNDLE_IDENTIFIER:") {
                let value = line.split(separator: ":", maxSplits: 1).last.map {
                    $0.trimmingCharacters(in: .whitespaces)
                } ?? ""
                XCTAssertTrue(value == Self.bundleIdentifier || value.hasPrefix(Self.bundleIdentifier + "."),
                              "\(path) builds \(value), outside \(Self.bundleIdentifier). An extension "
                                  + "outside the app's prefix is a different app to Apple and cannot "
                                  + "be embedded or share the App Group.")
            }
        }
    }

    // MARK: - Skill packs

    func testSkillPackIdsArePinned() throws {
        let data = try Data(contentsOf: Self.repoRoot.appendingPathComponent("skillpacks/index.json"))
        let index = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let ids = ((index["packs"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
        XCTAssertFalse(ids.isEmpty, "skillpacks/index.json lists no packs")
        for id in ids {
            XCTAssertTrue(id.hasPrefix("com.\(Self.slug)."),
                          "Skill pack \(id) is outside com.\(Self.slug).*. A pack's id is its "
                              + "identity: a renamed pack is a different pack to every install and "
                              + "to the catalog.")
        }
    }

    // MARK: - The avenkin.* signed kinds

    private static let breaksBinding = "every issued binding, assignment and receipt stops verifying"

    /// Decodes a `Contracts/fixtures` envelope's base64 payload and returns its `kind`.
    private func fixtureKind(_ relativePath: String) throws -> String? {
        let envelope = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: Self.repoRoot.appendingPathComponent(relativePath))) as? [String: Any])
        var encoded = try XCTUnwrap(envelope["payload"] as? String, "\(relativePath) has no payload")
        encoded = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while encoded.count % 4 != 0 { encoded += "=" }
        let payload = try XCTUnwrap(Data(base64Encoded: encoded), "\(relativePath) payload is not base64")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
        return object["kind"] as? String
    }

    func testSignedKindsInTheContractFixturesArePinned() throws {
        XCTAssertEqual(try fixtureKind("Contracts/fixtures/manual-assignment-v1.json"), "avenkin.manual-assignment",
                       "The signed manual-assignment fixture's kind changed; \(Self.breaksBinding).")
        XCTAssertEqual(try fixtureKind("Contracts/fixtures/managed-job-v1.json"), "avenkin.managed-job",
                       "The signed managed-job fixture's kind changed; \(Self.breaksBinding).")
        XCTAssertTrue(try sourceText("Contracts/README.md").contains("`avenkin.manual-assignment`"),
                      "Contracts/README.md no longer documents avenkin.manual-assignment; the contract "
                          + "and the signed kind have drifted apart.")
    }

    /// Where each kind is checked or minted on the phone side: the Swift office sync, and the
    /// embedded Go office transport.
    private static let signedKindSites: [(path: String, literals: [String])] = [
        ("OpenGlasses/Sources/Services/OfficeSync/OfficeManualAssignment.swift", ["\"avenkin.manual-assignment\""]),
        ("OpenGlasses/Sources/Services/OfficeSync/OfficeManagedJob.swift", ["\"avenkin.managed-job\""]),
        ("OpenGlasses/Sources/Services/OfficeSync/OfficePeerBinding.swift", ["\"avenkin.office-peer-binding\""]),
        ("Transport/mobile-core/officepreview/protocol.go",
         ["\"avenkin.preview-invite\"", "\"avenkin.preview-response\"", "\"avenkin-preview-\""]),
        ("Transport/mobile-core/officepreview/office.go",
         ["\"avenkin.preview-invite\"", "\"avenkin.preview-confirmation\"",
          "\"avenkin.preview-delivery\"", "\"avenkin.preview-receipt\""]),
        ("Transport/mobile-core/officepreview/phone.go",
         ["\"avenkin.preview-response\"", "\"avenkin.preview-confirmation\"",
          "\"avenkin.preview-delivery\"", "\"avenkin.preview-receipt\""]),
        ("Transport/mobile-core/bridge.go", ["\"avenkin-model-hook.1\""]),
        ("Transport/vendor/syncthing/mobile-extension/pin.json", ["\"avenkin-model-hook.1\""]),
    ]

    func testSignedKindsInThePhoneSourcesArePinned() throws {
        for site in Self.signedKindSites {
            let source = try sourceText(site.path)
            for literal in site.literals {
                XCTAssertTrue(source.contains(literal),
                              "\(site.path) no longer carries \(literal). It is a signing domain the "
                                  + "desktop signs over: changing it means \(Self.breaksBinding).")
            }
        }
    }

    /// The desktop app is named "Avenkin Office"; its signed kinds are not. A rename that reaches
    /// them means every issued binding, assignment and receipt stops verifying.
    func testSignedKindsNeverNameTheOfficeProduct() throws {
        let kind = try NSRegularExpression(pattern: #""(avenkin[.\-][^"]*)""#, options: [.caseInsensitive])
        var paths = Self.signedKindSites.map(\.path)
        paths += ["Contracts/README.md", "Contracts/office-preview.md", "Contracts/generate-fixture.go"]
        for path in paths {
            let source = try sourceText(path)
            let range = NSRange(source.startIndex..., in: source)
            for match in kind.matches(in: source, range: range) {
                guard let valueRange = Range(match.range(at: 1), in: source) else { continue }
                let value = source[valueRange].lowercased()
                for forbidden in ["avenkin-office", "avenkin office", "avenkin_office", "avenkinoffice"] {
                    XCTAssertFalse(value.contains(forbidden),
                                   "\(path) carries the signed kind \"\(value)\", which names the office "
                                       + "product. Signed kinds keep their spelling: renaming one "
                                       + "means \(Self.breaksBinding).")
                }
            }
        }
        for fixture in ["Contracts/fixtures/manual-assignment-v1.json", "Contracts/fixtures/managed-job-v1.json"] {
            let value = try fixtureKind(fixture)?.lowercased() ?? ""
            XCTAssertFalse(value.contains("office"),
                           "\(fixture)'s signed kind \"\(value)\" names the office product; "
                               + "\(Self.breaksBinding).")
        }
    }
}
