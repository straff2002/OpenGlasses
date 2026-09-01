import Combine
import UIKit
import XCTest
@testable import OpenGlasses

/// Plan DM P2.3 — adversarial canary fixtures, driven through the subsystems themselves.
///
/// `PrivacyLogTests` proves the *encoder* never emits supplied content: it calls every typed
/// method with a sentinel in every slot. That is a statement about the facade. This file is the
/// level above it, and it exists because the facade being safe is not the same claim as the app
/// using it safely: a live QR scan, a tool result, a decode failure or a callback URL could still
/// reach a log by some route the facade never sees.
///
/// So each probe below takes real app code — the function that *decides what to log* — feeds it
/// input carrying a recognisable canary, and asserts the structured event sink never received one.
/// The sink is `PrivacyLog`'s own tap, so what is inspected is the exact line the OS log got.
///
/// Adding a canary is one entry in `Canary.all`; adding a subsystem is one entry in `probes()`.
@MainActor
final class PrivacyCanaryTests: XCTestCase {

    // MARK: - The corpus
    //
    // Every canary contains the literal `CANARY`, so one assertion covers the whole corpus, and
    // each is shaped like the real thing it stands for. They are deliberately *identifier-shaped*
    // where that is the hostile case: `PrivacyToken` is a shape filter, not a secret detector
    // (`PrivacyLogTests.testTokenIsAShapeFilterNotASecretDetector` pins that), so a canary that
    // would survive the filter is exactly the one worth planting — it proves the protection is
    // "there is no parameter for this", not "the filter caught it".

    /// The corpus, at file scope so the export suite drives the same one.
    typealias Canary = PrivacyCanary

    /// A server error whose `localizedDescription` embeds a canary URL *and* its token, which is
    /// exactly the shape a networking or provider error takes in this app.
    private struct HostileServerError: LocalizedError {
        var errorDescription: String? {
            "POST \(Canary.url) failed — " + #"{"error":{"message":"CANARY-RESULT rejected"}}"#
        }
    }

    // MARK: - The sink

    /// Captures the encoded line of every event emitted while a probe runs.
    ///
    /// This is `PrivacyLog`'s own tap, added for the diagnostics ring (P3) and reused here, so
    /// the test reads precisely what the OS log received — not a re-encoding of the arguments a
    /// call site passed, which would be a test of the test.
    private final class EventSink: @unchecked Sendable {
        private let lock = NSLock()
        private var captured: [String] = []

        func record(_ line: String) {
            lock.lock()
            captured.append(line)
            lock.unlock()
        }

        var lines: [String] {
            lock.lock()
            defer { lock.unlock() }
            return captured
        }
    }

    private func capturing(_ body: () async throws -> Void) async rethrows -> [String] {
        let sink = EventSink()
        let token = PrivacyLog.addTap { _, line in sink.record(line) }
        defer { PrivacyLog.removeTap(token) }
        try await body()
        return sink.lines
    }

    /// The assertion every probe ends in: no canary, in any form, in any encoded event.
    private func assertNoCanary(_ lines: [String], _ subsystem: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        let joined = lines.joined(separator: "\n")
        XCTAssertFalse(joined.uppercased().contains(Canary.stem),
                       "\(subsystem) leaked a canary into the event sink:\n\(joined)",
                       file: file, line: line)
        for canary in Canary.all {
            XCTAssertFalse(joined.contains(canary),
                           "\(subsystem) leaked \(canary)", file: file, line: line)
        }
    }

    // MARK: - Probes

    /// One subsystem, driven with canary-bearing input.
    ///
    /// `expects` is a substring that must appear in the captured lines. Without it a probe that
    /// silently logged nothing would pass, which is the failure mode a leak test is most likely
    /// to acquire as the code around it changes.
    private struct Probe {
        let subsystem: String
        let expects: String
        let drive: () async throws -> Void
    }

    private func probes() -> [Probe] {
        [
            Probe(subsystem: "tool dispatch and result", expects: "toolRun") {
                let registry = NativeToolRegistry(locationService: LocationService())
                registry.register(HostileEchoTool())
                let router = NativeToolRouter(registry: registry)
                router.toolTimeoutSeconds = 5
                _ = await router.handleToolCall(
                    name: "leak_probe",
                    args: ["payload": Canary.toolArguments, "who": Canary.person])
            },

            Probe(subsystem: "tool failure", expects: "toolRun") {
                let registry = NativeToolRegistry(locationService: LocationService())
                registry.register(HostileThrowingTool())
                let router = NativeToolRouter(registry: registry)
                router.toolTimeoutSeconds = 5
                _ = await router.handleToolCall(name: "leak_probe_failing",
                                                args: ["payload": Canary.toolArguments])
            },

            Probe(subsystem: "tool authorization refusal", expects: "toolAuthorizationRefused") {
                let log = ToolAuthorizationEventLog()
                let call = ResolvedToolCall.root(
                    name: "send_message",
                    arguments: ToolArguments(["body": Canary.transcript, "to": Canary.person]),
                    origin: .model,
                    invocationID: Canary.secret)
                log.record(call: call, verdict: "refusedByPolicy")
            },

            Probe(subsystem: "QR context — refused scheme", expects: "qrFetchBlocked") {
                let tool = QRContextTool(cameraService: CameraService(backend: InertCameraBackend(),
                                                                      phoneCamera: InertPhoneCamera()))
                // The canary is the *scheme*, so it lands inside the rejection's payload — and
                // the rejection is `CustomStringConvertible`, naming what it refused.
                _ = try await tool.execute(args: ["url": "canary-7f3a-secret://intake/ctx?token=\(Canary.secret)"])
            },

            Probe(subsystem: "QR context — refused host", expects: "qrFetchBlocked") {
                let tool = QRContextTool(cameraService: CameraService(backend: InertCameraBackend(),
                                                                      phoneCamera: InertPhoneCamera()))
                _ = try await tool.execute(args: ["url": "http://192.168.13.7/ctx?visitor=CANARY-VISITOR-91&token=\(Canary.secret)"])
            },

            Probe(subsystem: "deep link route classification", expects: "deepLink") {
                // `privacyRoute` is the app's own classifier; the emit beside it is the app's own
                // statement. Driven together, this is the callback path as `onOpenURL` runs it.
                for raw in ["openglasses://shortcut-result?result=\(Canary.transcript)&token=\(Canary.secret)",
                            "openglasses://persona?name=\(Canary.person)",
                            "https://openglasses.app/wearables/callback?code=\(Canary.secret)",
                            Canary.url] {
                    guard let url = URL(string: raw.addingPercentEncoding(
                        withAllowedCharacters: .urlFragmentAllowed) ?? raw) else { continue }
                    PrivacyLog.deepLink(route: privacyRoute(for: url),
                                        source: PrivacyToken(url.scheme ?? "unknown"),
                                        verdict: .received)
                    PrivacyLog.deepLink(route: privacyRoute(for: url),
                                        source: PrivacyToken(url.scheme ?? "unknown"),
                                        verdict: .failed,
                                        error: SafeErrorSummary(HostileServerError()))
                }
            },

            Probe(subsystem: "captions", expects: "noteInserted") {
                AmbientCaptionService().insertVisualNote(Canary.transcript)
            },

            Probe(subsystem: "speech synthesis", expects: "[speech] tts") {
                // Glasses-only audio with no glasses connected is the one `speak` path that runs
                // the real entry point without producing audio, and it logs before returning.
                let previous = Config.glassesOnlyAudio
                Config.setGlassesOnlyAudio(true)
                defer { Config.setGlassesOnlyAudio(previous) }
                await TextToSpeechService().speak(Canary.transcript)
            },

            Probe(subsystem: "home bridge", expects: "[home] homeBridge") {
                let previousURL = Config.homeAssistantURL
                let previousToken = Config.homeAssistantToken
                defer {
                    Config.setHomeAssistantURL(previousURL)
                    Config.setHomeAssistantToken(previousToken)
                }
                // A closed local port: the fetch fails fast, and the failure carries the URL the
                // canary is in. `.notConfigured` is the same probe when the Keychain declines a
                // token in this environment — both are real paths through the same function.
                Config.setHomeAssistantURL("http://127.0.0.1:9/\(Canary.entity)")
                Config.setHomeAssistantToken(Canary.secret)
                await HomeAssistantEntityCache().refreshIfNeeded(force: true)
            },

            Probe(subsystem: "face database", expects: "[vision] face") {
                let store = FaceDatabaseFixture()
                defer { store.restore() }
                // A face DB full of canary-named people, loaded by the real service.
                store.write(#"[{"id":"CANARY-FACE-1","name":"\#(Canary.person)","faceprint":[0.1,0.2],"addedAt":0,"lastSeen":0}]"#)
                _ = FaceRecognitionService()
                // …and a corrupt one, so the decode failure runs too: a `DecodingError`'s own
                // description quotes the JSON it choked on.
                store.write(#"{"person":"\#(Canary.person)","note":"\#(Canary.medication)"}"#)
                _ = FaceRecognitionService()
            },

            Probe(subsystem: "JSON store salvage", expects: "[store] store") {
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("CanaryStore_\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }

                // A blob whose keys and values are the wearer's own strings, one record of which
                // is the wrong shape — the salvage path every JSON-backed store funnels into.
                let url = directory.appendingPathComponent("blob.json")
                let blob = """
                [{"title":"\(Canary.documentTitle)"},{"title":42},{"title":"\(Canary.medication)"}]
                """
                try Data(blob.utf8).write(to: url)
                _ = JSONStore.loadArray(ProbeRecord.self, at: url, name: "readingSessions",
                                        backupDirectory: directory)

                // And a blob that is not JSON at all, which backs itself up first.
                let broken = directory.appendingPathComponent("broken.json")
                try Data("\(Canary.transcript) — not json".utf8).write(to: broken)
                _ = JSONStore.loadDictionary(ProbeRecord.self, at: broken, name: "studyDecks",
                                             backupDirectory: directory)
                _ = JSONStore.backUp(Data(Canary.toolArguments.utf8), name: "usage",
                                     directory: directory)
            },

            Probe(subsystem: "clinical export", expects: "[transfer]") {
                let root = FileManager.default.temporaryDirectory
                    .appendingPathComponent("CanaryExport_\(UUID().uuidString)", isDirectory: true)
                defer { try? FileManager.default.removeItem(at: root) }
                let store = MedicalExportFileStore(root: root)
                let lease = try store.createLease(data: Data(Canary.medication.utf8),
                                                  format: .plainText,
                                                  displayName: Canary.documentTitle)
                store.release(lease)
                // The diagnostics bundle takes the same protected route (P3).
                let coordinator = DiagnosticExportCoordinator(
                    store: ProtectedExportFileStore(rootDirectoryName: "CanaryDiagnostics",
                                                    root: root.appendingPathComponent("diag")))
                let document = DiagnosticExportBuilder.build(entries: [], environment: .unknown)
                let bundle = try coordinator.makeLease(document: document,
                                                       displayName: Canary.documentTitle)
                coordinator.finishShare(bundle, outcome: .completed)
            },

            Probe(subsystem: "server errors at their call sites", expects: "[model] model") {
                // The four error shapes the classification table calls out, each summarised the
                // way its own subsystem summarises it.
                let urlError = URLError(.badServerResponse,
                                        userInfo: [NSURLErrorFailingURLStringErrorKey: Canary.url,
                                                   NSLocalizedDescriptionKey: Canary.url])
                PrivacyLog.model(.apiError, error: SafeErrorSummary(urlError))
                PrivacyLog.model(.streamError, error: SafeErrorSummary(HostileServerError()))
                PrivacyLog.gatewayFailed(.request, SafeErrorSummary(HostileServerError()))
                PrivacyLog.authFailed(.claude, .tokenRefresh,
                                      SafeErrorSummary(NSError(domain: Canary.secret, code: 401,
                                                               userInfo: [NSLocalizedDescriptionKey: Canary.url])))
                PrivacyLog.qrFetchBlocked(.refused(URLFetchGuard.Rejection.privateOrReservedHost(Canary.url)))
                PrivacyLog.realtimeError(.openai, phase: .receive,
                                         SafeErrorSummary(HostileServerError()))
                do {
                    _ = try JSONDecoder().decode([ProbeRecord].self,
                                                 from: Data(#"{"\#(Canary.person)":"\#(Canary.medication)"}"#.utf8))
                } catch {
                    PrivacyLog.store(.jsonBlob, .loadFailed, error: SafeErrorSummary(error))
                }
            },
        ]
    }

    // MARK: - The suite

    func testNoSubsystemLeaksACanary() async throws {
        for probe in probes() {
            let lines = try await capturing { try await probe.drive() }
            XCTAssertFalse(lines.isEmpty, "\(probe.subsystem) logged nothing — the probe is vacuous")
            XCTAssertTrue(lines.contains { $0.contains(probe.expects) },
                          "\(probe.subsystem) never reached \(probe.expects):\n\(lines.joined(separator: "\n"))")
            assertNoCanary(lines, probe.subsystem)
        }
    }

    /// The corpus itself has to be recognisable, or every assertion above is trivially true.
    func testEveryCanaryCarriesTheStem() {
        XCTAssertFalse(Canary.all.isEmpty)
        for canary in Canary.all {
            XCTAssertTrue(canary.uppercased().contains(Canary.stem), "\(canary) is not detectable")
        }
    }

    /// The sink has to be able to see a leak, or "no canary reached it" means nothing. A tap on
    /// a deliberately unfiltered line proves the capture path works end to end.
    func testTheSinkWouldCatchALeak() async {
        let lines = await capturing {
            // A tool *name* is public operation class and passes the vocabulary filter — which is
            // precisely why the corpus never plants a canary in one. Here it is planted on purpose.
            PrivacyLog.toolDispatch(.native, tool: Canary.secret)
        }
        XCTAssertTrue(lines.joined().contains(Canary.secret),
                      "the sink cannot observe what the encoder emits")
    }

    /// The canary that *does* survive, pinned rather than quietly avoided.
    ///
    /// Two slots take a short word from a vocabulary someone else defines: a tool's name, and a
    /// remote peer's machine-readable error code. `PrivacyToken` is a shape filter, so an
    /// identifier-shaped canary planted in one of those comes out the other side — which is why
    /// the corpus never plants one there, and why this test exists to say so out loud. The
    /// compensating control is structural: no call site builds either from a credential or from
    /// user text, and `Scripts/check-privacy-logging.sh` flags the ones that could.
    func testIdentifierShapedValuesInVocabularySlotsAreNotFilteredOut() async {
        let lines = await capturing {
            PrivacyLog.realtimeError(.openai, phase: .receive, .remote(code: Canary.secret))
        }
        XCTAssertTrue(lines.joined().contains(Canary.secret),
                      "if this ever stops being true, PrivacyToken has become a secret detector "
                          + "and its documented limit needs rewriting")
        // The peer's human-readable message, by contrast, has no parameter at all.
        let messages = await capturing {
            PrivacyLog.realtimeError(.openai, phase: .receive,
                                     SafeErrorSummary(HostileServerError()))
        }
        assertNoCanary(messages, "remote error message")
    }

    /// Removing a tap must actually stop it: a sink that outlived its probe would attribute one
    /// subsystem's events to another.
    func testTapsStopWhenRemoved() {
        var seen = 0
        let token = PrivacyLog.addTap { _, _ in seen += 1 }
        PrivacyLog.toolDispatch(.native, tool: "leak_probe")
        PrivacyLog.removeTap(token)
        PrivacyLog.toolDispatch(.native, tool: "leak_probe")
        XCTAssertEqual(seen, 1)
    }
}

// MARK: - Fixtures

/// Returns a canary-bearing result, and is called with canary-bearing arguments.
private struct HostileEchoTool: NativeTool {
    let name = "leak_probe"
    let description = "test fixture"
    let parametersSchema: [String: Any] = ["type": "object", "properties": [:] as [String: Any]]

    func execute(args: [String: Any]) async throws -> String {
        PrivacyCanaryTests.Canary.toolResult + " " + (args["payload"] as? String ?? "")
    }
}

/// Fails with an error whose description is the leak.
private struct HostileThrowingTool: NativeTool {
    let name = "leak_probe_failing"
    let description = "test fixture"
    let parametersSchema: [String: Any] = ["type": "object", "properties": [:] as [String: Any]]

    struct Boom: LocalizedError {
        var errorDescription: String? {
            "upstream refused \(PrivacyCanaryTests.Canary.url) for \(PrivacyCanaryTests.Canary.person)"
        }
    }

    func execute(args: [String: Any]) async throws -> String { throw Boom() }
}

/// A camera backend that does nothing. `QRContextTool` holds a `CameraService` it never reaches on
/// the URL path, and the real backend traps in a unit-test process.
private final class InertCameraBackend: GlassesCameraBackend {
    var capabilities: CameraCapabilities = .meta
    let events = PassthroughSubject<CameraBackendEvent, Never>()
    var permissionGranted = false

    func isReady(configuringIfNeeded: Bool) -> Bool { false }
    func ensurePermission() async throws {}
    func capturePhoto() async throws -> Data { Data() }
    func startStreaming() async throws {}
    func stopStreaming() async {}
    func tearDown() async {}
}

private final class InertPhoneCamera: PhoneCameraCapturing {
    func capturePhoto() async throws -> Data { Data() }
}

private struct ProbeRecord: Codable {
    let title: String
}

/// Swaps the face database out from under `FaceRecognitionService`, whose storage URL is the
/// documents directory, and puts the wearer's own file back afterwards.
@MainActor
private final class FaceDatabaseFixture {
    private let url: URL
    private let saved: Data?

    init() {
        url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("known_faces.json")
        saved = try? Data(contentsOf: url)
    }

    func write(_ json: String) {
        try? Data(json.utf8).write(to: url, options: .atomic)
    }

    func restore() {
        if let saved {
            try? saved.write(to: url, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

// MARK: - The corpus

/// The shared canary corpus: distinctive tokens shaped like the real things the
/// classification table forbids. File scope so `DiagnosticExportTests` plants the same ones.
enum PrivacyCanary {
    /// A credential, in the shape a bearer token actually takes.
    static let secret = "CANARY-7f3a-SECRET"
    /// A URL with both an identifier and a credential in its query.
    static let url = "https://intake.example.test/ctx?visitor=CANARY-VISITOR-91&token=CANARY-7f3a-SECRET"
    /// Something the wearer said.
    static let transcript = "CANARY-PHRASE remind me what the biopsy result was"
    /// A person the wearer enrolled.
    static let person = "Dr CANARY-PERSON Alvarez"
    /// A device in a named room of their house.
    static let entity = "light.CANARY_ENTITY_master_bedroom"
    /// A clinical value.
    static let medication = "CANARY-MED amoxicillin 500mg three times daily"
    /// A document they scanned — which becomes a filename.
    static let documentTitle = "CANARY-TITLE biopsy results, March.pdf"
    /// A tool call's arguments, as JSON.
    static let toolArguments = #"{"to":"CANARY-CONTACT@example.test","body":"CANARY-PHRASE meet at 8"}"#
    /// A tool's answer.
    static let toolResult = "CANARY-RESULT the front door is unlocked and Dr CANARY-PERSON Alvarez is in the hall"

    static let all: [String] = [secret, url, transcript, person, entity, medication,
                                documentTitle, toolArguments, toolResult]

    /// The single stem every canary shares. Asserting on it catches a partial leak — a
    /// truncated prefix, a percent-encoded fragment — that an equality check would miss.
    static let stem = "CANARY"
}

