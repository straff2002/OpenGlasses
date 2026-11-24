import XCTest
import CryptoKit
@testable import OpenGlasses

/// Plan CT 3a — the profile's `aiModel`: checked on the way in, turned into the organisation's
/// `ModelConfig` with a key typed on the phone, kept across renewals, and deleted with the profile.
@MainActor
final class OrgAIModelTests: XCTestCase {

    private var vendorKey: Curve25519.Signing.PrivateKey!
    private var stored: OrgEnrolmentRecord?
    private var models: [ModelConfig] = []
    private var activeId = ""
    private var nextId = 0
    private var currentDate: Date!
    private var forgotAdminCard = 0
    private var departures: [OrgDeparture.Reason] = []
    private var fetchResult: Result<Data, Error> = .failure(URLError(.notConnectedToInternet))
    /// Plan ND decision 9: the company secret this phone holds, if any.
    private var companySecret: Data?
    private let issued = Date(timeIntervalSince1970: 1_790_000_000)
    private let address = URL(string: "https://config.northbridge.example/profile.txt")!
    private let ownConfig = ModelConfig(id: "mine", name: "My Groq", provider: "groq", apiKey: "gsk-mine",
                                        model: "llama", baseURL: LLMProvider.groq.defaultBaseURL)

    override func setUp() {
        super.setUp()
        vendorKey = Curve25519.Signing.PrivateKey()
        stored = nil
        models = [ownConfig]
        activeId = "mine"
        nextId = 0
        currentDate = issued.addingTimeInterval(86_400)
        forgotAdminCard = 0
        departures = []
        fetchResult = .failure(URLError(.notConnectedToInternet))
        companySecret = nil
    }

    private var privateKeyBase64: String { vendorKey.rawRepresentation.base64EncodedString() }
    private var publicKeyBase64: String { vendorKey.publicKey.rawRepresentation.base64EncodedString() }

    private func makeManager() -> OrgProfileManager {
        var seams = OrgProfileManager.Seams()
        seams.verificationKeys = ["k": publicKeyBase64]
        seams.licenceKey = publicKeyBase64
        seams.now = { [unowned self] in self.currentDate }
        seams.resolvableVaultIds = { [] }
        seams.loadRecord = { [unowned self] in self.stored }
        seams.saveRecord = { [unowned self] in self.stored = $0 }
        var values: [SettingKey: ProfileValue] = [:]
        seams.readSetting = { values[$0] }
        seams.writeSetting = { values[$0] = $1 }
        seams.activateLicence = { _ in }
        seams.storedLicenceCode = { nil }
        seams.clearLicence = {}
        seams.installEnvelope = { _, _ in }
        seams.clearEnvelope = {}
        seams.fetch = { [unowned self] _ in try self.fetchResult.get() }
        seams.activeJobId = { nil }
        seams.withholdLicence = { _ in }
        seams.installPack = { _ in .failed("offline") }
        seams.loadModels = { [unowned self] in self.models }
        seams.saveModels = { [unowned self] in self.models = $0 }
        seams.activeModelId = { [unowned self] in self.activeId }
        seams.setActiveModelId = { [unowned self] in self.activeId = $0 }
        seams.newModelConfigId = { [unowned self] in
            self.nextId += 1
            return "org-\(self.nextId)"
        }
        seams.forgetAdminCard = { [unowned self] in self.forgotAdminCard += 1 }
        seams.beginDeparture = { [unowned self] reason, _, _ in self.departures.append(reason) }
        let secrets = CompanySecretStore(read: { [unowned self] in self.companySecret },
                                         write: { [unowned self] in self.companySecret = $0 },
                                         erase: { [unowned self] in self.companySecret = nil })
        seams.sealedModelKey = { OrgCredentialSeal.modelKey(in: $0, secrets: secrets) }
        return OrgProfileManager(seams: seams)
    }

    private func document(_ aiModel: ConfigProfile.AIModel?, sealedKey: String? = nil) throws -> String {
        let secret = Data(repeating: 4, count: OrgCredentialSeal.secretLength)
        let credentials = try sealedKey.map {
            ConfigProfile.SealedCredentials([OrgCredentialSeal.aiModel: try OrgCredentialSeal.seal(
                $0, name: OrgCredentialSeal.aiModel, profileId: "northbridge", companySecret: secret)])
        }
        let profile = ConfigProfile(keyId: "k", profileId: "northbridge", organizationName: "Northbridge Mechanical",
                                    issued: issued, leaseDays: 30, aiModel: aiModel, credentials: credentials)
        return try ProfileVerification.makeDocument(profile, privateKeyBase64: privateKeyBase64)
    }

    private func enrol(_ manager: OrgProfileManager, _ aiModel: ConfigProfile.AIModel?, sealedKey: String? = nil) throws {
        let review = try manager.review(document: try document(aiModel, sealedKey: sealedKey), source: .link, sourceURL: address).get()
        try manager.apply(review).get()
    }

    private let claude = ConfigProfile.AIModel(provider: "anthropic", model: "claude-sonnet-4-5")

    // MARK: - Checking what the profile names

    func testAKnownProviderAndModelResolve() throws {
        let model = try OrgAIModel.resolve(claude).get()
        XCTAssertEqual(model.provider, .anthropic)
        XCTAssertEqual(model.access, .key)
        XCTAssertEqual(model.summary, "\(LLMProvider.anthropic.displayName) · claude-sonnet-4-5")
        XCTAssertNil(model.host)
    }

    func testEveryWayItCanBeWrongIsANamedDrop() {
        let cases: [ConfigProfile.AIModel] = [
            .init(provider: "skynet", model: "t-800"),
            .init(provider: "anthropic", model: nil),
            .init(provider: nil, model: "gpt"),
            .init(provider: "anthropic", model: "claude", baseURL: "https://proxy.example"),
            .init(provider: "openrouter", model: "x", baseURL: "http://proxy.example"),
            .init(provider: "custom", model: "x", baseURL: "https://user:pass@proxy.example"),
            .init(provider: "custom", model: "x"),
        ]
        for spec in cases {
            guard case .failure = OrgAIModel.resolve(spec) else { return XCTFail("\(spec) should not resolve") }
        }
        let proxied = try? OrgAIModel.resolve(.init(provider: "openrouter", model: "x",
                                                    baseURL: "https://AI.Northbridge.example/v1")).get()
        XCTAssertEqual(proxied?.host, "ai.northbridge.example", "the review names where prompts go")
    }

    func testAMalformedEntryIsDroppedWithoutRefusingTheProfile() throws {
        let profile = ConfigProfile(keyId: "k", profileId: "p", organizationName: "Org", issued: issued, leaseDays: 30)
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: ProfileVerification.encoder.encode(profile)) as? [String: Any])
        json["aiModel"] = "claude, please"
        let decoded = try ProfileVerification.decoder.decode(
            ConfigProfile.self, from: JSONSerialization.data(withJSONObject: json))
        let result = ProfileApplier.apply(profile: decoded, resolvableVaultIds: [])
        XCTAssertNil(result.aiModel)
        XCTAssertEqual(result.drops.map(\.key), ["aiModel"])
    }

    /// `Scripts/make-org-profile.swift` and preset-built profiles refuse a provider the app does not know,
    /// from the shared contract's list (compiled into this test bundle).
    func testTheProfileScriptKnowsEveryProvider() {
        XCTAssertEqual(ProfileContract.knownProviders, Set(LLMProvider.allCases.map(\.rawValue)))
    }

    func testTheKeyFormatCheckIsOnboardings() throws {
        let anthropic = try OrgAIModel.resolve(claude).get()
        XCTAssertEqual(anthropic.keyProblem("sk-proj-123"), "Anthropic keys start with sk-ant-")
        XCTAssertNotNil(anthropic.keyProblem("  "))
        XCTAssertNil(anthropic.keyProblem("sk-ant-abc"))
    }

    // MARK: - Enrolment

    func testAKeyedProviderWaitsForItsKeyAndTheReviewSaysSo() throws {
        let manager = makeManager()
        let review = try manager.review(document: try document(claude), source: .link).get()
        XCTAssertEqual(review.aiModelLines, ["AI model: \(LLMProvider.anthropic.displayName) · claude-sonnet-4-5"])
        try manager.apply(review).get()
        XCTAssertTrue(manager.needsModelSetup)
        XCTAssertEqual(models, [ownConfig], "nothing is saved without a key")
    }

    func testTheKeyEnteredBecomesTheOrganisationsActiveModel() throws {
        let manager = makeManager()
        try enrol(manager, claude)
        XCTAssertFalse(manager.completeModelSetup(apiKey: "sk-openai"), "the format check runs first")
        XCTAssertTrue(manager.completeModelSetup(apiKey: " sk-ant-abc "))

        let config = try XCTUnwrap(models.first { $0.id == "org-1" })
        XCTAssertEqual(config.provider, "anthropic")
        XCTAssertEqual(config.model, "claude-sonnet-4-5")
        XCTAssertEqual(config.apiKey, "sk-ant-abc")
        XCTAssertEqual(config.baseURL, LLMProvider.anthropic.defaultBaseURL)
        XCTAssertEqual(activeId, "org-1")
        XCTAssertFalse(manager.needsModelSetup)
        XCTAssertEqual(stored?.modelConfigId, "org-1")
        XCTAssertFalse((stored?.document ?? "").contains("sk-ant-abc"), "the key never enters the profile")
    }

    func testRevocationRemovesTheOrganisationsModelAndCannotReinstallItsKey() async throws {
        let manager = makeManager()
        try enrol(manager, claude)
        XCTAssertTrue(manager.completeModelSetup(apiKey: "sk-ant-abc"))
        let revoked = ProfileRevocation(keyId: "k", profileId: "northbridge", issued: currentDate)
        fetchResult = .success(Data(try ProfileVerification.makeDocument(revoked, privateKeyBase64: privateKeyBase64).utf8))
        await manager.renewIfDue(force: true)
        XCTAssertEqual(models, [ownConfig])
        XCTAssertEqual(activeId, "mine")
        XCTAssertFalse(manager.completeModelSetup(apiKey: "sk-ant-abc"))
    }

    func testAnExpiredLeaseRemovesTheOrganisationsModelWithoutRemovingThePersonalOne() throws {
        let manager = makeManager()
        try enrol(manager, claude)
        XCTAssertTrue(manager.completeModelSetup(apiKey: "sk-ant-abc"))
        currentDate = issued.addingTimeInterval(400 * 86400)
        manager.evaluateLease()
        XCTAssertTrue(manager.contentLocked)
        XCTAssertEqual(models, [ownConfig])
        XCTAssertEqual(activeId, "mine")
        XCTAssertFalse(manager.completeModelSetup(apiKey: "sk-ant-abc"))
    }

    func testAnOnDeviceModelIsReadyAtOnce() throws {
        let manager = makeManager()
        try enrol(manager, .init(provider: "local", model: "qwen3-4b", name: "Workshop model"))
        XCTAssertFalse(manager.needsModelSetup)
        XCTAssertEqual(models.last?.name, "Workshop model")
        XCTAssertEqual(activeId, "org-1")
    }

    /// Plan CT 3b: an administrator phone's kept card goes with the enrolment, so re-enrolling a
    /// phone handed on to a technician does not quietly make it an administrator phone again.
    func testRemovalAndRevocationForgetTheAdminCard() async throws {
        let manager = makeManager()
        try enrol(manager, nil)
        try manager.remove().get()
        XCTAssertEqual(forgotAdminCard, 1)

        try enrol(manager, nil)
        let revocation = ProfileRevocation(keyId: "k", profileId: "northbridge", issued: issued)
        fetchResult = .success(Data(try ProfileVerification.makeDocument(revocation, privateKeyBase64: privateKeyBase64).utf8))
        await manager.renewIfDue(force: true)
        XCTAssertEqual(stored?.revoked, true)
        XCTAssertEqual(forgotAdminCard, 2)
        XCTAssertEqual(departures, [.removed, .revoked],
                       "Plan CT PR 4: removal is treated exactly as revocation — both leave the firm")
    }

    func testRemovalDeletesTheOrganisationsConfigAndLeavesTheirOwn() throws {
        let manager = makeManager()
        try enrol(manager, claude)
        manager.completeModelSetup(apiKey: "sk-ant-abc")
        try manager.remove().get()
        XCTAssertEqual(models, [ownConfig])
        XCTAssertEqual(activeId, "mine")
    }

    // MARK: - Renewal

    func testANewModelUnderTheSameProviderKeepsTheKey() async throws {
        let manager = makeManager()
        try enrol(manager, claude)
        manager.completeModelSetup(apiKey: "sk-ant-abc")

        fetchResult = .success(Data(try document(.init(provider: "anthropic", model: "claude-opus-5")).utf8))
        await manager.renewIfDue(force: true)
        let config = try XCTUnwrap(models.first { $0.id == "org-1" })
        XCTAssertEqual(config.model, "claude-opus-5")
        XCTAssertEqual(config.apiKey, "sk-ant-abc")
        XCTAssertFalse(manager.needsModelSetup)
    }

    func testANewProviderWaitsForItsKeyAndKeepsTheOldModelMeanwhile() async throws {
        let manager = makeManager()
        try enrol(manager, claude)
        manager.completeModelSetup(apiKey: "sk-ant-abc")

        fetchResult = .success(Data(try document(.init(provider: "openai", model: "gpt-5")).utf8))
        await manager.renewIfDue(force: true)
        XCTAssertTrue(manager.needsModelSetup)
        XCTAssertEqual(activeId, "org-1", "never dropped into a provider with no key")
        XCTAssertNotNil(models.first { $0.id == "org-1" })

        XCTAssertTrue(manager.completeModelSetup(apiKey: "sk-live"))
        XCTAssertNil(models.first { $0.id == "org-1" }, "the organisation's old config is replaced")
        XCTAssertEqual(models.first { $0.id == "org-2" }?.provider, "openai")
        XCTAssertEqual(activeId, "org-2")
    }

    // MARK: - The sheet's key step

    func testConfirmingLeadsToTheKeyPageAndLaterLeavesTheAdministratorState() async throws {
        let manager = makeManager()
        fetchResult = .success(Data(try document(claude).utf8))
        let service = OrgEnrolmentService(manager: manager, fetch: { [unowned self] _ in try self.fetchResult.get() },
                                          isPastOnboarding: { true })
        service.open(URL(string: "openglasses://enrol?url=\(address.absoluteString)")!)
        await service.approveFetch()
        service.confirm()
        guard case .modelKey(let model, let organization) = service.stage else {
            return XCTFail("\(service.stage)")
        }
        XCTAssertEqual(model.provider, .anthropic)
        XCTAssertEqual(organization, "Northbridge Mechanical")

        XCTAssertEqual(service.submitModelKey("nope"), "Anthropic keys start with sk-ant-")
        service.deferModelKey()
        XCTAssertEqual(service.stage, .applied("Northbridge Mechanical"))
        XCTAssertTrue(manager.needsModelSetup)
    }

    func testAKeyOnTheKeyPageFinishesSetup() async throws {
        let manager = makeManager()
        fetchResult = .success(Data(try document(claude).utf8))
        var refreshed = 0
        let service = OrgEnrolmentService(manager: manager, fetch: { [unowned self] _ in try self.fetchResult.get() },
                                          isPastOnboarding: { true }, modelDidChange: { refreshed += 1 })
        service.open(URL(string: "openglasses://enrol?url=\(address.absoluteString)")!)
        await service.approveFetch()
        service.confirm()
        XCTAssertNil(service.submitModelKey("sk-ant-abc"))
        XCTAssertEqual(service.stage, .applied("Northbridge Mechanical"))
        XCTAssertEqual(activeId, "org-1")
        XCTAssertEqual(refreshed, 1)
    }
    // MARK: - The company's sealed key (Plan ND decision 9)

    private let theCompanysSecret = Data(repeating: 4, count: OrgCredentialSeal.secretLength)

    func testASealedKeyMakesTheModelReadyWithNothingTyped() throws {
        companySecret = theCompanysSecret
        let manager = makeManager()
        let review = try manager.review(document: try document(claude, sealedKey: "sk-ant-company-key"), source: .link).get()
        XCTAssertTrue(review.suppliesModelKey, "the review says the company supplies the key")
        try manager.apply(review).get()
        XCTAssertFalse(manager.needsModelSetup)
        let config = try XCTUnwrap(models.first { $0.id == "org-1" })
        XCTAssertEqual(config.apiKey, "sk-ant-company-key")
        XCTAssertEqual(activeId, "org-1")
    }

    func testWithoutTheCompanySecretTheKeyWaitsUntilItIsKept() throws {
        let manager = makeManager()
        try enrol(manager, claude, sealedKey: "sk-ant-company-key")
        XCTAssertTrue(manager.needsModelSetup, "a phone set up from a link cannot open the box")

        companySecret = theCompanysSecret          // the activation key's secret is kept after the apply
        manager.reconcileOrganizationModel()
        XCTAssertFalse(manager.needsModelSetup)
        XCTAssertEqual(models.first { $0.id == "org-1" }?.apiKey, "sk-ant-company-key")
    }

    func testAReplacedSealedKeyReplacesTheOneInUse() async throws {
        companySecret = theCompanysSecret
        let manager = makeManager()
        try enrol(manager, claude, sealedKey: "sk-ant-company-key")
        fetchResult = .success(Data(try document(claude, sealedKey: "sk-ant-rotated-key").utf8))
        await manager.renewIfDue(force: true)
        XCTAssertEqual(models.first { $0.id == "org-1" }?.apiKey, "sk-ant-rotated-key")
    }

    func testASealedKeyForTheWrongProviderIsNotUsed() throws {
        companySecret = theCompanysSecret
        let manager = makeManager()
        try enrol(manager, claude, sealedKey: "sk-openai-not-anthropic")
        XCTAssertTrue(manager.needsModelSetup, "the same format check as a typed key")
        XCTAssertEqual(models, [ownConfig])
    }
}
