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
        /// The two regulated shapes batch 3 exists for: a person the wearer enrolled, and a
        /// device in a named room of their house.
        static let personName = "Dr SENTINEL Alvarez"
        static let entityName = "light.SENTINEL_master_bedroom"

        /// `entityName` is deliberately absent: it is identifier-shaped, so `PrivacyToken` keeps
        /// it — the type's stated limit, pinned by `testTokenIsAShapeFilterNotASecretDetector`.
        /// The protection for an entity id is that no method takes one, which is asserted
        /// directly in `testRegulatedNamesHaveNoParameterAtAll`.
        static let all = [transcript, toolArgs, url, secret, cookie, personName]
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
            PrivacyLog.realtimeSession(.openai, .sessionCreated, detail: PrivacyToken(text),
                                       state: PrivacyToken(text), count: 4, total: 9,
                                       characters: text.count, success: false,
                                       error: SafeErrorSummary(MaliciousError())),
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
            PrivacyLog.keychainFailed(.read, status: -25300),
            PrivacyLog.configMigration(.providerSecrets, .completed),
            PrivacyLog.requestFailed(.homeAssistant, .http(status: 503)),
            PrivacyLog.gatewayConnection(.connecting, transport: .lan,
                                         peer: PrivateIdentifier(text), count: 3,
                                         detail: PrivacyToken(text)),
            PrivacyLog.gatewayReconnectScheduled(delaySeconds: 4.2),
            PrivacyLog.gatewayHealth(.tunnel, reachable: false, status: 503),
            PrivacyLog.gatewayOperation(text, outcome: .failed, count: 2, characters: text.count),
            PrivacyLog.gatewayNotification(.cronResult, characters: text.count),
            PrivacyLog.gatewayFailed(.handshake, SafeErrorSummary(MaliciousError())),
            PrivacyLog.mcpDiscovery(tools: 4, servers: 2),
            PrivacyLog.mcpToolScreened(.blocked, tool: text, server: PrivateIdentifier(text)),
            PrivacyLog.mcpEgress(.redacted, tool: text, server: PrivateIdentifier(text), hits: 3),
            PrivacyLog.mcpFailed(.transport, server: PrivateIdentifier(text),
                                 SafeErrorSummary(MaliciousError())),
            PrivacyLog.mcpServer(.requestRejected, port: 8765, route: .unknown,
                                 error: .http(status: 401)),
            PrivacyLog.stream(.viewerBroadcast, .started, detail: PrivacyToken(text), count: 2,
                              session: PrivateIdentifier(text), attempt: 3, delaySeconds: 2,
                              error: SafeErrorSummary(MaliciousError())),
            // P1 batch 2 — conversation / model / audio.
            PrivacyLog.toolGate(.confirmationRequired, tool: text, detail: PrivacyToken(text)),
            PrivacyLog.toolDispatch(.gateway, tool: text),
            PrivacyLog.toolRun(.succeeded, tool: text, seconds: 1.5, count: 1,
                               characters: text.count, detail: PrivacyToken(text),
                               error: SafeErrorSummary(MaliciousError())),
            PrivacyLog.toolAuthorizationRefused(verdict: text, tool: text, origin: text,
                                                depth: 1, invocation: text),
            PrivacyLog.webSearch(.perplexity, succeeded: false, status: 503, results: 0,
                                 error: SafeErrorSummary(MaliciousError())),
            PrivacyLog.wakeWord(.fuzzyDetected, trigger: .wakePhrase, attempt: 1, count: 2,
                                distance: 2, error: SafeErrorSummary(MaliciousError())),
            PrivacyLog.speech(.ambientCaptions, .transcriptDelivered,
                              language: PrivacyToken(text), characters: text.count, count: 1,
                              seconds: 2, bytes: text.utf8.count, detail: PrivacyToken(text),
                              error: SafeErrorSummary(MaliciousError())),
            PrivacyLog.tts(.speaking, engine: PrivacyToken(text), characters: text.count,
                           bytes: 4096, seconds: 1.2, quality: 2,
                           voice: PrivateIdentifier(text), status: 200, success: true,
                           detail: PrivacyToken(text),
                           error: SafeErrorSummary(MaliciousError())),
            PrivacyLog.audio(.wakeWord, .routeChanged, owner: PrivacyToken(text),
                             route: PrivacyToken(text), device: PrivateIdentifier(text),
                             detail: PrivacyToken(text), hertz: 48_000, channels: 1,
                             bytes: 320, milliseconds: 40, count: 2,
                             error: SafeErrorSummary(MaliciousError())),
            PrivacyLog.model(.turnStarted, provider: PrivacyToken(text),
                             model: PrivacyToken(text),
                             configuration: PrivateIdentifier(text), attempt: 1, count: 2,
                             total: 3, characters: text.count, tokens: 900, status: 429,
                             bytes: 2048, seconds: 0.5, success: false,
                             detail: PrivacyToken(text),
                             error: SafeErrorSummary(MaliciousError())),
            PrivacyLog.modelCompaction(messagesBefore: 40, messagesAfter: 12,
                                       tokensBefore: 9000, tokensAfter: 2200, signals: 3,
                                       detail: PrivacyToken(text)),
            PrivacyLog.localModel(.tokenShape, model: PrivacyToken(text), vision: true,
                                  count: 1, total: 2, characters: text.count, tokens: 842,
                                  shape: PrivacyToken(text), megabytes: 1200,
                                  cacheMegabytes: 300, footprintMegabytes: 2100,
                                  headroomMegabytes: 900, kilobytes: 64,
                                  tool: PrivacyToken(text), detail: PrivacyToken(text),
                                  error: SafeErrorSummary(MaliciousError())),
            PrivacyLog.conversation(.conversations, .threadResumed,
                                    thread: PrivateIdentifier(text), count: 12,
                                    characters: text.count, minutes: 7,
                                    detail: PrivacyToken(text),
                                    error: SafeErrorSummary(MaliciousError())),
            // P1 batch 3 — vision / home / medical / location.
            PrivacyLog.camera(.glasses, .streamState, device: PrivateIdentifier(text),
                              state: PrivacyToken(text), detail: PrivacyToken(text),
                              resolution: PrivacyToken(text), frameRate: 30,
                              width: 1280, height: 720, attempt: 1, ofAttempts: 4,
                              count: 12, kilobytes: 64, bytes: 65_536, seconds: 1.5,
                              error: SafeErrorSummary(MaliciousError())),
            PrivacyLog.photoLibrary(.saveNotPermitted, asset: .image,
                                    status: PrivacyToken(text),
                                    error: SafeErrorSummary(MaliciousError())),
            PrivacyLog.vision(.ocr, .textRecognized, reason: PrivacyToken(text),
                              posture: PrivacyToken(text), count: 4,
                              characters: text.count, percent: 62, kilobytes: 48,
                              milliseconds: 58, extractionMilliseconds: 34, seconds: 0.4,
                              detail: PrivacyToken(text),
                              error: SafeErrorSummary(MaliciousError())),
            PrivacyLog.face(.recognized, confidence: .high, candidates: 1, enrolled: 12,
                            error: SafeErrorSummary(MaliciousError())),
            PrivacyLog.homeBridge(.homeKit, .homesUpdated, status: 1, count: 3, attempt: 2,
                                  error: SafeErrorSummary(MaliciousError())),
            PrivacyLog.medical(.audit, .auditRecorded, operation: PrivacyToken(text),
                               count: 3, days: 30,
                               error: SafeErrorSummary(MaliciousError())),
            PrivacyLog.location(.geofenceEntered, count: 4,
                                error: SafeErrorSummary(MaliciousError())),
            PrivacyLog.proactiveAlert(.delivered, characters: text.count, count: 3,
                                      seconds: 60),
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
    /// The specific shape a caption or a spoken reply takes on its way to the log: a transcript
    /// goes in, a character count comes out. This is the canary the batch-2 domains are judged on,
    /// asserted end to end through the real methods rather than on the encoder alone.
    func testTranscriptSentinelSurvivesOnlyAsALength() {
        let spoken = Sentinel.transcript
        let caption = PrivacyEventEncoder.encode(
            PrivacyLog.speech(.ambientCaptions, .transcriptDelivered,
                              language: PrivacyToken("en-NZ"), characters: spoken.count))
        XCTAssertFalse(caption.contains("SENTINEL"), caption)
        XCTAssertFalse(caption.lowercased().contains("biopsy"), caption)
        XCTAssertTrue(caption.contains("characters=\(spoken.count)"), caption)
        XCTAssertTrue(caption.contains("language=en-NZ"), caption)

        let reply = PrivacyEventEncoder.encode(
            PrivacyLog.tts(.speaking, engine: PrivacyToken("elevenLabs"),
                           characters: spoken.count))
        XCTAssertFalse(reply.contains("SENTINEL"), reply)
        XCTAssertTrue(reply.contains("characters=\(spoken.count)"), reply)

        // Wake-word detection carries no text at all — not even a length, since the phrase that
        // matched is a fixed short string and its length would narrow the vocabulary.
        let wake = PrivacyEventEncoder.encode(PrivacyLog.wakeWord(.detected))
        XCTAssertEqual(wake, "[speech] wakeWord event=detected")
    }

    /// The batch-3 canary, on the two shapes the classification table calls regulated.
    ///
    /// A recognised name and a home entity id are the values these subsystems hold at the exact
    /// moment they log, and both used to be written out verbatim — `👤 Recognized: <name>` and
    /// `Fuzzy matched '<query>' → <entity> (name: <friendly name>)`. Neither has a parameter now,
    /// so the assertion is that the name cannot be passed at all: what comes back is the fact of
    /// a match, a confidence band, and how many people are enrolled.
    func testRegulatedNamesHaveNoParameterAtAll() {
        let recognition = PrivacyEventEncoder.encode(
            PrivacyLog.face(.recognized, confidence: .init(similarity: 0.91),
                            candidates: 1, enrolled: 12))
        XCTAssertFalse(recognition.contains("SENTINEL"), recognition)
        XCTAssertFalse(recognition.lowercased().contains("alvarez"), recognition)
        XCTAssertEqual(recognition,
                       "[vision] face event=recognized confidence=high count=1 total=12")

        // The ambiguous case names *several* people; it survives as how many were in contention.
        let ambiguous = PrivacyEventEncoder.encode(PrivacyLog.face(.ambiguous, candidates: 2,
                                                                   enrolled: 12))
        XCTAssertEqual(ambiguous, "[vision] face event=ambiguous count=2 total=12")

        // A home entity is low-entropy — a hash of "light.master_bedroom" is not anonymous — so
        // it is omitted rather than fingerprinted, and the event says only how it resolved.
        let resolved = PrivacyEventEncoder.encode(PrivacyLog.homeEntityResolved(.fuzzy))
        XCTAssertFalse(resolved.contains("SENTINEL"), resolved)
        XCTAssertFalse(resolved.contains("bedroom"), resolved)
        XCTAssertEqual(resolved, "[home] homeEntityResolved match=fuzzy")

        // Every event the home path can emit while it is holding `entityName`. None of them has
        // anywhere to put it — including as a fingerprint, which would not anonymise a dictionary
        // this small anyway. The count of entities is the one number that survives.
        let homeLines = [
            PrivacyLog.homeOperation(.callService, success: false),
            PrivacyLog.homeFallback(.toggle),
            PrivacyLog.homeEntityResolved(.unresolved),
            PrivacyLog.homeBridge(.homeAssistant, .catalogueRefreshed, count: 42),
        ].map(PrivacyEventEncoder.encode)
        for line in homeLines {
            XCTAssertFalse(line.contains(Sentinel.entityName), line)
            XCTAssertFalse(line.contains("SENTINEL"), line)
            XCTAssertFalse(line.contains("#"),
                           "an entity must not be smuggled in as a fingerprint either: \(line)")
        }
        XCTAssertTrue(homeLines.last?.contains("count=42") == true, "\(homeLines)")
    }

    /// The similarity score is a biometric measurement, so it is banded before it is logged.
    func testFaceConfidenceIsABandNotAScore() {
        XCTAssertEqual(PrivacyLog.FaceConfidence(similarity: 0.42), .low)
        XCTAssertEqual(PrivacyLog.FaceConfidence(similarity: 0.71), .medium)
        XCTAssertEqual(PrivacyLog.FaceConfidence(similarity: 0.97), .high)
        let line = PrivacyEventEncoder.encode(
            PrivacyLog.face(.recognized, confidence: .init(similarity: 0.8421)))
        XCTAssertFalse(line.contains("0.84"), "the raw similarity must not reach the log: \(line)")
    }

    /// A model configuration name is wearer-authored; a model id is a catalog name. The pair has
    /// to come out on opposite sides of the classification in the same line.
    func testModelIdIsKeptWhileConfigurationNameIsFingerprinted() {
        let line = PrivacyEventEncoder.encode(
            PrivacyLog.model(.turnStarted, provider: PrivacyToken("anthropic"),
                             model: PrivacyToken("claude-opus-4"),
                             configuration: PrivateIdentifier("Dr Alvarez clinic notes")))
        XCTAssertTrue(line.contains("model=claude-opus-4"), line)
        XCTAssertFalse(line.contains("Alvarez"), line)
        XCTAssertTrue(line.contains("configuration=#"), line)
    }

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

    /// P1 batch 1 — the authentication / networking / gateway / MCP / stream tier.
    ///
    /// Unlike the P0 list, these are asserted to contain *no* direct log call at all. The batch's
    /// stated target is zero for exactly these paths, and the checked-in ledger baseline says the
    /// same thing, so a regression here shows up as a failing test before it shows up as a number
    /// creeping back into the ledger.
    private static let batchOneFiles = [
        "OpenGlasses/Sources/Services/OpenClawBridge.swift",
        "OpenGlasses/Sources/Services/OpenClawEventClient.swift",
        "OpenGlasses/Sources/Services/MCPClient.swift",
        "OpenGlasses/Sources/Services/MCP/MCPTransport.swift",
        "OpenGlasses/Sources/Services/MCPServer/MCPGlassesServer.swift",
        "OpenGlasses/Sources/Services/KeychainService.swift",
        "OpenGlasses/Sources/Utils/Config.swift",
        "OpenGlasses/Sources/Services/ModelFetcher.swift",
        "OpenGlasses/Sources/Services/WebRTCStreamingService.swift",
        "OpenGlasses/Sources/Services/Display/WebHUD/WebHUDMirrorServer.swift",
        "OpenGlasses/Sources/Services/FieldAssist/WebRTCPeerTransport.swift",
        "OpenGlasses/Sources/Services/FieldAssist/ExpertStreamTransport.swift",
        "OpenGlasses/Sources/Services/FieldAssist/ExpertBridge.swift",
        "OpenGlasses/Sources/Services/FieldAssist/EscalationCoordinator.swift",
    ]

    /// P1 batch 2 — conversation / model / audio. Same contract as batch 1: zero direct log
    /// calls, and the file must be emitting typed events instead.
    ///
    /// `WakeWordService` and `LLMService` are the two that matter most here. The first logged the
    /// recognised transcript on five separate paths (stop command, both barge-in kinds, detection,
    /// fuzzy match) plus the persona names and every configured wake phrase; the second logged the
    /// model's reasoning trace, provider error bodies, and the on-device tool call with its
    /// arguments.
    private static let batchTwoFiles = [
        "OpenGlasses/Sources/Services/WakeWordService.swift",
        "OpenGlasses/Sources/Services/LLMService.swift",
        "OpenGlasses/Sources/Services/TextToSpeechService.swift",
        "OpenGlasses/Sources/Services/Audio/RealtimeAudioEngine.swift",
        "OpenGlasses/Sources/Services/Audio/AudioSessionCoordinator.swift",
        "OpenGlasses/Sources/Services/Audio/AudioSessionActivator.swift",
        "OpenGlasses/Sources/Services/GeminiLive/GeminiLiveSessionManager.swift",
        "OpenGlasses/Sources/Services/GeminiLive/GeminiLiveModelCatalog.swift",
        "OpenGlasses/Sources/Services/GeminiLive/FrameThrottler.swift",
        "OpenGlasses/Sources/Services/OpenAIRealtime/OpenAIRealtimeSessionManager.swift",
        "OpenGlasses/Sources/Services/LocalLLMService.swift",
        "OpenGlasses/Sources/Services/LLM/ToolLoopDriver.swift",
        "OpenGlasses/Sources/Services/ConversationStore.swift",
        "OpenGlasses/Sources/Services/ConversationEncryptionService.swift",
        "OpenGlasses/Sources/Services/TranscriptionService.swift",
        "OpenGlasses/Sources/Services/AmbientCaptionService.swift",
        "OpenGlasses/Sources/Services/LiveTranslationService.swift",
        "OpenGlasses/Sources/Services/Translation/OnDeviceTranslationProvider.swift",
        "OpenGlasses/Sources/Services/Translation/GeminiTranslationProvider.swift",
        "OpenGlasses/Sources/Services/ASR/OnDeviceASREngine.swift",
        "OpenGlasses/Sources/Services/Diarization/DeepgramSTTService.swift",
        "OpenGlasses/Sources/Services/MemoryRewindService.swift",
        "OpenGlasses/Sources/Services/MeetingAssistantService.swift",
        "OpenGlasses/Sources/Services/IntentClassifier.swift",
        "OpenGlasses/Sources/Services/BackgroundVoiceService.swift",
        "OpenGlasses/Sources/Services/AudioRecordingService.swift",
        "OpenGlasses/Sources/Services/AudioCapture/StandaloneMicTapService.swift",
        "OpenGlasses/Sources/Services/AudioCapture/CaptureAudioRouter.swift",
        "OpenGlasses/Sources/Services/AudioCapture/CaptureAudioNormalizer.swift",
        "OpenGlasses/Sources/Services/NativeTools/NativeToolRouter.swift",
        "OpenGlasses/Sources/Services/NativeTools/ToolAuthorizationEventLog.swift",
        "OpenGlasses/Sources/Services/NativeTools/WebSearchTool.swift",
        "OpenGlasses/Sources/Services/Teleprompter/TeleprompterScriptStore.swift",
        "OpenGlasses/Sources/Services/BroadcastChat/TwitchChatClient.swift",
        "OpenGlasses/Sources/Services/BroadcastChat/BroadcastChatReadbackService.swift",
    ]

    /// P1 batch 3 — vision / home / medical / location. The strictest batch: every one of these
    /// files holds a value the classification table calls regulated at the moment it logs.
    ///
    /// `MetaCameraBackend` is the bulk of it and the least sensitive part — DAT session and
    /// stream plumbing, which is public operation class and stays, in typed form, because it is
    /// the hardest thing in the app to diagnose without a device. The sensitive ones are small:
    /// `FaceRecognitionService` printed the name it had just recognised, `HomeAssistantEntityCache`
    /// printed the matched entity and its friendly name, `LocationService` printed the
    /// reverse-geocoded place, `ProactiveAlertService` printed the whole spoken alert, and
    /// `HIPAAComplianceService` mirrored every audit line — action *and* detail — into the device
    /// log, where none of the audit store's protection applies.
    private static let batchThreeFiles = [
        "OpenGlasses/Sources/Services/Camera/MetaCameraBackend.swift",
        "OpenGlasses/Sources/Services/CameraService.swift",
        "OpenGlasses/Sources/Services/PhoneVideoSource.swift",
        "OpenGlasses/Sources/Services/PhoneCameraSource.swift",
        "OpenGlasses/Sources/Services/VideoDecoder.swift",
        "OpenGlasses/Sources/App/Views/PhoneCameraView.swift",
        "OpenGlasses/Sources/Services/PrivacyFilterService.swift",
        "OpenGlasses/Sources/Services/GlassesPhotoAlbum.swift",
        "OpenGlasses/Sources/Services/NativeTools/CapturePhotoTool.swift",
        "OpenGlasses/Sources/Services/NativeTools/LookCloselyTool.swift",
        "OpenGlasses/Sources/Services/NativeTools/DocumentScanTool.swift",
        "OpenGlasses/Sources/Services/SignLanguage/FingerspellingSessionService.swift",
        "OpenGlasses/Sources/Services/Accessibility/OCRService.swift",
        "OpenGlasses/Sources/Services/Accessibility/SceneNarrationService.swift",
        "OpenGlasses/Sources/Services/Accessibility/NavigationAssistService.swift",
        "OpenGlasses/Sources/Services/Accessibility/AssistiveModeService.swift",
        "OpenGlasses/Sources/Services/LiveCoachService.swift",
        "OpenGlasses/Sources/Services/FaceRecognitionService.swift",
        "OpenGlasses/Sources/Services/NativeTools/HomeKitTool.swift",
        "OpenGlasses/Sources/Services/HomeAssistantEntityCache.swift",
        "OpenGlasses/Sources/Services/ProactiveAlertService.swift",
        "OpenGlasses/Sources/Services/HIPAAComplianceService.swift",
        "OpenGlasses/Sources/Services/MedicalExportService.swift",
        "OpenGlasses/Sources/Services/Medical/FHIRConfigurationStore.swift",
        "OpenGlasses/Sources/Services/SafetyAssessment/SafetyAssessmentStore.swift",
        "OpenGlasses/Sources/Services/HealthSafety/HealthSafetyAdvisor.swift",
        "OpenGlasses/Sources/Services/NativeTools/FitnessCoachingTool.swift",
        "OpenGlasses/Sources/Services/LocationService.swift",
        "OpenGlasses/Sources/Services/NativeTools/GeofenceTool.swift",
        "OpenGlasses/Sources/Services/Navigation/WalkingRouteService.swift",
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

    func testBatchOneFilesHaveNoDirectLogCalls() throws {
        for path in Self.batchOneFiles {
            let source = try sourceText(path)
            XCTAssertTrue(source.contains("PrivacyLog."),
                          "\(path): sanity — a migrated file should be emitting typed events")
            for line in loggingLines(in: source) {
                XCTFail("\(path): a direct log call survives in a migrated file:\n\(line)")
            }
            // The two-shape redactor is not authorisation to log a URL or a handshake body; the
            // gateway path used it and no longer may.
            XCTAssertFalse(source.contains("LogRedaction."),
                           "\(path): LogRedaction is export-diagnostics defence-in-depth, not a "
                               + "way to log content from a live network path")
        }
    }

    func testBatchTwoFilesHaveNoDirectLogCalls() throws {
        for path in Self.batchTwoFiles {
            let source = try sourceText(path)
            XCTAssertTrue(source.contains("PrivacyLog."),
                          "\(path): sanity — a migrated file should be emitting typed events")
            for line in loggingLines(in: source) {
                XCTFail("\(path): a direct log call survives in a migrated file:\n\(line)")
            }
            // `ToolLogContent.redacted` passed content straight through in DEBUG and shortened it
            // to a count in Release — the same "a redactor is not authorisation" trap
            // `LogRedaction` was. It is deleted; nothing may reintroduce a caller.
            XCTAssertFalse(source.contains("ToolLogContent"),
                           "\(path): ToolLogContent was removed — content goes to the log as a "
                               + "count through PrivacyLog, not through a debug passthrough")
        }
    }

    func testBatchThreeFilesHaveNoDirectLogCalls() throws {
        for path in Self.batchThreeFiles {
            let source = try sourceText(path)
            XCTAssertTrue(source.contains("PrivacyLog."),
                          "\(path): sanity — a migrated file should be emitting typed events")
            for line in loggingLines(in: source) {
                XCTFail("\(path): a direct log call survives in a migrated file:\n\(line)")
            }
        }
    }

    /// The names this batch is about, pinned by their identifiers rather than by a log statement:
    /// a recognised person, a home entity, a geocoded place and an accessory must not be formatted
    /// into anything the migrated files hand to `PrivacyLog`.
    func testRegulatedValuesAreNotPassedToTheFacade() throws {
        let forbidden: [(String, [String])] = [
            ("OpenGlasses/Sources/Services/FaceRecognitionService.swift",
             ["name", "names"]),
            ("OpenGlasses/Sources/Services/HomeAssistantEntityCache.swift",
             ["entityId", "friendlyName", "query"]),
            ("OpenGlasses/Sources/Services/LocationService.swift",
             ["geocodedPlace", "identifier"]),
            ("OpenGlasses/Sources/Services/NativeTools/HomeKitTool.swift",
             ["accessory", "deviceName"]),
            ("OpenGlasses/Sources/Services/NativeTools/GeofenceTool.swift",
             ["message", "reminder"]),
            ("OpenGlasses/Sources/Services/ProactiveAlertService.swift",
             ["message", "title", "notes"]),
            ("OpenGlasses/Sources/Services/HIPAAComplianceService.swift",
             ["detail", "lastPathComponent"]),
        ]
        for (path, values) in forbidden {
            let source = try sourceText(path)
            for call in privacyLogCalls(in: source) {
                // A *count* of a private value is the approved shape — `characters:
                // message.count` is the whole point — so `x.count` is removed before the search.
                // What must not survive is the value itself.
                let stripped = call.replacingOccurrences(
                    of: #"[A-Za-z0-9_?.]+\.count"#, with: "", options: .regularExpression)
                for value in values {
                    XCTAssertFalse(stripped.contains(value),
                                   "\(path): a privacy event is being handed '\(value)':\n\(call)")
                }
            }
        }
    }

    /// Every `PrivacyLog.…(…)` call in a file, as complete text including its continuation lines.
    /// A per-line scan would miss an argument that wrapped, which is exactly where a value would
    /// hide in this codebase's formatting.
    private func privacyLogCalls(in source: String) -> [String] {
        var calls: [String] = []
        var search = source.startIndex..<source.endIndex
        while let start = source.range(of: "PrivacyLog.", range: search) {
            var depth = 0
            var index = start.upperBound
            var opened = false
            while index < source.endIndex {
                let character = source[index]
                if character == "(" { depth += 1; opened = true }
                if character == ")" {
                    depth -= 1
                    if depth == 0 { break }
                }
                if !opened, character == "\n" { break }
                index = source.index(after: index)
            }
            let end = index < source.endIndex ? source.index(after: index) : source.endIndex
            calls.append(String(source[start.lowerBound..<end]))
            search = end..<source.endIndex
        }
        return calls
    }

    /// A path arrives from the network, so it is attacker-chosen text. It must be classified into
    /// the fixed endpoint set, never quoted into the rejection log.
    @MainActor
    func testUnknownServerPathIsClassifiedRatherThanQuoted() {
        let hostile = "/../../etc/passwd?token=SENTINELTOKEN"
        XCTAssertEqual(MCPGlassesServer.route(for: hostile), .unknown)
        XCTAssertEqual(MCPGlassesServer.route(for: "/see_glasses"), .seeGlasses)
        let line = PrivacyEventEncoder.encode(
            PrivacyLog.mcpServer(.requestRejected, route: MCPGlassesServer.route(for: hostile)))
        XCTAssertFalse(line.contains("SENTINEL"), line)
        XCTAssertTrue(line.contains("route=unknown"), line)
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
            // P1 batch 1: the gateway health probe logged the endpoint and the response body, the
            // connect path logged the handshake frame, and the notification path logged the text
            // that was about to be read aloud.
            ("OpenGlasses/Sources/Services/OpenClawBridge.swift",
             ["Health %@", "WS received:", "Sending connect:", "Task result:", "Task failed:"]),
            ("OpenGlasses/Sources/Services/OpenClawEventClient.swift",
             ["Invalid URL:", "Connecting to %@", "full response:", "Heartbeat notification:",
              "Cron result"]),
            ("OpenGlasses/Sources/Services/MCPClient.swift",
             ["blocked tool '", "quarantined tool '", "MCP egress "]),
            ("OpenGlasses/Sources/Services/MCPServer/MCPGlassesServer.swift",
             ["Rejected unauthorized", "(display) %@"]),
            ("OpenGlasses/Sources/Services/KeychainService.swift",
             ["read failed for %@", "write failed for %@"]),
            ("OpenGlasses/Sources/Services/WebRTCStreamingService.swift",
             ["streaming started:"]),
            ("OpenGlasses/Sources/Services/FieldAssist/ExpertBridge.swift",
             ["Paging expert pool"]),
            ("OpenGlasses/Sources/Services/FieldAssist/ExpertStreamTransport.swift",
             ["Streaming via %@"]),
            // P1 batch 2: the wake-word listener logged the recognised transcript on every path
            // that fired, plus the persona names and the full contextual-boost list; the LLM
            // service logged the reasoning trace, provider error bodies and the on-device tool
            // call with its arguments; TTS logged the sentence it was about to speak; the
            // translator logged both the utterance and its translation.
            ("OpenGlasses/Sources/Services/WakeWordService.swift",
             ["Stop command detected in:", "Barge-in (wake word):", "Barge-in (voice activity):",
              "Wake word detected:", "Fuzzy wake word match:", "Personas:"]),
            ("OpenGlasses/Sources/Services/LLMService.swift",
             ["🤖 Using model:", "Think: %@", "raw error response", "Local model tool call:",
              "Dropping malformed tool_call (no function.name): %@", "🧠 Cloud agent:"]),
            ("OpenGlasses/Sources/Services/TextToSpeechService.swift",
             ["TTS: Speaking", "ElevenLabs: Error", "Using voice"]),
            ("OpenGlasses/Sources/Services/LiveTranslationService.swift",
             ["→\\(targetLanguage)]"]),
            ("OpenGlasses/Sources/Services/AmbientCaptionService.swift",
             ["Artifact filter dropped caption: %@"]),
            ("OpenGlasses/Sources/Services/ASR/OnDeviceASREngine.swift",
             ["Artifact filter dropped transcript: %@"]),
            ("OpenGlasses/Sources/Services/TranscriptionService.swift",
             ["Transcription complete, sending:", "On-device transcription:"]),
            ("OpenGlasses/Sources/Services/NativeTools/NativeToolRouter.swift",
             ["Delegating to OpenClaw: %@(%@)", "succeeded in %.1fs: %@",
              "Confirmation required for %@: %@"]),
            ("OpenGlasses/Sources/Services/IntentClassifier.swift",
             ["RESPOND for: %@", "IGNORE for: %@", "Uncertain response: %@"]),
            ("OpenGlasses/Sources/Services/LocalLLMService.swift",
             ["think block: %d chars — %@"]),
            ("OpenGlasses/Sources/Services/ConversationStore.swift",
             ["Started thread %@ (project %@)"]),
            // P1 batch 3: the face recogniser printed the name it had just matched and every
            // name in an ambiguous tie; the Home Assistant cache printed the spoken query, the
            // matched entity id and its friendly name; HomeKit printed the accessory; the
            // location service printed the reverse-geocoded place; the geofence printed the
            // alert it was about to speak; the proactive alerter printed every alert and the
            // calendar title behind a playbook; and the HIPAA audit trail mirrored its own
            // detail line into the device log.
            ("OpenGlasses/Sources/Services/FaceRecognitionService.swift",
             ["👤 Recognized:", "👤 Ambiguous:"]),
            ("OpenGlasses/Sources/Services/HomeAssistantEntityCache.swift",
             ["Fuzzy matched"]),
            ("OpenGlasses/Sources/Services/NativeTools/HomeKitTool.swift",
             ["Read before write failed for %@"]),
            ("OpenGlasses/Sources/Services/LocationService.swift",
             ["📍 Location: ", "Region monitoring failed for"]),
            ("OpenGlasses/Sources/Services/NativeTools/GeofenceTool.swift",
             ["Geofence triggered:"]),
            ("OpenGlasses/Sources/Services/ProactiveAlertService.swift",
             ["[ProactiveAlerts] %@", "Auto-created playbook from"]),
            ("OpenGlasses/Sources/Services/HIPAAComplianceService.swift",
             ["[HIPAA Audit] %@: %@", "Protected file: %@", "Failed to purge %@"]),
            ("OpenGlasses/Sources/Services/HealthSafety/HealthSafetyAdvisor.swift",
             ["from speech: %@"]),
            ("OpenGlasses/Sources/Services/Accessibility/SceneNarrationService.swift",
             ["Refused — %@", "Camera claim failed — %@"]),
            ("OpenGlasses/Sources/Services/Camera/MetaCameraBackend.swift",
             ["Creating session bound to device %@", "📸 Photo captured:"]),
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

        // A file no batch has reached yet, so the line scanner must find something in it. If this
        // ever goes to zero legitimately (batch 4 covers it), move the anchor rather than delete
        // the check — an empty result would otherwise mean the matcher matches nothing at all.
        // It was `MetaCameraBackend` until batch 3 took that file to zero.
        let unmigrated = try sourceText("OpenGlasses/Sources/Services/SemanticMemoryStore.swift")
        XCTAssertFalse(loggingLines(in: unmigrated).isEmpty,
                       "sanity: this file still has direct NSLog lines, so the line scanner "
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
