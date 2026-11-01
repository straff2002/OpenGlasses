import XCTest
@testable import OpenGlasses

@MainActor
final class CloudProcessingConsentTests: XCTestCase {
    private var directory: URL!
    private var store: ConsentStore!
    private var consent: CloudProcessingConsent!
    private let url = URL(string: "https://ai.example.test/v1/chat?key=secret")!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = ConsentStore(directory: directory)
        consent = CloudProcessingConsent(store: store, foreground: { true })
        consent.presenterAvailable = true
    }
    override func tearDown() {
        consent.cancelPending()
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }
    private func waitForPrompt() async {
        for _ in 0..<200 {
            if consent.pending != nil { return }
            await Task.yield()
        }
        XCTFail("An interactive request should present its actual destination")
    }
    private func approve(_ scope: CloudProcessingScope = .conversation) {
        store.recordWearerApproval(purpose: .aiProcessing, dataClass: scope.dataClass,
                                  recipient: "https://ai.example.test", version: CloudProcessingTerms.version)
    }

    func testOriginsRemoveSecretsAndNormalizeWebSocketAndDefaultPorts() throws {
        let terms = try CloudProcessingTerms(url: URL(string: "wss://user:password@AI.EXAMPLE.TEST:443/path?token=secret#fragment")!, scope: .conversation)
        XCTAssertEqual(terms.origin, "https://ai.example.test")
        XCTAssertNotEqual(terms, try CloudProcessingTerms(url: URL(string: "https://ai.example.test:8443")!, scope: .conversation))
        XCTAssertThrowsError(try CloudProcessingTerms(url: URL(string: "file:///tmp/model")!, scope: .conversation))
    }
    func testApprovalIsSpecificToRecipientAndUseAndSurvivesRestart() async throws {
        approve()
        _ = try await consent.authorize(url: url, scope: .conversation)
        XCTAssertFalse(consent.hasApproval(url: url, scope: .speechOutput))
        XCTAssertFalse(consent.hasApproval(url: URL(string: "https://other.example.test")!, scope: .conversation))
        let restarted = CloudProcessingConsent(store: ConsentStore(directory: directory), foreground: { false })
        XCTAssertTrue(restarted.hasApproval(url: url, scope: .conversation))
        let saved = try String(contentsOf: store.storeURL, encoding: .utf8)
        XCTAssertFalse(saved.contains("secret"))
        XCTAssertFalse(saved.contains("/v1/chat"))
    }
    func testBackgroundCannotPromptOrCreatePermission() async {
        let background = CloudProcessingConsent(store: store, foreground: { false })
        background.presenterAvailable = true
        do { _ = try await background.authorize(url: url, scope: .conversation); XCTFail("Must refuse") }
        catch { XCTAssertTrue(error is CloudProcessingRefusal) }
        XCTAssertNil(background.pending)
        XCTAssertTrue(store.records.isEmpty)
    }
    func testGrantRequiresExplicitResponseAndWithdrawalInvalidatesActiveLease() async throws {
        let request = Task { try await consent.authorize(url: url, scope: .liveSession) }
        await waitForPrompt()
        XCTAssertEqual(consent.pending?.terms.origin, "https://ai.example.test")
        XCTAssertTrue(store.records.isEmpty)
        consent.respond(allow: true)
        let lease = try await request.value
        var cancelled = false
        lease.onWithdrawal { cancelled = true }
        consent.withdraw(try XCTUnwrap(consent.approvals.first))
        XCTAssertFalse(lease.isValid)
        XCTAssertTrue(cancelled)
        do { _ = try await consent.authorize(url: url, scope: .liveSession); XCTFail("Withdrawal must persist") }
        catch { XCTAssertTrue(error is CloudProcessingRefusal) }
        XCTAssertNil(consent.pending, "Withdrawal must not immediately ask again")
    }
    func testDeclineDoesNotInventConsentAndCancellationRemovesThePrompt() async {
        let request = Task { try await consent.authorize(url: url, scope: .conversation) }
        await waitForPrompt()
        consent.respond(allow: false)
        do { _ = try await request.value; XCTFail("Must refuse") } catch {}
        XCTAssertTrue(store.records.isEmpty)
        let other = Task { try await consent.authorize(url: url, scope: .speechOutput) }
        await waitForPrompt()
        other.cancel()
        do { _ = try await other.value; XCTFail("Must cancel") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNil(consent.pending)
    }
    func testRefusedHTTPNeverReachesTheTransportAndGrantAllowsIt() async throws {
        let session = RecordingQueueProtocol.session()
        defer { session.invalidateAndCancel(); RecordingQueueProtocol.reset() }
        RecordingQueueProtocol.reset()
        consent.presenterAvailable = false
        do {
            _ = try await session.consentedData(for: URLRequest(url: url), scope: .conversation, consent: consent)
            XCTFail("No approval")
        } catch { XCTAssertTrue(error is CloudProcessingRefusal) }
        XCTAssertTrue(RecordingQueueProtocol.requests.isEmpty)
        approve()
        RecordingQueueProtocol.queue = [(200, "ok")]
        let (data, _) = try await session.consentedData(for: URLRequest(url: url), scope: .conversation, consent: consent)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "ok")
        XCTAssertEqual(RecordingQueueProtocol.requests.count, 1)
    }
    func testRedirectCannotSendToAnUnapprovedOrigin() throws {
        approve()
        let lease = try consent.existingLease(url: url, scope: .conversation)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let delegate = CloudProcessingTransferDelegate(lease: lease, session: session, url: url)
        let task = session.dataTask(with: url)
        let response = HTTPURLResponse(url: url, statusCode: 307, httpVersion: nil, headerFields: nil)!
        var permitted: URLRequest?
        delegate.urlSession(session, task: task, willPerformHTTPRedirection: response,
                            newRequest: URLRequest(url: URL(string: "https://other.example.test")!)) { permitted = $0 }
        XCTAssertNil(permitted)
        delegate.urlSession(session, task: task, willPerformHTTPRedirection: response,
                            newRequest: URLRequest(url: url)) { permitted = $0 }
        XCTAssertEqual(permitted?.url, url)
        lease.invalidate()
        delegate.urlSession(session, task: task, willPerformHTTPRedirection: response,
                            newRequest: URLRequest(url: url)) { permitted = $0 }
        XCTAssertNil(permitted)
        task.cancel()
    }
    func testWithdrawalCancelsAnInFlightHTTPUpload() async throws {
        approve()
        let started = expectation(description: "Authorized request reached the transport")
        let stopped = expectation(description: "Withdrawal cancelled that request")
        HoldingConsentProtocol.started = { started.fulfill() }
        HoldingConsentProtocol.stopped = { stopped.fulfill() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HoldingConsentProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            HoldingConsentProtocol.started = nil
            HoldingConsentProtocol.stopped = nil
        }
        let transfer = Task { try await session.consentedData(for: URLRequest(url: url), scope: .conversation, consent: consent) }
        await fulfillment(of: [started], timeout: 5)
        consent.withdraw(try XCTUnwrap(consent.approvals.first))
        do { _ = try await transfer.value; XCTFail("Withdrawn upload must stop") }
        catch { XCTAssertTrue(error is CloudProcessingRefusal) }
        await fulfillment(of: [stopped], timeout: 5)
    }
    func testRefusalAndTransferCancellationNeverCascadeToAnotherModel() {
        XCTAssertEqual(ModelFallbackChain.classify(CloudProcessingRefusal.permissionRequired), .terminalForTurn)
        XCTAssertEqual(ModelFallbackChain.classify(CloudProcessingRefusal.withdrawn), .terminalForTurn)
        XCTAssertEqual(ModelFallbackChain.classify(URLError(.cancelled)), .terminalForTurn)
    }
    func testRealtimeTransportCannotOpenBeforeSharingApproval() {
        let transport = RealtimeWebSocketTransport()
        defer { transport.cancel() }
        let request = URLRequest(url: URL(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent")!)
        XCTAssertThrowsError(try transport.start(request))
    }
    func testAnApprovalThatCannotBeSavedDoesNotAuthorizeSharing() async throws {
        let blockedPath = directory.appendingPathComponent("not-a-directory")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("file".utf8).write(to: blockedPath)
        let blockedStore = ConsentStore(directory: blockedPath)
        let blocked = CloudProcessingConsent(store: blockedStore, foreground: { true })
        blocked.presenterAvailable = true
        let request = Task { try await blocked.authorize(url: url, scope: .conversation) }
        for _ in 0..<200 { if blocked.pending != nil { break }; await Task.yield() }
        XCTAssertNotNil(blocked.pending)
        blocked.respond(allow: true)
        do { _ = try await request.value; XCTFail("An unsaved approval must not authorize egress") }
        catch { XCTAssertTrue(error is CloudProcessingRefusal) }
        XCTAssertFalse(blockedStore.storageAvailable)
        XCTAssertFalse(blocked.hasApproval(url: url, scope: .conversation))
        XCTAssertNotNil(blocked.storageNotice)
    }
}

private final class HoldingConsentProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var started: (() -> Void)?
    nonisolated(unsafe) static var stopped: (() -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.started?() }
    override func stopLoading() { Self.stopped?() }
}

/// Existing protocol fixtures still traverse real authorization, with isolated approvals for
/// the exact destinations they script. This cannot authorize a production request.
@MainActor
enum CloudConsentFixture {
    static func conversation(origins: [String] = ["https://api.test", "https://api.anthropic.com", "https://api.openai.com", "https://selected.example.test"]) -> CloudProcessingConsent {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ConsentStore(directory: directory)
        for origin in origins {
            store.recordWearerApproval(purpose: .aiProcessing, dataClass: .assistantContext,
                                      recipient: origin, version: CloudProcessingTerms.version)
        }
        try? FileManager.default.removeItem(at: directory)
        return CloudProcessingConsent(store: store, foreground: { false })
    }
}
