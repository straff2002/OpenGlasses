import XCTest
@testable import OpenGlasses

/// Plan JM P2 — the cloud dictation gate, and the invariant it holds on the transports: audio of a
/// question leaves the phone only while every condition holds, and stops at once when one stops
/// holding mid-utterance. Fresh service instances with the gate injected — never the Keychain.
@MainActor
final class CloudDictationGateTests: XCTestCase {

    // MARK: - The pure rule

    func testEveryConditionMustHold() {
        for provider in CloudDictationProvider.allCases {
            for optedIn in [true, false] {
                for keyPresent in [true, false] {
                    for hipaa in [true, false] {
                        for pinnedOff in [true, false] {
                            for medical in [true, false] {
                                let allowed = CloudDictationGate.decide(
                                    provider: provider, preference: provider.preference, optedIn: optedIn,
                                    keyPresent: keyPresent, hipaa: hipaa, orgPinnedOff: pinnedOff,
                                    medicalAllows: medical)
                                XCTAssertEqual(allowed, optedIn && keyPresent && !hipaa && !pinnedOff && medical,
                                               "\(provider) opt=\(optedIn) key=\(keyPresent) hipaa=\(hipaa) pin=\(pinnedOff) med=\(medical)")
                            }
                        }
                    }
                }
            }
        }
    }

    func testOnlyTheChosenProviderIsConfigured() {
        for preference in ASREnginePreference.allCases {
            for provider in CloudDictationProvider.allCases {
                let allowed = CloudDictationGate.decide(provider: provider, preference: preference, optedIn: true,
                                                        keyPresent: true, hipaa: false, orgPinnedOff: false,
                                                        medicalAllows: true)
                XCTAssertEqual(allowed, preference == provider.preference, "\(preference) → \(provider)")
            }
        }
    }

    func testTheGateReadsItsInputsLiveEveryTime() {
        var hipaa = false
        let gate = Self.gate(hipaa: { hipaa })
        XCTAssertTrue(gate.isConfigured(provider: .deepgram))
        hipaa = true
        XCTAssertFalse(gate.isConfigured(provider: .deepgram), "a HIPAA flip is seen on the next read")
    }

    func testTheGateConsultsTheProvidersOwnRouteForTheMedicalRule() {
        var asked: [NetworkRoute] = []
        var gate = Self.gate()
        gate.medicalAllows = { asked.append($0); return true }
        _ = gate.isConfigured(provider: .deepgram)
        _ = gate.isConfigured(provider: .openAI)
        XCTAssertEqual(asked, [.deepgramDictation, .openAIDictation])
    }

    func testProviderMapping() {
        XCTAssertEqual(CloudDictationProvider(engine: .deepgram), .deepgram)
        XCTAssertEqual(CloudDictationProvider(engine: .openAI), .openAI)
        XCTAssertNil(CloudDictationProvider(engine: .appleSpeech))
        XCTAssertNil(CloudDictationProvider(engine: .onDevice))
        XCTAssertEqual(CloudDictationProvider.deepgram.route, .deepgramDictation)
        XCTAssertEqual(CloudDictationProvider.openAI.route, .openAIDictation)
    }

    // MARK: - Deepgram: the per-buffer invariant

    private static let someAudio = Data(repeating: 0, count: 320)

    func testDeepgramStartRefusesWhenTheGateIsClosed() {
        let service = DeepgramDictationService()
        service.isAllowed = { false }   // e.g. HIPAA mode on
        XCTAssertFalse(service.start(vocabulary: ["R-410A"]))
        XCTAssertEqual(service.state, .idle)
    }

    func testDeepgramStartArmsWhenTheGateIsOpen() {
        let service = DeepgramDictationService()
        service.isAllowed = { true }
        XCTAssertTrue(service.start(vocabulary: []))
        XCTAssertEqual(service.state, .armed, "the socket waits for the first buffer's sample rate")
    }

    func testAMidUtteranceFlipStopsTheStreamOnTheNextBuffer() {
        let service = DeepgramDictationService()
        var allowed = true
        var stopped: [String] = []
        service.isAllowed = { allowed }
        service.onStopped = { stopped.append($0) }
        XCTAssertTrue(service.start(vocabulary: []))

        // HIPAA flips on (or the choice is revoked, or a pin lands) while the wearer is speaking.
        allowed = false
        service.sendAudio(Self.someAudio, sampleRate: 16_000)
        XCTAssertEqual(service.state, .idle, "the first buffer after the flip tears the stream down")
        XCTAssertEqual(stopped, ["gateClosed"], "the caller is told, so the turn ends with what was heard")

        // Later buffers stay inert.
        service.sendAudio(Self.someAudio, sampleRate: 16_000)
        XCTAssertEqual(service.state, .idle)
        XCTAssertEqual(stopped.count, 1)
    }

    func testThePerBufferCheckUsesTheGateItself() {
        // The service's default gate is the live CloudDictationGate; here the injected gate is a real
        // CloudDictationGate over closures, flipped between buffers exactly as the app would.
        var hipaa = false
        let gate = Self.gate(hipaa: { hipaa })
        let service = DeepgramDictationService()
        service.isAllowed = { gate.isConfigured(provider: .deepgram) }
        XCTAssertTrue(service.start(vocabulary: []))
        hipaa = true
        service.sendAudio(Self.someAudio, sampleRate: 48_000)
        XCTAssertEqual(service.state, .idle)
    }

    func testSendAudioIsInertWhenNeverArmed() {
        let service = DeepgramDictationService()
        var stopped = 0
        service.isAllowed = { false }
        service.onStopped = { _ in stopped += 1 }
        service.sendAudio(Self.someAudio, sampleRate: 16_000)
        XCTAssertEqual(service.state, .idle)
        XCTAssertEqual(stopped, 0)
    }

    func testNoKeyStopsBeforeASocketIsBuilt() {
        let service = DeepgramDictationService()
        var stopped: [String] = []
        service.isAllowed = { true }
        service.apiKey = { "" }
        service.onStopped = { stopped.append($0) }
        XCTAssertTrue(service.start(vocabulary: []))
        service.sendAudio(Self.someAudio, sampleRate: 16_000)
        XCTAssertEqual(service.state, .idle)
        XCTAssertEqual(stopped, ["notConfigured"])
    }

    func testFinishWithoutASocketReturnsAtOnce() async {
        let service = DeepgramDictationService()
        service.isAllowed = { true }
        XCTAssertTrue(service.start(vocabulary: []))
        let text = await service.finish(closeTimeout: 5)
        XCTAssertEqual(text, "")
        XCTAssertEqual(service.state, .idle)
    }

    // MARK: - The Deepgram transcript

    func testInterimsReplaceEachOtherAndFinalsAccumulate() {
        var transcript = DeepgramDictationTranscript()
        transcript.apply(text: "what's the", isFinal: false)
        XCTAssertEqual(transcript.text, "what's the")
        transcript.apply(text: "what's the charge", isFinal: false)
        XCTAssertEqual(transcript.text, "what's the charge")
        transcript.apply(text: "What's the charge", isFinal: true)
        XCTAssertEqual(transcript.text, "What's the charge")
        transcript.apply(text: "on this unit", isFinal: false)
        XCTAssertEqual(transcript.text, "What's the charge on this unit")
        transcript.apply(text: "on this unit?", isFinal: true)
        XCTAssertEqual(transcript.text, "What's the charge on this unit?")
        XCTAssertEqual(transcript.finals.count, 2)
    }

    func testAnInterimWithoutItsFinalIsStillDelivered() {
        var transcript = DeepgramDictationTranscript()
        transcript.apply(text: "Check the", isFinal: true)
        transcript.apply(text: "superheat", isFinal: false)
        XCTAssertEqual(transcript.text, "Check the superheat",
                       "the socket closed before the last final: never less than the screen showed")
    }

    func testAnEmptyFinalClearsTheInterimAndAddsNothing() {
        var transcript = DeepgramDictationTranscript()
        transcript.apply(text: "um", isFinal: false)
        transcript.apply(text: "  ", isFinal: true)
        XCTAssertTrue(transcript.isEmpty)
    }

    // MARK: - OpenAI: the per-request invariant

    func testOpenAIUploadIsRefusedWhenTheGateIsClosedAndNothingIsSent() async {
        let service = OpenAIDictationService()
        var sent = 0
        service.isAllowed = { false }
        service.apiKey = { "sk-test-invented" }
        service.send = { request in sent += 1; return (Data(), URLResponse()) }
        do {
            _ = try await service.transcribe(samples: [0.1, 0.2], sampleRate: 16_000, vocabulary: [])
            XCTFail("the upload was allowed with the gate closed")
        } catch {
            XCTAssertEqual(error as? OpenAIDictationError, .notAllowed)
        }
        XCTAssertEqual(sent, 0)
    }

    func testOpenAIUploadNeedsAKey() async {
        let service = OpenAIDictationService()
        var sent = 0
        service.isAllowed = { true }
        service.apiKey = { "" }
        service.send = { _ in sent += 1; return (Data(), URLResponse()) }
        do {
            _ = try await service.transcribe(samples: [0.1], sampleRate: 16_000, vocabulary: [])
            XCTFail("an upload without a key")
        } catch {
            XCTAssertEqual(error as? OpenAIDictationError, .noKey)
        }
        XCTAssertEqual(sent, 0)
    }

    func testOpenAIUploadRefusesAnOverlongQuestion() async {
        let service = OpenAIDictationService()
        service.isAllowed = { true }
        service.apiKey = { "sk-test-invented" }
        service.send = { _ in XCTFail("sent"); return (Data(), URLResponse()) }
        let tooMany = [Float](repeating: 0, count: Int(OpenAIDictationRequest.maxSeconds * 1_000) + 1_000)
        do {
            _ = try await service.transcribe(samples: tooMany, sampleRate: 1_000, vocabulary: [])
            XCTFail("an overlong upload")
        } catch {
            XCTAssertEqual(error as? OpenAIDictationError, .tooLong)
        }
    }

    func testOpenAIUploadReturnsTheTranscriptAndNamesAFailureByStatusOnly() async throws {
        let service = OpenAIDictationService()
        service.isAllowed = { true }
        service.apiKey = { "sk-test-invented" }
        var lastRequest: URLRequest?
        service.send = { request in
            lastRequest = request
            let ok = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(#"{"text":" Torque the flare nut. "}"#.utf8), ok)
        }
        let text = try await service.transcribe(samples: [Float](repeating: 0.01, count: 4_800),
                                                sampleRate: 48_000, vocabulary: ["flare nut"])
        XCTAssertEqual(text, "Torque the flare nut.")
        service.send = { request in
            let ok = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(#"{"text":"Replace the XR7720 contactor.","languages":["en"]}"#.utf8), ok)
        }
        let code = try await service.transcribe(samples: [Float](repeating: 0.01, count: 4_800),
                                                sampleRate: 48_000, vocabulary: ["XR-7720"])
        XCTAssertEqual(code, "Replace the XR-7720 contactor.", "the vocabulary's spelling comes back")
        XCTAssertEqual(lastRequest?.url, OpenAIDictationRequest.url)
        XCTAssertEqual(lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test-invented")

        service.send = { request in
            let refused = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (Data(#"{"error":{"message":"secret detail"}}"#.utf8), refused)
        }
        do {
            _ = try await service.transcribe(samples: [0.1], sampleRate: 16_000, vocabulary: [])
            XCTFail("a 401 was accepted")
        } catch let error as OpenAIDictationError {
            XCTAssertEqual(error, .http(401))
            XCTAssertEqual(error.token, "http401")
            XCTAssertFalse((error.errorDescription ?? "").contains("secret detail"), "never the response body")
        }
    }

    // MARK: - Helpers

    private static func gate(hipaa: @escaping () -> Bool = { false }) -> CloudDictationGate {
        CloudDictationGate(preference: { .deepgram },
                           optedIn: { true },
                           keyPresent: { _ in true },
                           hipaa: hipaa,
                           orgPinnedOff: { false },
                           medicalAllows: { _ in true })
    }
}
