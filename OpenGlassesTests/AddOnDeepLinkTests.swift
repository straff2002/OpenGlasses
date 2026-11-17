import XCTest
@testable import OpenGlasses

/// Plan GF P2 — how an add-on reaches the phone: the `install-addon` link (asked about before
/// anything is fetched, HTTPS only), files, and the sheet flow that installs only on its button.
@MainActor
final class AddOnDeepLinkTests: XCTestCase {

    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AddOnDeepLinkTests_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private var currency: Data { Data(RecipeAddOnFixtures.currency.utf8) }

    // MARK: - The link

    func testAnHTTPSLinkParses() throws {
        let link = try XCTUnwrap(URL(string: "openglasses://install-addon?url=https%3A%2F%2Fexample.org%2Fcurrency.addon"))
        XCTAssertEqual(try AddOnIngest.parse(link).get().fileURL.absoluteString, "https://example.org/currency.addon")
        let avenkin = try XCTUnwrap(URL(string: "avenkin://install-addon?url=https://example.org/a.json"))
        XCTAssertNoThrow(try AddOnIngest.parse(avenkin).get())
    }

    func testAnythingButPlainHTTPSIsRefused() throws {
        for raw in ["http://example.org/a.addon", "http://192.168.1.4/a.addon", "file:///tmp/a.addon",
                    "https://user:pw@example.org/a.addon", "https://example.org/a.addon#frag",
                    "https://example.org:8443/a.addon", "ftp://example.org/a.addon"] {
            var components = URLComponents(string: "openglasses://install-addon")!
            components.queryItems = [URLQueryItem(name: "url", value: raw)]
            let link = try XCTUnwrap(components.url)
            XCTAssertEqual(AddOnIngest.parse(link), .failure(.insecureSource), raw)
        }
    }

    func testOtherLinksAndMissingURLs() throws {
        XCTAssertEqual(AddOnIngest.parse(URL(string: "openglasses://skillpack?url=https://example.org/a.zip")!),
                       .failure(.notAnAddOnLink))
        XCTAssertEqual(AddOnIngest.parse(URL(string: "https://install-addon?url=https://example.org/a")!),
                       .failure(.notAnAddOnLink))
        XCTAssertEqual(AddOnIngest.parse(URL(string: "openglasses://install-addon")!), .failure(.missingURL))
        XCTAssertEqual(AddOnIngest.parse(URL(string: "openglasses://install-addon?url=")!), .failure(.missingURL))
    }

    func testTheLinkIsOutsideTheTrustedCallerGateBecauseItNeverActs() {
        XCTAssertFalse(DeepLinkTrust.requiresTrustedCaller(host: AddOnIngest.linkHost, action: ""))
        XCTAssertEqual(privacyRoute(for: URL(string: "openglasses://install-addon?url=https://a.b/c")!), .addOn)
    }

    // MARK: - Files

    func testFilesAreRecognisedByExtensionOrByTheirFormatTag() throws {
        XCTAssertTrue(AddOnIngest.isAddOnFile(URL(fileURLWithPath: "/tmp/Currency.addon")))
        XCTAssertTrue(AddOnIngest.isAddOnFile(URL(fileURLWithPath: "/tmp/Currency.ADDON")))
        XCTAssertFalse(AddOnIngest.isAddOnFile(URL(fileURLWithPath: "/tmp/Currency.json")))
        XCTAssertFalse(AddOnIngest.isAddOnFile(URL(string: "https://example.org/a.addon")!))

        XCTAssertTrue(AddOnIngest.looksLikeAddOn(currency))
        let key = AddOnSigningFixtures.KeyPair()
        XCTAssertTrue(AddOnIngest.looksLikeAddOn(try AddOnSigningFixtures.vendorEnvelope(currency, key: key)))
        XCTAssertFalse(AddOnIngest.looksLikeAddOn(Data(#"{"format":"team-learning/1"}"#.utf8)),
                       "other JSON the app opens is left for its own reader")
        XCTAssertFalse(AddOnIngest.looksLikeAddOn(Data("not json".utf8)))
    }

    func testAFileIsReadAndAnOversizedOneIsRefused() throws {
        let small = root.appendingPathComponent("a.addon")
        try currency.write(to: small)
        XCTAssertEqual(AddOnIngest.readFile(small), currency)
        let big = root.appendingPathComponent("b.addon")
        try Data(count: AddOnSignature.maxEnvelopeBytes + 1).write(to: big)
        XCTAssertNil(AddOnIngest.readFile(big))
    }

    // MARK: - The sheet flow

    private final class FetchLog: @unchecked Sendable {
        var urls: [URL] = []
    }

    private func makeService(store: AddOnStore, log: FetchLog = FetchLog(), body: Data? = nil,
                             now: @escaping () -> Date = Date.init,
                             context: AddOnAdmission.Context = .init(),
                             changed: @escaping () -> Void = {}) -> AddOnInstallService {
        let payload = body ?? currency
        return AddOnInstallService(
            store: store, context: { context },
            fetch: { url in log.urls.append(url); return payload },
            networkDecision: .allowHardenedFetch, now: now, onChange: changed)
    }

    private func makeStore() -> AddOnStore {
        AddOnStore(directory: root.appendingPathComponent("addons"), backupDirectory: root)
    }

    private let link = AddOnLinkRequest(fileURL: URL(string: "https://example.org/currency.addon")!)

    func testALinkAsksBeforeFetchingAndInstallsOnlyOnTheSheetsButton() async throws {
        let log = FetchLog()
        var changes = 0
        let store = makeStore()
        let service = makeService(store: store, log: log, changed: { changes += 1 })

        service.open(link)
        guard case .confirmFetch(let offer) = service.prompt else { return XCTFail("the link must ask first") }
        XCTAssertEqual(offer.host, "example.org")
        XCTAssertTrue(log.urls.isEmpty, "nothing is fetched before the wearer says yes")

        await service.approveFetch(offer)
        XCTAssertEqual(log.urls, [link.fileURL])
        guard case .review(let review) = service.prompt else { return XCTFail("a valid file shows the sheet") }
        XCTAssertEqual(review.kind, .install)
        XCTAssertEqual(review.origin, .installed(via: .link))
        XCTAssertTrue(store.installed.isEmpty, "nothing installs before the button")

        service.accept(review)
        XCTAssertEqual(store.installed.map(\.id), ["dev.frankfurter.currency"])
        XCTAssertEqual(changes, 1, "the registry is rebuilt")
        guard case .done = service.prompt else { return XCTFail("the wearer is told") }
    }

    func testAFetchApprovalIsSingleUseAndExpires() async throws {
        var clock = Date(timeIntervalSince1970: 1_000)
        let log = FetchLog()
        let service = makeService(store: makeStore(), log: log, now: { clock })
        service.open(link)
        guard case .confirmFetch(let offer) = service.prompt else { return XCTFail() }
        clock = clock.addingTimeInterval(AddOnInstallService.offerLifetime + 1)
        await service.approveFetch(offer)
        guard case .refused = service.prompt else { return XCTFail("an expired yes fetches nothing") }
        XCTAssertTrue(log.urls.isEmpty)
        await service.approveFetch(offer)
        XCTAssertTrue(log.urls.isEmpty, "and it can't be spent twice")
    }

    func testDismissingTheSheetInstallsNothing() async throws {
        let store = makeStore()
        let service = makeService(store: store)
        service.receive(currency, origin: .installed(via: .file))
        guard case .review(let review) = service.prompt else { return XCTFail() }
        service.dismiss()
        service.accept(review)
        XCTAssertTrue(store.installed.isEmpty, "a review that is no longer showing can't be accepted")
    }

    func testAnInvalidFileIsRefusedInPlainWords() {
        let service = makeService(store: makeStore())
        service.receive(Data(#"{"format":"avenkin.addon/1","id":"x"}"#.utf8), origin: .installed(via: .file))
        guard case .refused(let lines) = service.prompt else { return XCTFail() }
        XCTAssertEqual(lines.first, "This isn't an add-on file.")
    }

    func testANewerVersionShowsTheUpdateSheetAndAnOlderOneIsRefused() throws {
        let store = makeStore()
        let service = makeService(store: store)
        service.receive(AddOnSigningFixtures.file(version: "1.0.0"), origin: .installed(via: .file))
        guard case .review(let first) = service.prompt else { return XCTFail() }
        service.accept(first)

        let grown = RecipeAddOnFixtures.file(skills: [RecipeAddOnFixtures.skill(steps: [["say": "Done."]])],
                                             permissions: ["network": ["api.example.org", "new.example.net"]],
                                             overrides: ["version": "1.1.0"])
        service.receive(grown, origin: .installed(via: .link))
        guard case .review(let update) = service.prompt, case .update(let diff) = update.kind else {
            return XCTFail("a newer version is an update")
        }
        XCTAssertEqual(diff?.domainsAdded, ["new.example.net"])
        XCTAssertEqual(store.record(id: "org.example.test")?.version, "1.0.0", "nothing applied before the button")
        service.accept(update)
        XCTAssertEqual(store.record(id: "org.example.test")?.version, "1.1.0")

        service.receive(AddOnSigningFixtures.file(version: "1.0.5"), origin: .installed(via: .file))
        guard case .refused(let lines) = service.prompt else { return XCTFail("an older version is refused") }
        XCTAssertTrue(lines.first?.contains("older version") == true)
        service.receive(AddOnSigningFixtures.file(version: "1.1.0"), origin: .installed(via: .file))
        guard case .refused(let same) = service.prompt else { return XCTFail("the same version is refused") }
        XCTAssertTrue(same.first?.contains("already installed") == true)
    }

    func testAnOrganisationCeilingRefusesACommunityAddOn() {
        let service = makeService(store: makeStore(),
                                  context: .init(policy: AddOnPolicy(ceiling: .signedOnly)))
        service.receive(currency, origin: .installed(via: .file))
        XCTAssertEqual(service.prompt, .refused(["Your organisation allows only signed add-ons on this phone."]))
    }

    func testAnAddOnNeedingANewerAppIsRefused() {
        let service = makeService(store: makeStore(), context: .init(currentBuild: 700))
        let needsNewer = RecipeAddOnFixtures.file(skills: [RecipeAddOnFixtures.skill(steps: [["say": "Hi."]])],
                                                  overrides: ["minAppBuild": 9_999])
        service.receive(needsNewer, origin: .installed(via: .file))
        guard case .refused(let lines) = service.prompt else { return XCTFail() }
        XCTAssertTrue(lines.first?.contains("newer version of the app") == true)
    }

    func testAnUnavailableNetworkFeatureFetchesNothing() {
        let log = FetchLog()
        let service = AddOnInstallService(store: makeStore(), context: { .init() },
                                          fetch: { url in log.urls.append(url); return Data() },
                                          networkDecision: .refuseUntilHardenedClient)
        service.open(link)
        XCTAssertEqual(service.prompt, .refused([UntrustedNetworkFeaturePolicy.unavailableMessage]))
    }

    func testTheAssistantsOwnAddOnArrivesWithItsProvenance() throws {
        let store = makeStore()
        let service = makeService(store: store)
        let provenance = SelfBuiltAddOnProvenance(sessionID: "s-1", goal: "tides", builtAt: Date(timeIntervalSince1970: 5))
        service.receive(AddOnSigningFixtures.file(id: "local.assistant.tides"), origin: .selfBuilt(provenance))
        guard case .review(let review) = service.prompt else { return XCTFail() }
        XCTAssertEqual(AddOnSheetModel(review: review).badges, [.builtByAssistant])
        service.accept(review)
        XCTAssertEqual(store.record(id: "local.assistant.tides")?.selfBuiltProvenance, provenance)
    }

    // MARK: - Source edits

    func testAnEditIsValidatedAsACommunityFileWithTheSameID() throws {
        let installed = RecipeAddOnFixtures.currencyManifest
        let bytes = currency
        XCTAssertEqual(AddOnSourceEdit.review(RecipeAddOnFixtures.currency, installedBytes: bytes,
                                              installed: installed, context: .init()), .unchanged)

        let renamed = RecipeAddOnFixtures.currency.replacingOccurrences(of: "dev.frankfurter.currency", with: "dev.other.currency")
        guard case .invalid(let idLines) = AddOnSourceEdit.review(renamed, installedBytes: bytes, installed: installed,
                                                                   context: .init()) else { return XCTFail() }
        XCTAssertTrue(idLines.first?.contains("id can't change") == true)

        guard case .invalid = AddOnSourceEdit.review("{", installedBytes: bytes, installed: installed,
                                                     context: .init()) else { return XCTFail() }

        let reworded = RecipeAddOnFixtures.currency.replacingOccurrences(of: "\"Currency\"", with: "\"Money\"")
        guard case .saveable(let candidate, _, let needsApproval) = AddOnSourceEdit.review(
            reworded, installedBytes: bytes, installed: installed, context: .init()) else { return XCTFail() }
        XCTAssertFalse(needsApproval, "nothing new it can do: saved without the sheet")
        XCTAssertEqual(candidate.trust, .community)

        let widened = RecipeAddOnFixtures.currency.replacingOccurrences(
            of: #""network": ["api.frankfurter.dev"]"#, with: #""network": ["api.frankfurter.dev", "evil.example.net"]"#)
        guard case .saveable(_, let diff, let grows) = AddOnSourceEdit.review(
            widened, installedBytes: bytes, installed: installed, context: .init()) else { return XCTFail() }
        XCTAssertTrue(grows, "a new domain sends it back through the sheet")
        XCTAssertEqual(diff.domainsAdded, ["evil.example.net"])
    }

    func testAnEditThatGrewIsSavedOnlyThroughTheSheet() throws {
        let store = makeStore()
        let service = makeService(store: store)
        service.receive(currency, origin: .installed(via: .file))
        guard case .review(let first) = service.prompt else { return XCTFail() }
        service.accept(first)

        let widened = RecipeAddOnFixtures.currency.replacingOccurrences(
            of: #""network": ["api.frankfurter.dev"]"#, with: #""network": ["api.frankfurter.dev", "new.example.net"]"#)
        guard case .saveable(let candidate, let diff, true) = AddOnSourceEdit.review(
            widened, installedBytes: currency, installed: RecipeAddOnFixtures.currencyManifest,
            context: .init()) else { return XCTFail() }
        service.reviewEdit(candidate, diff: diff)
        guard case .review(let edit) = service.prompt else { return XCTFail() }
        XCTAssertEqual(AddOnSheetModel(review: edit).confirmTitle, "Save")
        XCTAssertEqual(store.fileBytes(id: "dev.frankfurter.currency"), currency)
        service.accept(edit)
        XCTAssertEqual(store.fileBytes(id: "dev.frankfurter.currency"), Data(widened.utf8))
        XCTAssertEqual(store.record(id: "dev.frankfurter.currency")?.editedOnPhone, true)
    }
}
