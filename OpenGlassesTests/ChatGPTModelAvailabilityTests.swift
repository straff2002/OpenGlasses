import CryptoKit
import XCTest
@testable import OpenGlasses

/// A ChatGPT model the account's catalog does not list: the backend's refusal is classified, the
/// stored catalog keeps what the account offers, and a turn sends the catalog's default instead of
/// a model that would be refused again.
@MainActor
final class ChatGPTModelAvailabilityTests: XCTestCase {

    /// The subscription backend's refusal, byte for byte as a tester's support report measured it
    /// (94 bytes): a model outside the account's catalog.
    static let codexRefusal = #"{"detail":"The 'gpt-5.6-sol' model is not supported when using Codex with a ChatGPT account."}"#

    private var suite = ""
    private var originalStore: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        suite = "ChatGPTModelAvailabilityTests.\(UUID().uuidString)"
        originalStore = ChatGPTContextCatalog.store
        ChatGPTContextCatalog.store = UserDefaults(suiteName: suite)!
    }

    override func tearDown() async throws {
        // Signed out: clears a stale mark a test left, so no other suite inherits it.
        ChatGPTContextCatalog.update(data: Data(), accountID: nil)
        ChatGPTContextCatalog.store.removePersistentDomain(forName: suite)
        ChatGPTContextCatalog.store = originalStore
        try await super.tearDown()
    }

    private func catalog(ids: [String], pickable: [String]? = nil, defaultID: String? = nil)
        -> ChatGPTModelAvailability.Catalog {
        .init(ids: ids, pickable: pickable ?? ids, defaultID: defaultID)
    }

    // MARK: - The refusal

    func testTheBackendsRefusalIsAModelTheAccountDoesNotOffer() {
        XCTAssertEqual(Data(Self.codexRefusal.utf8).count, 94, "the fixture is the reported body")
        let rejection = ProviderRejection(status: 400, body: Data(Self.codexRefusal.utf8), provider: .chatgpt)
        XCTAssertEqual(rejection.reason, .modelNotAvailable)
        XCTAssertTrue(rejection.reason.endsOnlyThisCandidate)
        XCTAssertFalse(rejection.reason.isModelContract, "not a parameter the model refuses")

        let error = LLMError.apiError(provider: "ChatGPT", statusCode: 400, message: Self.codexRefusal,
                                      rejection: rejection)
        XCTAssertEqual(ModelFallbackChain.classify(error), .terminalForCandidate,
                       "another model may answer the very same request")
    }

    func testTheRefusalIsLoggedWithItsReasonAndMarksTheCatalogStale() async throws {
        let fetched = Date()
        ChatGPTContextCatalog.update(data: Data(#"{"models":[{"slug":"gpt-5.5"}]}"#.utf8),
                                     accountID: "account-a", now: fetched)
        XCTAssertFalse(ChatGPTContextCatalog.needsRefresh(accountID: "account-a", now: fetched))

        RecordingQueueProtocol.reset()
        defer { RecordingQueueProtocol.reset() }
        RecordingQueueProtocol.queue = [(400, Self.codexRefusal)]
        let llm = LLMService()
        llm.streamingSession = RecordingQueueProtocol.session()
        llm.processingConsent = CloudConsentFixture.conversation(origins: ["https://chatgpt.com"])
        var lines: [String] = []
        let lock = NSLock()
        let tap = PrivacyLog.addTap { _, line in
            guard line.contains("event=apiError") else { return }
            lock.lock(); lines.append(line); lock.unlock()
        }
        defer { PrivacyLog.removeTap(tap) }

        do {
            _ = try await llm.streamResponsesTurn(
                request: URLRequest(url: URL(string: ChatGPTOAuth.backendResponsesURL)!), onToken: nil)
            XCTFail("a refused model must not answer")
        } catch LLMError.apiError(_, let status, _, let rejection?) {
            XCTAssertEqual(status, 400)
            XCTAssertEqual(rejection.reason, .modelNotAvailable)
        }

        let logged = lock.withLock { lines }
        XCTAssertEqual(logged.count, 1)
        XCTAssertTrue(logged.first?.contains("reason=modelNotAvailable") ?? false, "\(logged)")
        XCTAssertTrue(logged.first?.contains("detail=limitHeadersAbsent") ?? false,
                      "the stub sends no usage headers: \(logged)")
        XCTAssertFalse(logged.first?.contains("gpt-5.6-sol") ?? true, "the body never reaches the log")
        XCTAssertTrue(ChatGPTContextCatalog.needsRefresh(accountID: "account-a", now: fetched),
                      "a catalog known to be wrong is fetched again on the next turn")
    }

    // MARK: - The decision

    func testAListedModelIsSentAsSaved() {
        XCTAssertEqual(ChatGPTModelAvailability.decide(model: "gpt-5.5", catalog: catalog(ids: ["gpt-5.5", "gpt-6-astra"])),
                       .send)
    }

    func testWithNoCatalogToJudgeByTheSavedModelIsSent() {
        XCTAssertEqual(ChatGPTModelAvailability.decide(model: "gpt-5.6-sol", catalog: nil), .send)
        XCTAssertEqual(ChatGPTModelAvailability.decide(model: "gpt-5.6-sol", catalog: catalog(ids: [])), .send,
                       "an empty catalog is a failed fetch, not an account with no models")
    }

    func testAnUnlistedModelTakesTheCatalogsDefault() {
        let offered = catalog(ids: ["gpt-5.5", "gpt-6-astra"], defaultID: "gpt-6-astra")
        XCTAssertEqual(ChatGPTModelAvailability.decide(model: "gpt-5.6-sol", catalog: offered),
                       .substitute("gpt-6-astra"))
    }

    func testWithNoDefaultTheFirstPickableModelIsTaken() {
        let offered = catalog(ids: ["codex-internal", "gpt-5.5"], pickable: ["gpt-5.5"])
        XCTAssertEqual(ChatGPTModelAvailability.decide(model: "gpt-5.6-sol", catalog: offered),
                       .substitute("gpt-5.5"))
    }

    func testAHiddenModelIsStillServed() {
        let offered = catalog(ids: ["gpt-5.5", "codex-internal"], pickable: ["gpt-5.5"], defaultID: "gpt-5.5")
        XCTAssertEqual(ChatGPTModelAvailability.decide(model: "codex-internal", catalog: offered), .send)
    }

    func testWithNothingPickableTheSavedModelIsSent() {
        let offered = catalog(ids: ["codex-internal"], pickable: [])
        XCTAssertEqual(ChatGPTModelAvailability.decide(model: "gpt-5.6-sol", catalog: offered), .send)
    }

    func testTheNoticeNamesNoModelAndPointsAtSettings() {
        let notice = ChatGPTModelAvailability.substitutionNotice
        XCTAssertTrue(notice.contains("isn't available on your ChatGPT account right now"))
        XCTAssertTrue(notice.contains("usage limit"), "a used-up allowance is the likelier cause")
        XCTAssertTrue(notice.contains("Settings"))
        XCTAssertFalse(notice.lowercased().contains("gpt-"))
    }

    // MARK: - The usage headers on a refusal

    func testAUsageHeaderAtItsLimitReadsAsExhausted() {
        XCTAssertEqual(ChatGPTModelAvailability.limitReading(headers: [
            "x-codex-primary-used-percent": "100", "x-codex-secondary-used-percent": "12"]), .exhausted)
        XCTAssertEqual(ChatGPTModelAvailability.limitReading(headers: [
            "X-Codex-Secondary-Used-Percent": "100.0"]), .exhausted, "names are matched without case")
        // A separately metered limit carries its own prefix.
        XCTAssertEqual(ChatGPTModelAvailability.limitReading(headers: [
            "x-codex-sol-primary-used-percent": "100", "x-codex-primary-used-percent": "40"]), .exhausted)
    }

    func testUsageHeadersBelowTheirLimitReadAsBelow() {
        XCTAssertEqual(ChatGPTModelAvailability.limitReading(headers: [
            "x-codex-primary-used-percent": "99.5", "x-codex-secondary-used-percent": " 40 "]), .belowLimit)
    }

    func testWithNoReadableUsageHeaderTheReadingIsAbsent() {
        XCTAssertEqual(ChatGPTModelAvailability.limitReading(headers: ["Content-Type": "application/json"]), .absent)
        XCTAssertEqual(ChatGPTModelAvailability.limitReading(headers: [
            "x-codex-primary-used-percent": "lots", "x-codex-primary-window-minutes": "300"]), .absent,
            "a value that is not a number, or a header that is not a percentage, is not a reading")
    }

    // MARK: - A turn

    func testATurnOnAnUnlistedModelSubstitutesAndAsksForAFreshCatalog() {
        let fetched = Date()
        ChatGPTContextCatalog.update(data: payload, accountID: "account-a", now: fetched)
        XCTAssertFalse(ChatGPTContextCatalog.needsRefresh(accountID: "account-a", now: fetched))

        XCTAssertNil(ChatGPTModelAvailability.modelForTurn("gpt-5.5", accountID: "account-a", now: fetched))
        XCTAssertFalse(ChatGPTContextCatalog.needsRefresh(accountID: "account-a", now: fetched),
                       "a listed model leaves the catalog alone")

        XCTAssertEqual(ChatGPTModelAvailability.modelForTurn("gpt-5.6-sol", accountID: "account-a", now: fetched),
                       "gpt-6-astra")
        XCTAssertTrue(ChatGPTContextCatalog.needsRefresh(accountID: "account-a", now: fetched),
                      "the saved model may come back when its allowance does")

        // Listed again: the saved model is sent as saved.
        let restored = Data(#"{"models":[{"slug":"gpt-6-astra","is_default":true},{"slug":"gpt-5.6-sol"}]}"#.utf8)
        ChatGPTContextCatalog.update(data: restored, accountID: "account-a", now: fetched)
        XCTAssertNil(ChatGPTModelAvailability.modelForTurn("gpt-5.6-sol", accountID: "account-a", now: fetched))
    }

    // MARK: - The stored catalog

    private let payload = Data(#"""
    {"models":[
      {"slug":"gpt-6-astra","display_name":"GPT-6 Astra","context_window":272000,"is_default":true},
      {"slug":"gpt-5.5","display_name":"GPT-5.5","context_window":272000},
      {"slug":"codex-internal","hidden":true}
    ]}
    """#.utf8)

    func testTheCatalogIsReadFromThePayloadThePickerReads() throws {
        let offered = try XCTUnwrap(ChatGPTModelAvailability.Catalog(data: payload))
        XCTAssertEqual(offered.ids, ["gpt-6-astra", "gpt-5.5", "codex-internal"])
        XCTAssertEqual(offered.pickable, ["gpt-6-astra", "gpt-5.5"])
        XCTAssertEqual(offered.defaultID, "gpt-6-astra")
        XCTAssertNil(ChatGPTModelAvailability.Catalog(data: Data("not json".utf8)))
    }

    func testTheStoredCatalogSaysWhatThisAccountOffers() throws {
        let fetched = Date(timeIntervalSince1970: 1_800_000_000)
        ChatGPTContextCatalog.update(data: payload, accountID: "account-a", now: fetched)

        let offered = try XCTUnwrap(ChatGPTContextCatalog.offered(accountID: "account-a", now: fetched))
        XCTAssertEqual(ChatGPTModelAvailability.decide(model: "gpt-5.6-sol", catalog: offered),
                       .substitute("gpt-6-astra"))
        XCTAssertNil(ChatGPTContextCatalog.offered(accountID: "account-b", now: fetched), "never another account's")
        XCTAssertNil(ChatGPTContextCatalog.offered(accountID: "account-a",
                                                   now: fetched.addingTimeInterval(ChatGPTContextCatalog.maxAge)),
                     "too old to judge by")
    }

    func testASnapshotStoredBeforeAvailabilityWasKeptStillReadsItsWindows() throws {
        // The shape an earlier build wrote: no `offered`.
        let earlier = #"{"accountDigest":"\#(digest("account-a"))","updatedAt":0,"windows":{"gpt-5.5":272000}}"#
        ChatGPTContextCatalog.store.set(Data(earlier.utf8), forKey: ChatGPTContextCatalog.storeKey)
        let now = Date(timeIntervalSinceReferenceDate: 60)
        XCTAssertEqual(ChatGPTContextCatalog.context(model: "gpt-5.5", accountID: "account-a", now: now), 272_000)
        XCTAssertNil(ChatGPTContextCatalog.offered(accountID: "account-a", now: now),
                     "an old snapshot says nothing about availability, so nothing is replaced")
    }

    func testMarkingStaleAsksForAFetchUntilTheNextOneArrives() {
        let fetched = Date(timeIntervalSince1970: 1_800_000_000)
        ChatGPTContextCatalog.update(data: payload, accountID: "account-a", now: fetched)
        XCTAssertFalse(ChatGPTContextCatalog.needsRefresh(accountID: "account-a", now: fetched))
        ChatGPTContextCatalog.markStale()
        XCTAssertTrue(ChatGPTContextCatalog.needsRefresh(accountID: "account-a", now: fetched))
        XCTAssertFalse(ChatGPTContextCatalog.needsRefresh(accountID: nil, now: fetched), "no account, no fetch")
        ChatGPTContextCatalog.update(data: payload, accountID: "account-a", now: fetched)
        XCTAssertFalse(ChatGPTContextCatalog.needsRefresh(accountID: "account-a", now: fetched))
    }

    private func digest(_ accountID: String) -> String {
        SHA256.hash(data: Data(accountID.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
