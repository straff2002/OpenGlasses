import XCTest
@testable import OpenGlasses

/// The privacy property of the logging facade, asserted rather than asserted-to.
///
/// Two halves. The first is a pure test of the encoder: every typed `PrivacyLog` method is called
/// with a recognisable sentinel in *every* parameter that could carry a string, and the encoded
/// line is checked for the sentinel. Because `emit` returns the event it logged, this exercises
/// the real methods rather than a parallel reimplementation of them.
///
/// The second half reads the app's own source, because a facade nobody uses proves nothing: the
/// files the leak was found in must contain no log call that interpolates a content-named value
/// or reads `localizedDescription`.
final class PrivacyLogTests: XCTestCase {

    // MARK: - Sentinels

    /// Every sentinel contains the literal `SENTINEL`, so one assertion covers them all, and each
    /// is shaped like the real thing it stands for: a spoken sentence, a tool-argument blob, a URL
    /// with a credential in its query, a bearer token, an HTTP cookie.
    private enum Sentinel {
        static let transcript = "SENTINEL remind me to call Dr Alvarez about the biopsy result"
        static let toolArgs = #"{"to":"SENTINELPERSON@example.test","body":"meet at 8"}"#
        static let url = "https://museum.example.test/ctx?visitor=SENTINELVISITOR&token=SENTINELTOKEN"
        static let secret = "sk-ant-SENTINEL/SECRET+VALUE=="
        static let cookie = "session=SENTINELSESSION; Path=/; HttpOnly"

        static let all = [transcript, toolArgs, url, secret, cookie]
    }

    /// An error whose description is exactly the thing that must never be logged.
    private struct MaliciousError: LocalizedError {
        var errorDescription: String? {
            "POST https://api.example.test/v1/token?code=SENTINELCODE failed — "
                + #"{"transcript":"SENTINEL the patient said"}"#
        }
    }

    /// An error enum whose payload is sensitive but whose case name is not.
    private enum MaliciousEnumError: Error {
        case refusedHost(String)
    }

    // MARK: - Every method, every sentinel

    /// Calls each typed method with `text` wherever a string can be passed.
    private func allEvents(with text: String) -> [PrivacyEvent] {
        [
            PrivacyLog.toolCallReceived(name: text, invocation: text),
            PrivacyLog.toolCallRefused(name: text, invocation: text),
            PrivacyLog.toolCallAcked(name: text, invocation: text),
            PrivacyLog.toolCallCancelled(invocation: text),
            PrivacyLog.toolCallCompleted(name: text, invocation: text,
                                         outcome: .completed, durationMs: 1234),
            PrivacyLog.realtimeSession(.openai, .sessionCreated, detail: PrivacyToken(text)),
            PrivacyLog.realtimeUtterance(.gemini, direction: .input, characters: text.count),
            PrivacyLog.realtimeMedia(.gemini, kind: .streamedFrame, kilobytes: 42, sequence: 7),
            PrivacyLog.realtimeSendSkipped(.openai, kind: .text, reason: .notReady,
                                           state: PrivacyToken(text)),
            PrivacyLog.realtimeTruncated(.openai, item: text, playedMs: 900),
            PrivacyLog.realtimeReconnectScheduled(.gemini, attempt: 2, of: 10, delaySeconds: 4),
            PrivacyLog.realtimeReconnectExhausted(.gemini, attempts: 10),
            PrivacyLog.realtimeGoAway(.gemini, secondsRemaining: 30),
            PrivacyLog.realtimeToolCall(.gemini, functions: 2),
            PrivacyLog.realtimeToolCancellation(.gemini, calls: 1),
            PrivacyLog.realtimeLatency(.openai, milliseconds: 640),
            PrivacyLog.realtimeError(.openai, phase: .fatal, .remote(code: text)),
            PrivacyLog.qrScanned(payload: .url, bytes: text.utf8.count),
            PrivacyLog.qrFetchBlocked(.refused(URLFetchGuard.Rejection.privateOrReservedHost(text))),
            PrivacyLog.qrFetchLoaded(host: text, characters: 8000),
            PrivacyLog.homeOperation(.converse, success: true, replyCharacters: text.count),
            PrivacyLog.homeEntityResolved(.fuzzy),
            PrivacyLog.homeFallback(.callService),
            PrivacyLog.deepLink(route: .wearablesCallback, source: PrivacyToken(text),
                                verdict: .failed, action: PrivacyToken(text),
                                error: SafeErrorSummary(MaliciousError())),
            PrivacyLog.authFailed(.claude, .tokenRefresh, SafeErrorSummary(MaliciousError())),
            PrivacyLog.requestFailed(.homeAssistant, .http(status: 503)),
        ]
    }

    func testNoEncodedEventEverContainsASentinel() {
        for sentinel in Sentinel.all {
            for event in allEvents(with: sentinel) {
                let line = PrivacyEventEncoder.encode(event)
                XCTAssertFalse(line.contains("SENTINEL"),
                               "\(event.name.rawValue) leaked a sentinel: \(line)")
            }
        }
    }

    /// The sentinels are only meaningful if the events actually carry something. Without this, a
    /// facade that encoded the empty string would pass the test above.
    func testEncodedEventsCarryTheirMetadata() {
        let event = PrivacyLog.toolCallCompleted(name: "send_message", invocation: "call-9f2",
                                                 outcome: .rejected, durationMs: 1234)
        let line = PrivacyEventEncoder.encode(event)
        XCTAssertTrue(line.contains("[tools] toolCallCompleted"), line)
        XCTAssertTrue(line.contains("tool=send_message"), line)
        XCTAssertTrue(line.contains("outcome=rejected"), line)
        XCTAssertTrue(line.contains("duration=1234ms"), line)
        XCTAssertFalse(line.contains("call-9f2"), "the raw call id must not appear: \(line)")
        XCTAssertTrue(line.contains("invocation=#"), "the call id should appear as a fingerprint: \(line)")
    }

    /// Every declared event name is reachable from at least one method — a name that only exists
    /// in the enum is dead vocabulary that reads like shipped behaviour.
    func testEveryEventNameIsProducedBySomeMethod() {
        let produced = Set(allEvents(with: "probe").map(\.name))
        for name in PrivacyEvent.Name.allCases {
            XCTAssertTrue(produced.contains(name),
                          "PrivacyEvent.Name.\(name.rawValue) is declared but never emitted")
        }
    }

    // MARK: - PrivacyToken

    func testTokenDropsAnythingOutsideItsVocabulary() {
        for sentinel in Sentinel.all {
            XCTAssertEqual(PrivacyToken(sentinel).description, PrivacyToken.placeholder,
                           "should have been dropped: \(sentinel)")
        }
        XCTAssertEqual(PrivacyToken("").description, PrivacyToken.placeholder)
        XCTAssertEqual(PrivacyToken(String(repeating: "a", count: 49)).description,
                       PrivacyToken.placeholder, "over-length values are dropped, not truncated")
    }

    func testTokenKeepsVocabularyWords() {
        XCTAssertEqual(PrivacyToken("send_message").description, "send_message")
        XCTAssertEqual(PrivacyToken("response.audio.delta").description, "response.audio.delta")
        XCTAssertEqual(PrivacyToken("gemini-2.0-flash").description, "gemini-2.0-flash")
    }

    /// Pins the type's stated limit rather than pretending it does not exist: `PrivacyToken` is a
    /// shape filter, not a secret detector, so a short identifier-shaped value survives it. The
    /// compensating control is that no call site constructs a token from a credential, and
    /// `Scripts/check-privacy-logging.sh` flags the ones that might.
    func testTokenIsAShapeFilterNotASecretDetector() {
        XCTAssertEqual(PrivacyToken("identifierShapedSecret").description, "identifierShapedSecret")
    }

    /// A payload-free case with no custom description reads back as its case name.
    private enum PlainCaseError: Error { case somethingBroke }

    func testCaseNameLeavesEnumPayloadsBehind() {
        XCTAssertEqual(PrivacyToken.caseName(of: MaliciousEnumError.refusedHost("SENTINELHOST"))?
            .description, "refusedHost")
        XCTAssertEqual(PrivacyToken.caseName(of: URLFetchGuard.Rejection.privateOrReservedHost("SENTINELHOST"))?
            .description, "privateOrReservedHost")
        XCTAssertEqual(PrivacyToken.caseName(of: PlainCaseError.somethingBroke)?
            .description, "somethingBroke")
        XCTAssertNil(PrivacyToken.caseName(of: MaliciousError()), "a struct has no case name")
    }

    /// The trap that `String(describing:)` sets for a payload-free case: `URLFetchGuard.Rejection`
    /// is `CustomStringConvertible` and its description names the refused host, so the case name
    /// is refused outright rather than guessed at.
    func testCustomDescribedEnumsYieldNoCaseName() {
        XCTAssertNil(PrivacyToken.caseName(of: URLFetchGuard.Rejection.invalidURL))
        let summary = SafeErrorSummary.refused(URLFetchGuard.Rejection.disallowedScheme("file"))
        XCTAssertEqual(summary.description, "refused(disallowedScheme)",
                       "a payload case still reports its label, never its payload")
    }

    func testPrivateIdentifierIsAStableOneWayFingerprint() {
        let raw = "conversation-item-SENTINEL"
        let once = PrivateIdentifier(raw).description
        XCTAssertEqual(once, PrivateIdentifier(raw).description, "must be stable within a session")
        XCTAssertFalse(once.contains("SENTINEL"))
        XCTAssertEqual(once.count, 16)
        XCTAssertNotEqual(once, PrivateIdentifier(raw + "x").description)
    }

    // MARK: - SafeErrorSummary

    func testMaliciousDescriptionNeverReachesTheSummary() {
        let summary = SafeErrorSummary(MaliciousError())
        XCTAssertFalse(summary.description.contains("SENTINEL"), summary.description)
        XCTAssertFalse(summary.description.contains("https"), summary.description)
        XCTAssertTrue(summary.description.hasPrefix("unknown("), summary.description)
    }

    func testEnumErrorSummarisesToItsCaseNameOnly() {
        let summary = SafeErrorSummary(MaliciousEnumError.refusedHost("SENTINELHOST"))
        XCTAssertFalse(summary.description.contains("SENTINEL"), summary.description)
        XCTAssertTrue(summary.description.contains("refusedHost"), summary.description)
    }

    func testURLErrorsMapToBoundedCategories() {
        XCTAssertEqual(SafeErrorSummary(URLError(.timedOut)).category, .timedOut)
        XCTAssertEqual(SafeErrorSummary(URLError(.notConnectedToInternet)).category, .offline)
        XCTAssertEqual(SafeErrorSummary(URLError(.secureConnectionFailed)).category, .tlsFailure)
        XCTAssertEqual(SafeErrorSummary(URLError(.badServerResponse)).category, .badServerResponse)
        XCTAssertEqual(SafeErrorSummary(URLError(.cancelled)).category, .cancelled)
    }

    /// A `URLError` knows the URL it failed on. The summary must carry the code, not the URL.
    func testURLErrorSummaryDropsTheFailingURL() {
        let error = URLError(.timedOut, userInfo: [
            NSURLErrorFailingURLErrorKey: URL(string: Sentinel.url) as Any,
        ])
        let summary = SafeErrorSummary(error)
        XCTAssertFalse(summary.description.contains("SENTINEL"), summary.description)
        XCTAssertEqual(summary.description, "timedOut(URLError)#\(URLError.Code.timedOut.rawValue)")
    }

    func testHTTPStatusesMapToBoundedCategories() {
        XCTAssertEqual(SafeErrorSummary.http(status: 401).category, .unauthorized)
        XCTAssertEqual(SafeErrorSummary.http(status: 403).category, .forbidden)
        XCTAssertEqual(SafeErrorSummary.http(status: 404).category, .notFound)
        XCTAssertEqual(SafeErrorSummary.http(status: 429).category, .rateLimited)
        XCTAssertEqual(SafeErrorSummary.http(status: 503).category, .serverError)
        XCTAssertEqual(SafeErrorSummary.http(status: 418).category, .clientError)
        XCTAssertEqual(SafeErrorSummary.http(status: 503).description, "serverError(http)#503")
    }

    func testRemoteCodeIsFilteredLikeAnyOtherToken() {
        XCTAssertTrue(SafeErrorSummary.remote(code: "conversation_already_has_active_response")
            .description.contains("conversation_already_has_active_response"))
        XCTAssertFalse(SafeErrorSummary.remote(code: Sentinel.transcript)
            .description.contains("SENTINEL"))
    }

    func testDecodingErrorsDoNotEchoTheirContext() {
        let context = DecodingError.Context(codingPath: [], debugDescription: "SENTINEL value 42")
        let summary = SafeErrorSummary(DecodingError.dataCorrupted(context))
        XCTAssertEqual(summary.category, .decoding)
        XCTAssertFalse(summary.description.contains("SENTINEL"), summary.description)
    }

    // MARK: - Source scan
    //
    // `#filePath` is the repo anchor: baked in at compile time, so it resolves the same on a
    // developer machine and in CI, and the simulator shares the host filesystem.

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)   // <repo>/OpenGlassesTests/<thisfile>.swift
            .deletingLastPathComponent()  // <repo>/OpenGlassesTests
            .deletingLastPathComponent()  // <repo>
    }

    /// The files the audit found leaking, plus the two credential-refresh sites folded into P0.
    ///
    /// `OpenGlassesApp.swift` is absent deliberately: only its callback handling is in P0 scope,
    /// and the rest of that 5,000-line file is the largest single item on the P1 ledger. Scanning
    /// it whole would fail for work this phase never claimed to do; its callback region is scanned
    /// separately below.
    private static let migratedFiles = [
        "OpenGlasses/Sources/Services/ToolCallRouter.swift",
        "OpenGlasses/Sources/Services/OpenAIRealtime/OpenAIRealtimeService.swift",
        "OpenGlasses/Sources/Services/GeminiLive/GeminiLiveService.swift",
        "OpenGlasses/Sources/Services/NativeTools/QRContextTool.swift",
        "OpenGlasses/Sources/Services/NativeTools/HomeAssistantTool.swift",
        "OpenGlasses/Sources/Services/ClaudeOAuthService.swift",
        "OpenGlasses/Sources/Services/ChatGPTOAuthService.swift",
        "OpenGlasses/Sources/Services/GoogleOAuthService.swift",
    ]

    private func sourceText(_ relativePath: String) throws -> String {
        let url = Self.repoRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func loggingLines(in source: String) -> [String] {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { line in
                guard let range = line.range(of: "NSLog(") ?? line.range(of: "print(") else {
                    return false
                }
                // `.print(` / `debugPrint(` are somebody else's method, not a bare log call.
                guard range.lowerBound > line.startIndex else { return true }
                let preceding = line[line.index(before: range.lowerBound)]
                return !(preceding.isLetter || preceding.isNumber || preceding == "." || preceding == "_")
            }
    }

    /// The names a value carries when it is user content or a credential. Same vocabulary as
    /// `Scripts/check-privacy-logging.sh`, so the test and the scanner cannot disagree.
    private static let contentNames = [
        "args", "arguments", "result", "transcript", "payload", "prompt",
        "urlString", "absoluteString", "token", "apiKey", "cookie", "entityId", "rawText",
    ]

    func testMigratedFilesHaveNoContentBearingLogCalls() throws {
        for path in Self.migratedFiles {
            let source = try sourceText(path)
            for line in loggingLines(in: source) {
                XCTAssertFalse(line.contains("localizedDescription"),
                               "\(path): a log call still reads localizedDescription:\n\(line)")
                for name in Self.contentNames {
                    XCTAssertFalse(line.contains(name),
                                   "\(path): a log call still interpolates '\(name)':\n\(line)")
                }
            }
        }
    }

    /// The callback region of the app entry point: the wearables callback handler, and the
    /// `onOpenURL` block that classifies inbound `openglasses://` links. Both are bounded by
    /// anchors that would have to be deliberately removed to widen the scan silently.
    private func callbackRegions() throws -> [(String, String)] {
        let source = try sourceText("OpenGlasses/Sources/App/OpenGlassesApp.swift")

        func region(from start: String, to end: String) throws -> String {
            guard let lower = source.range(of: start),
                  let upper = source.range(of: end, range: lower.upperBound..<source.endIndex) else {
                throw XCTSkip("callback region anchors not found — the scan would be vacuous")
            }
            return String(source[lower.lowerBound..<upper.lowerBound])
        }

        return [
            ("processWearablesCallbackURL",
             try region(from: "private func processWearablesCallbackURL",
                        to: "final class OpenGlassesAppDelegate")),
            ("onOpenURL",
             try region(from: ".onOpenURL { url in",
                        to: "processWearablesCallbackURL(url, source: \"SwiftUI\")")),
        ]
    }

    func testAppCallbackHandlingHasNoContentBearingLogCalls() throws {
        for (label, region) in try callbackRegions() {
            XCTAssertFalse(region.isEmpty, "\(label): empty region — the scan would be vacuous")
            for line in loggingLines(in: region) {
                XCTFail("\(label): a direct log call survives in the callback path:\n\(line)")
            }
            XCTAssertFalse(region.contains("url.absoluteString"),
                           "\(label): the callback URL must never be formatted into a log")
        }
    }

    /// The specific statements the audit named. A structural check can pass while the exact line
    /// that leaked comes back in a slightly different shape, so these are pinned by their text.
    func testTheAuditedLeakStatementsAreGone() throws {
        let removed: [(String, [String])] = [
            ("OpenGlasses/Sources/Services/ToolCallRouter.swift",
             ["args: %@", "Result for"]),
            ("OpenGlasses/Sources/Services/OpenAIRealtime/OpenAIRealtimeService.swift",
             ["] You: %@", "Fatal error: %@"]),
            ("OpenGlasses/Sources/Services/GeminiLive/GeminiLiveService.swift",
             ["] You: %@", "] AI: %@", "NSLog(\"[Gemini] %@\", text)"]),
            ("OpenGlasses/Sources/Services/NativeTools/QRContextTool.swift",
             ["Scanned QR", "Blocked fetch of", "characters from"]),
            ("OpenGlasses/Sources/Services/NativeTools/HomeAssistantTool.swift",
             ["Conversation API: '", "Resolved '%@'", "Direct call failed for", "HTTP %d: %@"]),
            ("OpenGlasses/Sources/Services/ClaudeOAuthService.swift", ["Token refresh failed"]),
            ("OpenGlasses/Sources/Services/ChatGPTOAuthService.swift", ["Token refresh failed"]),
            ("OpenGlasses/Sources/Services/GoogleOAuthService.swift", ["Token refresh failed"]),
            ("OpenGlasses/Sources/App/OpenGlassesApp.swift",
             ["Received URL callback", "handleUrl result:", "handleUrl failed:",
              "Ignored untrusted deep link", "Refused skillpack link"]),
        ]
        for (path, statements) in removed {
            let source = try sourceText(path)
            for statement in statements {
                XCTAssertFalse(source.contains(statement),
                               "\(path) still contains the leaking statement '\(statement)'")
            }
        }
    }

    /// The guard's own guard. If the repo anchor stops resolving, the scans above would pass
    /// vacuously — a silently disabled test reads as a promise it is not keeping.
    func testTheSourceScanIsActuallyReadingTheApp() throws {
        let router = try sourceText("OpenGlasses/Sources/Services/ToolCallRouter.swift")
        XCTAssertTrue(router.contains("class ToolCallRouter"), "sanity: wrong file or empty read")
        XCTAssertTrue(router.contains("PrivacyLog.toolCallReceived"),
                      "sanity: the migrated call should be visible to the scan")

        let gemini = try sourceText("OpenGlasses/Sources/Services/GeminiLive/GeminiLiveService.swift")
        XCTAssertFalse(loggingLines(in: gemini).isEmpty,
                       "sanity: this file still has content-free NSLog lines, so the line scanner "
                           + "must be finding some — an empty result would mean it matches nothing")
    }

    // MARK: - Build settings

    /// The debug content hatch must be unreachable in anything anyone can build from this repo.
    func testContentLoggingIsEnabledInNoBuildConfiguration() throws {
        for spec in ["project.yml", "project.base.yml", "project.tests.yml", "project.watch.yml"] {
            let url = Self.repoRoot.appendingPathComponent(spec)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            XCTAssertFalse(text.contains("ENABLE_CONTENT_LOGGING"),
                           "\(spec) defines ENABLE_CONTENT_LOGGING — the debug content hatch must "
                               + "never be switched on in a checked-in build configuration")
        }
    }
}
