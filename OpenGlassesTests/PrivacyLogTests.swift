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
        /// The batch-4 shapes: a document the wearer titled (which becomes a filename), and a
        /// memory the agent was asked to keep.
        static let documentTitle = "SENTINEL biopsy results — Dr Alvarez, March.pdf"
        static let memoryValue = "SENTINEL daughter's birthday is the 3rd of April"

        /// `entityName` is deliberately absent: it is identifier-shaped, so `PrivacyToken` keeps
        /// it — the type's stated limit, pinned by `testTokenIsAShapeFilterNotASecretDetector`.
        /// The protection for an entity id is that no method takes one, which is asserted
        /// directly in `testRegulatedNamesHaveNoParameterAtAll`.
        static let all = [transcript, toolArgs, url, secret, cookie, personName,
                          documentTitle, memoryValue]
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
            // P1 batch 4 — persistence / import / export.
            PrivacyLog.store(.jsonBlob, .salvaged, slot: PrivacyToken(text), scope: .persona,
                             count: 11, total: 14, characters: text.count,
                             bytes: text.utf8.count, detail: PrivacyToken(text),
                             error: SafeErrorSummary(MaliciousError())),
            PrivacyLog.transfer(.skillPack, .installed, item: PrivateIdentifier(text),
                                version: PrivacyToken(text), operation: PrivacyToken(text),
                                signed: false, count: 4, total: 9, attempt: 2,
                                bytes: text.utf8.count,
                                error: SafeErrorSummary(MaliciousError())),
            // P1 batch 5 — operational UI / device.
            PrivacyLog.recording(.finished, width: 1920, height: 1080, frameRate: 30,
                                 count: 5400, characters: text.count, seconds: 180,
                                 hertz: 48_000, channels: 1, success: true,
                                 detail: PrivacyToken(text),
                                 error: SafeErrorSummary(MaliciousError())),
            PrivacyLog.stream(.rtmpBroadcast, .bitrateAdjusted, detail: PrivacyToken(text),
                              count: 2, session: PrivateIdentifier(text), attempt: 1,
                              delaySeconds: 2, seconds: 30, width: 1280, height: 720,
                              frameRate: 30, bitrate: 2_500_000, measuredBitrate: 1_900_000,
                              bytes: 4096, error: SafeErrorSummary(MaliciousError())),
            PrivacyLog.device(.glasses, .registrationState, state: PrivacyToken(text),
                              command: PrivacyToken(text), item: PrivateIdentifier(text),
                              count: 2, minutes: 15, success: false,
                              error: SafeErrorSummary(MaliciousError())),
            PrivacyLog.agent(.scheduler, .taskCompleted, model: PrivacyToken(text),
                             priority: PrivacyToken(text), reason: PrivacyToken(text),
                             count: 3, characters: text.count, minutes: 30,
                             error: SafeErrorSummary(MaliciousError())),
            PrivacyLog.purchase(.failed, product: PrivacyToken(text), count: 2,
                                error: SafeErrorSummary(MaliciousError())),
            PrivacyLog.app(.turnClassified, detail: PrivacyToken(text),
                           state: PrivacyToken(text), tool: PrivacyToken(text),
                           model: PrivacyToken(text), item: PrivateIdentifier(text),
                           count: 4, characters: text.count, success: true,
                           error: SafeErrorSummary(MaliciousError())),
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

    /// The batch-4 canary, on the two shapes a store holds at the moment it logs.
    ///
    /// A document title is user content that becomes a *filename* — which is why "just log the
    /// path" is the persistent temptation in this tier and why no method takes one. A memory value
    /// is the fact the wearer asked to be kept; `SemanticMemoryStore` used to write the key and
    /// the value out on every single `remember`.
    func testStoredContentSurvivesOnlyAsShapeAndScope() {
        let ingest = PrivacyEventEncoder.encode(
            PrivacyLog.store(.ragDocuments, .ingested, count: 14,
                             characters: Sentinel.documentTitle.count,
                             detail: PrivacyToken("scan")))
        XCTAssertFalse(ingest.contains("SENTINEL"), ingest)
        XCTAssertFalse(ingest.lowercased().contains("biopsy"), ingest)
        XCTAssertFalse(ingest.contains(".pdf"), "a filename must not reach the log: \(ingest)")
        XCTAssertEqual(ingest, "[store] store store=ragDocuments event=ingested count=14 "
                       + "characters=\(Sentinel.documentTitle.count) detail=scan")

        // A remembered fact: the pool it went into survives, the key and the value do not — not
        // even fingerprinted, since a stable hash of "daughter's birthday" is that memory's name.
        let remembered = PrivacyEventEncoder.encode(
            PrivacyLog.store(.semanticMemory, .recordWritten, scope: .persona,
                             characters: Sentinel.memoryValue.count))
        XCTAssertFalse(remembered.contains("SENTINEL"), remembered)
        XCTAssertFalse(remembered.contains("birthday"), remembered)
        XCTAssertFalse(remembered.contains("#"),
                       "a memory must not be smuggled in as a fingerprint either: \(remembered)")
        XCTAssertEqual(remembered, "[store] store store=semanticMemory event=recordWritten "
                       + "scope=persona characters=\(Sentinel.memoryValue.count)")
    }

    /// The salvage path's canary, driven through the real `JSONStore` helper.
    ///
    /// A `DecodingError` quotes the JSON it choked on — that is what makes the corrupt-blob path
    /// the sharpest edge in this batch, because the blob *is* the records. The event that reports
    /// the salvage must say which slot and how many survived, and the summary built from the
    /// decode failure must reduce to a case name and a coding-path depth: never a key (a
    /// dictionary's keys are the wearer's own strings) and never the offending value.
    func testDecodeFailureOverSentinelJSONReportsOnlyCountsAndDepth() throws {
        struct Row: Codable, Equatable { let id: Int }

        let blob = Data("""
        [{"id":1},{"id":"\(Sentinel.documentTitle)"},{"id":3}]
        """.utf8)
        let backupDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PrivacyLogTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: backupDirectory) }

        let result = JSONStore.decodeArray(Row.self, from: blob, name: "conversations",
                                           backupDirectory: backupDirectory)
        guard case .recovered(let rows, let backup) = result else {
            return XCTFail("expected element-wise salvage, got \(result)")
        }
        XCTAssertEqual(rows, [Row(id: 1), Row(id: 3)])

        // The backup filename is the slot plus a timestamp — the preserved bytes carry the
        // sentinel, the name that points at them must not.
        XCTAssertFalse(backup?.lastPathComponent.contains("SENTINEL") ?? false,
                       "\(backup?.lastPathComponent ?? "nil")")

        // The event the salvage emits, and the summary of the failure that caused it.
        let salvage = PrivacyEventEncoder.encode(
            PrivacyLog.store(.jsonBlob, .salvaged, slot: PrivacyToken("conversations"),
                             count: rows.count, total: 3, detail: PrivacyToken("elements")))
        XCTAssertFalse(salvage.contains("SENTINEL"), salvage)
        XCTAssertEqual(salvage, "[store] store store=jsonBlob event=salvaged slot=conversations "
                       + "count=2 total=3 detail=elements")

        var decodeFailure: Error?
        do { _ = try JSONDecoder().decode([Row].self, from: blob) } catch { decodeFailure = error }
        let error = try XCTUnwrap(decodeFailure)
        let reported = PrivacyEventEncoder.encode(
            PrivacyLog.store(.jsonBlob, .readFailed, slot: PrivacyToken("conversations"),
                             error: SafeErrorSummary(error)))
        XCTAssertFalse(reported.contains("SENTINEL"), reported)
        XCTAssertFalse(reported.lowercased().contains("biopsy"), reported)
        XCTAssertFalse(reported.contains("id"),
                       "the coding path names a key, which in a dictionary blob is data: \(reported)")
        XCTAssertTrue(reported.contains("error=decoding(typeMismatch)#"), reported)
    }

    /// A coding path is a list of keys; only its length is safe to record.
    func testDecodingErrorReportsPathDepthNotPathKeys() {
        let context = DecodingError.Context(
            codingPath: [SentinelKey(stringValue: Sentinel.documentTitle),
                         SentinelKey(stringValue: "SENTINELCHILD")],
            debugDescription: "SENTINEL value 42")
        let summary = SafeErrorSummary(DecodingError.keyNotFound(
            SentinelKey(stringValue: "SENTINELMISSING"), context))
        XCTAssertEqual(summary.category, .decoding)
        XCTAssertFalse(summary.description.contains("SENTINEL"), summary.description)
        XCTAssertEqual(summary.description, "decoding(keyNotFound)#2")
    }

    /// A coding key whose name is the thing that must not be logged.
    private struct SentinelKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    /// SQLite's result codes are a fixed numeric vocabulary and are kept; `sqlite3_errmsg` is not,
    /// because on a prepare failure it quotes the SQL — and this app's SQL is where memory keys
    /// and document chunks live.
    func testSQLiteSummaryCarriesCodesNotMessages() {
        XCTAssertEqual(SafeErrorSummary.sqlite(code: 11, extended: 267).description,
                       "storage(sqlite.267)#11")
        XCTAssertEqual(SafeErrorSummary.sqlite(code: 14).description, "storage(sqlite)#14")
        let line = PrivacyEventEncoder.encode(
            PrivacyLog.store(.semanticMemory, .queryFailed, detail: PrivacyToken("prepare"),
                             error: .sqlite(code: 1, extended: 1)))
        XCTAssertFalse(line.contains("SENTINEL"), line)
        XCTAssertTrue(line.contains("error=storage(sqlite.1)#1"), line)
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

    /// P1 batch 4 — persistence / import / export / share. Same contract: zero direct log calls.
    ///
    /// The two that matter most are `SemanticMemoryStore`, which wrote every remembered key *and
    /// its value* to the device log on each `remember` and the agent's diary line on each write,
    /// and `AgentDocumentStore`, which logged the whole fact appended to the agent's memory
    /// document. `JSONStore` is the structural one: it is the salvage path every JSON-backed store
    /// funnels through, so a decode error quoted there would quote the records of all of them.
    private static let batchFourFiles = [
        "OpenGlasses/Sources/Services/Persistence/JSONStore.swift",
        "OpenGlasses/Sources/Services/SemanticMemoryStore.swift",
        "OpenGlasses/Sources/Services/AgentDocumentStore.swift",
        "OpenGlasses/Sources/Services/RAG/DocumentStore.swift",
        "OpenGlasses/Sources/Services/ClawHubService.swift",
        "OpenGlasses/Sources/Services/SkillPacks/SkillPackStore.swift",
        "OpenGlasses/Sources/Services/Reading/ReadingSessionStore.swift",
        "OpenGlasses/Sources/Services/Study/StudyStore.swift",
        "OpenGlasses/Sources/Services/PlaybookStore.swift",
        "OpenGlasses/Sources/Services/RecordedSessionStore.swift",
        "OpenGlasses/Sources/Services/RecordingFiler.swift",
        "OpenGlasses/Sources/Services/NativeTools/OperationJournal.swift",
        "OpenGlasses/Sources/Services/Offline/OfflineQueue.swift",
        "OpenGlasses/Sources/Services/Offline/SyncEngine.swift",
        "OpenGlasses/Sources/Services/Memory/ConversationIndex.swift",
        "OpenGlasses/Sources/Services/Memory/ConversationRecallCoordinator.swift",
        "OpenGlasses/Sources/Services/Brain/BrainStore.swift",
        "OpenGlasses/Sources/Services/Skills/EvolvedSkillStore.swift",
        "OpenGlasses/Sources/Services/Usage/UsageStore.swift",
        "OpenGlasses/Sources/Services/AgentDataExporter.swift",
        "OpenGlasses/Sources/Services/Siri/SpotlightIndexService.swift",
    ]

    /// P1 batch 5 — operational UI / device. The batch that took the ledger to zero.
    ///
    /// `OpenGlassesApp.swift` is the headline: 136 sites, of which most were progress narration
    /// and were deleted outright, and the rest carried the wearer's transcript, the assistant's
    /// answer, a direct tool call's result, the notification an agent was asked to triage, and
    /// the SDK credentials the launch path dumped from the Info.plist. The other named leaks:
    /// `ShortcutCallbackManager` printed 200 characters of a shortcut's output verbatim,
    /// `PersonaPickerSheet` printed the Field Assist **vault id** (which names a customer),
    /// `CarPlaySceneDelegate` printed a persona, a thread id, a playbook name and a tool result,
    /// and `BroadcastService` printed the RTMP destination and a prefix of the **stream key**.
    private static let batchFiveFiles = [
        "OpenGlasses/Sources/App/OpenGlassesApp.swift",
        "OpenGlasses/Sources/App/CarPlaySceneDelegate.swift",
        "OpenGlasses/Sources/App/Views/PersonaPickerSheet.swift",
        "OpenGlasses/Sources/App/Views/OnboardingView.swift",
        "OpenGlasses/Sources/App/Views/BottomControlBar.swift",
        "OpenGlasses/Sources/App/Views/AgenticFeaturesView.swift",
        "OpenGlasses/Sources/Services/BroadcastService.swift",
        "OpenGlasses/Sources/Services/VideoRecordingService.swift",
        "OpenGlasses/Sources/Services/AgentScheduler.swift",
        "OpenGlasses/Sources/Services/AgentNotificationQueue.swift",
        "OpenGlasses/Sources/Services/AgentHarness/AgentSessionService.swift",
        "OpenGlasses/Sources/Services/WatchConnectivityManager.swift",
        "OpenGlasses/Sources/Services/LiveActivityManager.swift",
        "OpenGlasses/Sources/Services/StoreKitService.swift",
        "OpenGlasses/Sources/Services/ShortcutCallbackManager.swift",
        "OpenGlasses/Sources/Services/GlassesConnectionService.swift",
        "OpenGlasses/Sources/Services/GlassesDisplayService.swift",
        "OpenGlasses/Sources/Services/WearablesBootstrap.swift",
        "OpenGlasses/Sources/Services/Device/MetaTelemetryBlock.swift",
        "OpenGlasses/Sources/Services/Triggers/MediaTriggerService.swift",
        "OpenGlasses/Sources/Models/HomeGridCatalog.swift",
        "OpenGlasses/Sources/Services/NativeTools/YieldToHumanTool.swift",
        "OpenGlasses/Sources/Services/NativeTools/PlaybookTool.swift",
        "OpenGlasses/Sources/Services/NativeTools/ShazamTool.swift",
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

    func testBatchFourFilesHaveNoDirectLogCalls() throws {
        for path in Self.batchFourFiles {
            let source = try sourceText(path)
            XCTAssertTrue(source.contains("PrivacyLog."),
                          "\(path): sanity — a migrated file should be emitting typed events")
            for line in loggingLines(in: source) {
                XCTFail("\(path): a direct log call survives in a migrated file:\n\(line)")
            }
            // `sqlite3_errmsg` quotes the statement it failed on, and this app interpolates memory
            // keys and document ids into SQL. The codes are the approved substitute.
            XCTAssertFalse(source.contains("sqlite3_errmsg"),
                           "\(path): a SQLite message quotes the failing statement — log "
                               + "sqlite3_errcode/sqlite3_extended_errcode instead")
        }
    }

    func testBatchFiveFilesHaveNoDirectLogCalls() throws {
        for path in Self.batchFiveFiles {
            let source = try sourceText(path)
            XCTAssertTrue(source.contains("PrivacyLog."),
                          "\(path): sanity — a migrated file should be emitting typed events")
            for line in loggingLines(in: source) {
                XCTFail("\(path): a direct log call survives in a migrated file:\n\(line)")
            }
        }
    }

    // MARK: - The global gate (P2.1 / P2.2)
    //
    // The ledger reached zero with batch 5, so the scan stops being a per-batch list and becomes
    // a property of the whole tree. This is the same contract `Scripts/check-privacy-logging.sh`
    // enforces in CI, run in-process: `Foundation.Process` is unavailable on iOS, so the suite
    // cannot shell out to the script from the simulator. Instead it re-implements the script's
    // three checks over the same sources and reads the same allowlist file, and a separate test
    // pins the script's default mode so the two halves cannot silently diverge.

    private func allSourceFiles() throws -> [String] {
        try FileManager.default
            .subpathsOfDirectory(atPath: Self.repoRoot.appendingPathComponent("OpenGlasses/Sources").path)
            .filter { $0.hasSuffix(".swift") }
            .map { "OpenGlasses/Sources/\($0)" }
            .sorted()
    }

    /// Paths exempted by `Scripts/privacy-logging-allowlist.txt`, and whether each carried a
    /// reason. The gate treats a reason-less entry as a failure, and so does this.
    private func allowlist() throws -> [(path: String, hasReason: Bool)] {
        let url = Self.repoRoot.appendingPathComponent("Scripts/privacy-logging-allowlist.txt")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .compactMap { raw in
                let trimmed = raw.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
                let path = String(trimmed.prefix(while: { $0 != "#" }))
                    .trimmingCharacters(in: .whitespaces)
                guard !path.isEmpty else { return nil }
                return (path, trimmed.contains("#"))
            }
    }

    /// No file under `OpenGlasses/Sources` may call `NSLog` or `print` directly.
    ///
    /// This is the check that makes every future PR inherit the gate with no list to update: a
    /// new file that logs directly fails here on the day it is written, whether or not anyone
    /// remembers Plan DM exists.
    func testNoProductionSourceLogsDirectly() throws {
        let exempt = Set(try allowlist().map(\.path))
        var offenders: [String] = []
        for path in try allSourceFiles() where !exempt.contains(path) {
            for line in loggingLines(in: try sourceText(path)) {
                offenders.append("\(path): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssertEqual(offenders, [],
                       "Production sources log through PrivacyLog's typed events. "
                           + "\(offenders.count) direct call(s):\n" + offenders.joined(separator: "\n"))
    }

    /// The two shapes that turn a diagnostic line into a leak, checked tree-wide rather than
    /// per batch. Vacuous while the tree has no direct log calls at all — deliberately so: it is
    /// the check that catches an allowlisted shim being handed content later.
    func testNoLogCallCarriesContentOrLocalizedDescription() throws {
        var offenders: [String] = []
        for path in try allSourceFiles() {
            for line in loggingLines(in: try sourceText(path)) {
                if line.contains("localizedDescription") {
                    offenders.append("\(path): localizedDescription — use SafeErrorSummary:\n\(line)")
                }
                for name in Self.contentNames where line.contains(name) {
                    offenders.append("\(path): interpolates '\(name)':\n\(line)")
                }
            }
        }
        XCTAssertEqual(offenders, [], offenders.joined(separator: "\n"))
    }

    /// Every allowlist entry is a privacy review flag, so every one must say why it exists.
    func testEveryAllowlistEntryCarriesAReason() throws {
        for entry in try allowlist() {
            XCTAssertTrue(entry.hasReason,
                          "\(entry.path) is allowlisted with no '# reason'. An unexplained "
                              + "exemption is what the allowlist exists to prevent.")
        }
    }

    /// The script and this file are two halves of one gate. If the script quietly reverted to
    /// report-only, CI would go green on a tree the suite still refuses — so the default mode is
    /// pinned here rather than trusted.
    func testTheGateScriptIsBlockingByDefault() throws {
        let script = try sourceText("Scripts/check-privacy-logging.sh")
        XCTAssertTrue(script.contains("MODE=\"gate\""),
                      "the scanner's default mode must be the blocking gate, not a report")
        XCTAssertTrue(script.contains("exit \"$failed\""),
                      "the gate must exit with its failure count")
        XCTAssertTrue(script.contains("--report"),
                      "the report-only mode must stay available for trending")
        XCTAssertFalse(script.contains("Report only — exiting 0. The gate lands with P2"),
                       "the P1 report-only banner must be gone")
    }

    /// The ledger stays checked in as the historical record, and it says zero.
    func testTheCheckedInLedgerReadsZero() throws {
        let ledger = try sourceText("docs/plans/DM-ledger-baseline.txt")
        XCTAssertTrue(ledger.contains("# TOTAL 0 sites across 0 files"),
                      "the ledger must record the migration's end state:\n\(ledger)")
    }

    /// `JSONStore` logs its `name` argument as a token, which is only sound because that argument
    /// is a slot from a fixed vocabulary at every call site. A store named from a document title
    /// would be identifier-shaped, so `PrivacyToken` would keep it — the type is a shape filter,
    /// not a secret detector. This is the check that keeps the assumption true.
    func testJSONStoreSlotNamesAreLiterals() throws {
        let sources = try FileManager.default
            .subpathsOfDirectory(atPath: Self.repoRoot.appendingPathComponent("OpenGlasses/Sources").path)
            .filter { $0.hasSuffix(".swift") }
            .map { "OpenGlasses/Sources/\($0)" }
        var callSites = 0
        for path in sources where path != "OpenGlasses/Sources/Services/Persistence/JSONStore.swift" {
            let source = try sourceText(path)
            guard source.contains("JSONStore.") else { continue }
            for line in source.split(separator: "\n").map(String.init) where line.contains("name: ") {
                guard line.contains("JSONStore.") else { continue }
                callSites += 1
                XCTAssertNotNil(line.range(of: #"name: "[a-z_]+""#, options: .regularExpression),
                                "\(path): JSONStore's slot name must be a literal, not a value:\n\(line)")
            }
        }
        XCTAssertGreaterThan(callSites, 5, "sanity: the scan should be finding the store's callers")
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
            // P1 batch 4: a stored record, and the filename it is kept under.
            ("OpenGlasses/Sources/Services/SemanticMemoryStore.swift",
             ["keyName", "value", "pid", "namespace"]),
            ("OpenGlasses/Sources/Services/AgentDocumentStore.swift",
             ["content", "trimmed", "filename", "lastPathComponent"]),
            ("OpenGlasses/Sources/Services/RAG/DocumentStore.swift",
             ["safeName", "dbURL", "path"]),
            ("OpenGlasses/Sources/Services/Persistence/JSONStore.swift",
             ["url", "lastPathComponent", "data"]),
            ("OpenGlasses/Sources/Services/RecordingFiler.swift",
             ["source", "destination", "folderURL", "lastPathComponent"]),
            ("OpenGlasses/Sources/Services/Offline/SyncEngine.swift", ["reason", "payload"]),
            ("OpenGlasses/Sources/Services/AgentDataExporter.swift",
             ["zipURL", "exportName", "lastPathComponent"]),
            // P1 batch 5: a stream key, a vault id in the clear, a scheduled task's title, a
            // notification body, a shortcut's output, and the recording's own file.
            ("OpenGlasses/Sources/Services/BroadcastService.swift",
             ["streamName", "connectionURL", "streamKey", "rtmpURL", "message", "reason"]),
            ("OpenGlasses/Sources/Services/VideoRecordingService.swift",
             ["lastPathComponent", "fileURL", "transcriptURL", "recordingTranscript",
              "outputURL", "writerFailure"]),
            ("OpenGlasses/Sources/Services/AgentScheduler.swift",
             ["task.name", "persona.name", "processed", "prompt"]),
            ("OpenGlasses/Sources/Services/AgentNotificationQueue.swift",
             ["personaName", "source", "spokenMessage"]),
            ("OpenGlasses/Sources/Services/ShortcutCallbackManager.swift",
             ["output", "url.host", "absoluteString"]),
            ("OpenGlasses/Sources/App/Views/PersonaPickerSheet.swift",
             ["persona.name", "procedure.id", "vaultName", "soulText"]),
            ("OpenGlasses/Sources/App/CarPlaySceneDelegate.swift",
             ["persona.name", "playbook.name", "result"]),
            ("OpenGlasses/Sources/Services/WatchConnectivityManager.swift",
             ["message[", "userInfo["]),
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
            // P1 batch 4: the memory store wrote every remembered key and its value, and each
            // diary line, into the device log; the agent document store logged the fact it had
            // just been asked to remember; the RAG store logged the title of every ingested
            // document; and the SQLite stores logged their file paths and `sqlite3_errmsg`,
            // which on a prepare failure quotes the statement that broke.
            ("OpenGlasses/Sources/Services/SemanticMemoryStore.swift",
             ["Persona: %@ = %@", "Global: %@ = %@", "Diary: %@", "Evicted (over budget): %@",
              "Cleared persona memories for %@", "prepare failed:", "step failed:"]),
            ("OpenGlasses/Sources/Services/AgentDocumentStore.swift",
             ["Memory appended: %@", "Saved %@: %d chars"]),
            ("OpenGlasses/Sources/Services/RAG/DocumentStore.swift",
             ["Ingested '%@'", "Failed to open database at %@"]),
            ("OpenGlasses/Sources/Services/Persistence/JSONStore.swift",
             ["Backed up undecodable %@ blob to %@", "file exists but read failed"]),
            ("OpenGlasses/Sources/Services/ClawHubService.swift",
             ["Installed skill: %@", "Uninstalled skill: %@"]),
            ("OpenGlasses/Sources/Services/SkillPacks/SkillPackStore.swift",
             ["Quarantined %d action(s) in %@: %@"]),
            ("OpenGlasses/Sources/Services/RecordedSessionStore.swift",
             ["Could not delete audio %@"]),
            ("OpenGlasses/Sources/Services/Offline/SyncEngine.swift",
             ["failed after %d attempts: %@", "permanently failed: %@"]),
            ("OpenGlasses/Sources/Services/AgentDataExporter.swift", ["Created: %@"]),
            // P1 batch 5: the app entry point dumped the SDK's Info.plist credentials at every
            // launch (a client token is a secret; the app id, team id and universal-link scheme
            // name the developer account and the app's own callback door), printed the wearer's
            // transcript, the assistant's answer, a direct tool call's result and the
            // notification an agent was asked to triage; the shortcut callback printed 200
            // characters of a shortcut's output; CarPlay printed a persona, a thread id, a
            // playbook name and a tool result; the persona sheet printed the Field Assist vault
            // id; and the broadcaster printed the RTMP destination and a prefix of the stream key.
            ("OpenGlasses/Sources/App/OpenGlassesApp.swift",
             ["Config clientTokenPresent", "Config teamID", "MetaAppID:", "Bundle ID:",
              "AppLinkURLScheme (Universal Link)", "MWDAT keys:",
              "📝 Transcription:", "(vision): \\(response)", "⚡ Direct tool call:",
              "Triaging notification", "Clarification received:", "Fix response:",
              "Held an utterance while a turn was in flight: %@",
              "Dropped a held utterance that went stale: %@",
              "📸 Photo + prompt:", "[SilentPhoto] Saved to %@", "📋 Devices changed:"]),
            ("OpenGlasses/Sources/Services/ShortcutCallbackManager.swift",
             ["Result: %@", "Error: %@"]),
            ("OpenGlasses/Sources/App/Views/PersonaPickerSheet.swift",
             ["Started session on %@", "Manually activated persona:"]),
            ("OpenGlasses/Sources/App/CarPlaySceneDelegate.swift",
             ["Resuming conversation \\(threadId)", "Activating playbook", "CarPlay: \\(result)"]),
            ("OpenGlasses/Sources/Services/BroadcastService.swift",
             ["Connecting to %@/%@", "Publishing as '%@'", "Nothing sent after %.0fs — %@",
              "Connection lost (%@)"]),
            ("OpenGlasses/Sources/Services/VideoRecordingService.swift",
             ["Transcript saved → %@", "Finished → %@", "Filed → %@", "Started (video+audio) →"]),
            ("OpenGlasses/Sources/Services/AgentScheduler.swift",
             ["Running task: %@", "Switched to persona: %@", "Task complete: %@"]),
            ("OpenGlasses/Sources/Services/AgentNotificationQueue.swift",
             ["Queued: %@", "Waiting for operator response (persona: %@)"]),
            ("OpenGlasses/Sources/Services/Device/MetaTelemetryBlock.swift",
             ["blocked SDK telemetry upload to %@"]),
            ("OpenGlasses/Sources/Services/WearablesBootstrap.swift",
             ["configure() failed — glasses features unavailable: %@"]),
            ("OpenGlasses/Sources/App/Views/OnboardingView.swift",
             ["Wearables SDK %@"]),
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

        // The line scanner must still match a direct log call, or every scan above passes
        // vacuously. Until batch 5 this was anchored on whichever file had not been migrated yet
        // (`MetaCameraBackend`, then `SemanticMemoryStore`, then `OpenGlassesApp`). The ledger is
        // now zero, so there is no such file left and the matcher is exercised against fixtures
        // instead — including the shapes it must *not* match.
        let fixture = """
        NSLog("plain")
        print("bare")
            NSLog("indented %@", x)
        // NSLog("a comment still counts — the scanner is deliberately blunt")
        stream.print("not a bare print")
        debugPrint("also not")
        sprint("nor this")
        let noise = 1
        """
        XCTAssertEqual(loggingLines(in: fixture).count, 4,
                       "the line scanner must match bare NSLog/print (and the comment the "
                           + "scanner deliberately over-reports), and nothing else")
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

    /// P2.4 — the content-logging label and the only method that could emit it are wholly inside
    /// the `#if DEBUG && ENABLE_CONTENT_LOGGING` region, and nothing outside `PrivacyLog` calls it.
    ///
    /// Together with the test above (the flag is defined in no checked-in configuration), that is
    /// a structural proof that a Release build compiles neither the method nor its format string:
    /// the compiler cannot emit what it never parses. **Stated limit:** this reasons about the
    /// source, not about a linked binary. A `strings`-over-the-Release-archive check would be the
    /// stronger statement, and it needs a Release build the unit suite does not have — P2.4 is
    /// recorded as shipped in this form, with that gap named rather than papered over.
    func testContentLoggingHatchIsConfinedToItsCompilationRegion() throws {
        let source = try sourceText("OpenGlasses/Sources/Utils/PrivacyLog.swift")
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        var guarded = false
        var sawRegion = false
        var strayLines: [String] = []
        for line in lines {
            if line.contains("#if DEBUG && ENABLE_CONTENT_LOGGING") {
                guarded = true
                sawRegion = true
                continue
            }
            if guarded, line.trimmingCharacters(in: .whitespaces) == "#endif" {
                guarded = false
                continue
            }
            guard !guarded else { continue }
            if line.contains("debugContent") || line.contains("CONTENT-LOG") {
                // The section comment above the region names it; a `//` line is prose, not code.
                guard line.trimmingCharacters(in: .whitespaces).hasPrefix("//") else {
                    strayLines.append(line)
                    continue
                }
            }
        }
        XCTAssertTrue(sawRegion, "PrivacyLog no longer guards its content hatch — check the #if")
        XCTAssertEqual(strayLines, [],
                       "the content-logging hatch escaped its compilation region:\n"
                           + strayLines.joined(separator: "\n"))

        // And nothing anywhere else may call it: a caller outside the region would fail to
        // compile in Release, which is a build break rather than a leak — but it would also mean
        // someone thought the hatch was usable.
        for path in try allSourceFiles()
        where path != "OpenGlasses/Sources/Utils/PrivacyLog.swift" {
            XCTAssertFalse(try sourceText(path).contains("debugContent"),
                           "\(path) references PrivacyLog.debugContent — the hatch is a local, "
                               + "uncommitted debugging aid, not an API")
        }
    }
}
