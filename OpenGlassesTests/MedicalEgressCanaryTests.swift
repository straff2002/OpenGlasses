import AVFoundation
import XCTest
@testable import OpenGlasses

/// Counts every HTTP request that reaches the transport, and answers it locally so nothing is
/// actually sent. Registered for the duration of a canary test only.
///
/// This is the honest way to assert "no bytes left": a guard test that only checks the guard's own
/// return value proves the policy, not the wiring. Here the assertion is made below the service,
/// at the layer `URLSession` hands a request to.
final class EgressCanaryURLProtocol: URLProtocol, @unchecked Sendable {

    private static let lock = NSLock()
    nonisolated(unsafe) private static var requests: [URL] = []

    static func begin() {
        lock.lock(); requests = []; lock.unlock()
        URLProtocol.registerClass(EgressCanaryURLProtocol.self)
    }

    static func end() {
        URLProtocol.unregisterClass(EgressCanaryURLProtocol.self)
        lock.lock(); requests = []; lock.unlock()
    }

    static var seen: [URL] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    override class func canInit(with request: URLRequest) -> Bool {
        lock.lock()
        if let url = request.url { requests.append(url) }
        lock.unlock()
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}

/// Roadmap W04.2 — the synthetic canary.
///
/// Each probe drives a guarded service through its real request-construction point twice: once
/// with medical local-only on, asserting the transport saw nothing, and once with it off,
/// asserting the same drive does reach the transport. The second half is what stops a probe from
/// passing because the service was broken rather than because the guard worked.
@MainActor
final class MedicalEgressCanaryTests: XCTestCase {

    override func setUp() {
        super.setUp()
        EgressCanaryURLProtocol.begin()
    }

    override func tearDown() {
        EgressCanaryURLProtocol.end()
        MedicalEgressGuard.currentMode = Self.liveMode
        super.tearDown()
    }

    private static let liveMode: () -> MedicalEgressGuard.Mode = {
        MedicalEgressGuard.Mode(hipaaMode: Config.hipaaMode, localOnly: Config.hipaaLocalOnly)
    }

    private func setMode(_ mode: MedicalEgressGuard.Mode) {
        MedicalEgressGuard.currentMode = { mode }
    }

    // MARK: - Speech to text

    func testDeepgramBatchUploadNeverReachesTheTransportInLocalOnly() async {
        let service = DeepgramBatchService()
        let url = URL(string: "https://api.deepgram.com/v1/listen")!
        let audio = Data(repeating: 0x41, count: 512)

        setMode(.localOnly)
        do {
            _ = try await service.diarize(audioData: audio, mimeType: "audio/m4a", key: "k", url: url)
            XCTFail("the upload was allowed in local-only mode")
        } catch let refusal as MedicalEgressRefusal {
            XCTAssertEqual(refusal.route, .deepgramBatchTranscription)
        } catch {
            XCTFail("expected a MedicalEgressRefusal, got \(error)")
        }
        XCTAssertEqual(EgressCanaryURLProtocol.seen, [], "audio reached the transport")

        setMode(.off)
        _ = try? await service.diarize(audioData: audio, mimeType: "audio/m4a", key: "k", url: url)
        XCTAssertEqual(EgressCanaryURLProtocol.seen, [url],
                       "with the guard off the same drive must reach the transport")
    }

    /// The live socket is a `URLSessionWebSocketTask`, which no `URLProtocol` sees, so the probe
    /// asserts on the service's own connection state: `connected` is set on the line after the
    /// socket is built, so never reaching it is the same claim.
    func testDeepgramLiveSocketIsNeverBuiltInLocalOnly() {
        let service = DeepgramSTTService()
        service.isConfigured = { true }   // bypass the opt-in gate; the medical rule is the subject

        setMode(.localOnly)
        service.start()
        service.sendAudio(Self.silentBuffer())
        XCTAssertNotEqual(service.state, .connected, "the diarization socket opened in local-only mode")
        XCTAssertEqual(EgressCanaryURLProtocol.seen, [])
        service.stop()
    }

    // MARK: - Text to speech

    func testElevenLabsSynthesisNeverReachesTheTransportInLocalOnly() async {
        let service = TextToSpeechService()

        setMode(.localOnly)
        do {
            try await service.speakWithElevenLabs(text: "vitals are stable", apiKey: "canary-key")
            XCTFail("the synthesis request was allowed in local-only mode")
        } catch let refusal as MedicalEgressRefusal {
            XCTAssertEqual(refusal.route, .elevenLabsSpeechSynthesis)
        } catch {
            XCTFail("expected a MedicalEgressRefusal, got \(error)")
        }
        XCTAssertEqual(EgressCanaryURLProtocol.seen, [], "reply text reached the transport")

        setMode(.off)
        try? await service.speakWithElevenLabs(text: "vitals are stable", apiKey: "canary-key")
        XCTAssertEqual(EgressCanaryURLProtocol.seen.count, 1,
                       "with the guard off the same drive must reach the transport")
        XCTAssertEqual(EgressCanaryURLProtocol.seen.first?.host, "api.elevenlabs.io")
    }

    func testElevenLabsVoiceCatalogNeverReachesTheTransportInLocalOnly() async {
        setMode(.localOnly)
        do {
            _ = try await TextToSpeechService.fetchElevenLabsVoices(apiKey: "canary-key")
            XCTFail("the voice catalog request was allowed in local-only mode")
        } catch let refusal as MedicalEgressRefusal {
            XCTAssertEqual(refusal.route, .elevenLabsVoiceCatalog)
        } catch {
            XCTFail("expected a MedicalEgressRefusal, got \(error)")
        }
        XCTAssertEqual(EgressCanaryURLProtocol.seen, [])

        setMode(.off)
        _ = try? await TextToSpeechService.fetchElevenLabsVoices(apiKey: "canary-key")
        XCTAssertEqual(EgressCanaryURLProtocol.seen.count, 1)
    }

    // MARK: - Helpers

    private static func silentBuffer(sampleRate: Double = 16_000, frames: AVAudioFrameCount = 160) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                   channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        return buffer
    }
}
