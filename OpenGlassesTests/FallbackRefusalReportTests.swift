import XCTest
@testable import OpenGlasses

/// The support report from build 737: "What's the weather in Rome" on a rate-limited Gemini fell
/// over to Apple Intelligence on a phone that cannot run it, then to a self-hosted model the
/// wearer had answered Not now for. The turn said it was switching, ended on "open Avenkin and
/// allow it", and the report could not say which refusal it was, named the model `unnamed` and
/// showed a request as sent that never left the phone.
@MainActor
final class FallbackRefusalReportTests: XCTestCase {
    private var directory: URL!
    private var store: ConsentStore!
    private var consent: CloudProcessingConsent!
    private var defaults: UserDefaults!
    private let suite = "FallbackRefusalReportTests"
    private let lan = URL(string: "http://studio-mac.local:11434/v1/chat/completions")!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = ConsentStore(directory: directory)
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        consent = CloudProcessingConsent(store: store, defaults: defaults, foreground: { true })
        consent.presenterAvailable = true
    }

    override func tearDown() {
        consent.cancelPending()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func waitForPrompt() async {
        for _ in 0..<200 {
            if consent.pending != nil { return }
            await Task.yield()
        }
        XCTFail("the request should have asked")
    }

    private func declineOnce() async {
        let request = Task { try await consent.authorize(url: lan, scope: .conversation) }
        await waitForPrompt()
        consent.respond(allow: false)
        do { _ = try await request.value; XCTFail("a Not now must refuse") } catch {
            XCTAssertEqual(error as? CloudProcessingRefusal, .declined)
        }
    }

    // MARK: The refusal says which it was

    func testNotNowIsRememberedAsDeclinedNotAsNobodyThere() async {
        await declineOnce()
        do { _ = try await consent.authorize(url: lan, scope: .conversation); XCTFail("still declined") } catch {
            XCTAssertEqual(error as? CloudProcessingRefusal, .declined)
        }
        XCTAssertNil(consent.pending, "a Not now is not asked again in the same session")
    }

    func testNobodyThereIsStillPermissionRequired() async {
        let locked = CloudProcessingConsent(store: store, defaults: defaults, foreground: { false })
        locked.presenterAvailable = true
        do { _ = try await locked.authorize(url: lan, scope: .conversation); XCTFail("nobody can answer") } catch {
            XCTAssertEqual(error as? CloudProcessingRefusal, .permissionRequired)
        }
    }

    func testTheReportKeepsTheRefusalCase() {
        XCTAssertEqual(SafeErrorSummary(CloudProcessingRefusal.declined).description,
                       "refused(cloudSharingConsent.declined)")
        XCTAssertEqual(SafeErrorSummary(CloudProcessingRefusal.permissionRequired).description,
                       "refused(cloudSharingConsent.permissionRequired)")
        XCTAssertEqual(SafeErrorSummary(CloudProcessingRefusal.withdrawn).description,
                       "refused(cloudSharingConsent.withdrawn)")
    }

    func testADeclinedServiceNamesWhereToAllowIt() {
        let line = ModelSwitchNarrator.failureLine(CloudProcessingRefusal.declined, narrate: false)
        XCTAssertTrue(line.contains("Cloud AI Sharing"), line)
        XCTAssertFalse(line.contains("ask me again"), "asking again is refused the same way: \(line)")
        XCTAssertEqual(ModelFallbackChain.classify(CloudProcessingRefusal.declined), .terminalForTurn)
    }

    // MARK: Would a hop be refused without asking

    func testRefusesWithoutAskingReadsEveryEarlyExitOfAuthorize() async throws {
        XCTAssertFalse(consent.refusesWithoutAsking(url: lan, scope: .conversation),
                       "unanswered, with someone there: the request may still ask")
        let locked = CloudProcessingConsent(store: store, defaults: defaults, foreground: { false })
        locked.presenterAvailable = true
        XCTAssertTrue(locked.refusesWithoutAsking(url: lan, scope: .conversation), "nobody there")
        let unpresented = CloudProcessingConsent(store: store, defaults: defaults, foreground: { true })
        XCTAssertTrue(unpresented.refusesWithoutAsking(url: lan, scope: .conversation), "nothing can show it")

        await declineOnce()
        XCTAssertTrue(consent.refusesWithoutAsking(url: lan, scope: .conversation), "answered Not now")

        store.recordWearerApproval(purpose: .aiProcessing, dataClass: CloudProcessingScope.conversation.dataClass,
                                   recipient: "http://studio-mac.local:11434", version: CloudProcessingTerms.version)
        XCTAssertFalse(consent.refusesWithoutAsking(url: lan, scope: .conversation), "approved")
        XCTAssertFalse(locked.refusesWithoutAsking(url: lan, scope: .conversation), "approved, even with nobody there")

        consent.withdraw(try XCTUnwrap(consent.approvals.first))
        XCTAssertTrue(consent.refusesWithoutAsking(url: lan, scope: .conversation), "withdrawn")
    }

    // MARK: The chain leaves out what cannot take the turn

    private func candidate(_ id: String) -> ModelFallbackChain.Candidate {
        .init(id: id, isLocalMLX: false, supportsVision: false, contextTokens: ModelFallbackChain.cloudContextTokens)
    }

    func testUnusableFallbacksAreDroppedButTheLeadStays() {
        let chain = ["gemini", "apple", "ollama", "claude"].map(candidate)
        let reasons: [String: ModelFallbackChain.Unusable] = [
            "gemini": .sharingNotAllowed, "apple": .unavailableOnDevice, "ollama": .sharingNotAllowed,
        ]
        let result = ModelFallbackChain.droppingUnusableFallbacks(chain, lead: "gemini") { reasons[$0.id] }
        XCTAssertEqual(result.kept.map(\.id), ["gemini", "claude"],
                       "the lead says its own reason; the rest are not announced and then refused")
        XCTAssertEqual(result.skipped.map(\.0.id), ["apple", "ollama"])
        XCTAssertEqual(result.skipped.map(\.1), [.unavailableOnDevice, .sharingNotAllowed])
    }

    func testAChainWithNothingUnusableIsUnchanged() {
        let chain = ["a", "b", "c"].map(candidate)
        let result = ModelFallbackChain.droppingUnusableFallbacks(chain, lead: "a") { _ in nil }
        XCTAssertEqual(result.kept, chain)
        XCTAssertTrue(result.skipped.isEmpty)
    }

    // MARK: Apple Intelligence on a phone that cannot run it

    func testAnUnavailableOnDeviceModelIsNotAMissingKey() {
        let error = LLMError.onDeviceUnavailable(reason: "deviceNotEligible", message: "Device does not support Apple Intelligence")
        XCTAssertEqual(SafeErrorSummary(error).description, "unavailableOnDevice(deviceNotEligible)")
        XCTAssertEqual(ModelFallbackChain.classify(error), .terminalForCandidate, "a cloud model may still answer")
        XCTAssertNil(CredentialGap.kind(of: error), "no key to fix")
        XCTAssertEqual(error.errorDescription, "Device does not support Apple Intelligence")
    }

    // MARK: Model names a provider uses

    func testModelNamesKeepTheirTagsAndPaths() {
        XCTAssertEqual(PrivacyToken(modelName: "qwen3-vl:4b").description, "qwen3-vl:4b")
        XCTAssertEqual(PrivacyToken(modelName: "meta-llama/llama-3.3-70b").description, "meta-llama/llama-3.3-70b")
        XCTAssertEqual(PrivacyToken(modelName: "gemini-3.1-flash-lite").description, "gemini-3.1-flash-lite")
        XCTAssertEqual(PrivacyToken("qwen3-vl:4b").description, PrivacyToken.placeholder,
                       "the plain filter is unchanged")
    }

    func testModelNamesStillDropAddressesAndSignIns() {
        for raw in ["http://studio-mac.local:11434", "user@host", "/Users/me/model.gguf", "admin:hunter2:x",
                    "qwen 4b", "", String(repeating: "a", count: 49)] {
            XCTAssertEqual(PrivacyToken(modelName: raw).description, PrivacyToken.placeholder, raw)
        }
    }

    // MARK: Tools offered to a custom endpoint

    func testACustomEndpointOfUnknownWindowGetsToolsOnDemand() {
        let available = (0..<107).map { "tool\($0)" }
        let custom = ToolExposurePolicy.decide(mode: .automatic, available: available, fullSetBytes: 93_836,
                                               contextWindow: nil, core: ["tool0", "tool1"], remembered: [],
                                               onDemandWhenWindowUnknown: true)
        XCTAssertEqual(custom.exposure, .core)
        XCTAssertEqual(custom.reason, .unknownWindow)
        XCTAssertEqual(custom.declared, ["tool0", "tool1"])

        let other = ToolExposurePolicy.decide(mode: .automatic, available: available, fullSetBytes: 93_836,
                                              contextWindow: nil, core: ["tool0"], remembered: [])
        XCTAssertEqual(other.exposure, .full, "a provider without the flag keeps today's default")
        XCTAssertEqual(other.reason, .default)

        let pinned = ToolExposurePolicy.decide(mode: .never, available: available, fullSetBytes: 93_836,
                                               contextWindow: nil, core: ["tool0"], remembered: [],
                                               onDemandWhenWindowUnknown: true)
        XCTAssertEqual(pinned.exposure, .full, "the wearer's or organisation's setting still wins")
    }
}
