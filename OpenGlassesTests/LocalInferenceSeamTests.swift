import XCTest
@testable import OpenGlasses

/// Plan DZ P0 — conformance tests for the backend-neutral seam, driven entirely through a fake
/// backend.
///
/// A fake is the right instrument here and not a compromise: every rule the coordinator exists to
/// enforce is about *ordering and exclusivity* between backends, and those are invisible when the
/// only backend is the real one — you cannot ask MLX to be resident twice, and you cannot observe
/// that unload finished before load started. The fake records the call order so the invariants are
/// asserted directly.
final class LocalInferenceSeamTests: XCTestCase {

    // MARK: - Fake backend

    /// Records what the coordinator asked it to do, in order.
    private final class FakeBackend: LocalInferenceBackend, @unchecked Sendable {
        enum Call: Equatable {
            case load(LocalModelID)
            case cancel
            case unload
            case generate
        }

        let runtime: LocalModelRuntime

        private let lock = NSLock()
        private var _calls: [Call] = []
        private var _resident: LocalLoadedModel?

        /// Text the next generation yields, as separate stream elements.
        var chunks: [String] = ["hello"]
        /// When set, `load` throws it instead of succeeding.
        var loadError: Error?
        /// Capabilities reported by a successful load.
        var loadedCapabilities: Set<LocalModelCapability> = [.text]

        init(runtime: LocalModelRuntime) { self.runtime = runtime }

        var calls: [Call] {
            lock.lock(); defer { lock.unlock() }
            return _calls
        }

        private func note(_ call: Call) {
            lock.lock(); _calls.append(call); lock.unlock()
        }

        var loadedModel: LocalLoadedModel? {
            lock.lock(); defer { lock.unlock() }
            return _resident
        }

        func load(_ installation: InstalledLocalModel,
                  configuration: LocalLoadConfiguration) async throws -> LocalLoadedModel {
            note(.load(installation.id))
            if let loadError { throw loadError }
            let loaded = LocalLoadedModel(id: installation.id,
                                          runtime: runtime,
                                          contextLength: configuration.contextLength,
                                          capabilities: loadedCapabilities)
            lock.lock(); _resident = loaded; lock.unlock()
            return loaded
        }

        func generate(_ request: LocalGenerationRequest) -> AsyncThrowingStream<String, Error> {
            note(.generate)
            let pieces = chunks
            let preview = request.previewSink
            return AsyncThrowingStream { continuation in
                for piece in pieces {
                    preview?(piece)
                    continuation.yield(piece)
                }
                continuation.finish()
            }
        }

        func cancelGeneration() async { note(.cancel) }

        func unload() async {
            note(.unload)
            lock.lock(); _resident = nil; lock.unlock()
        }
    }

    // MARK: - Helpers

    private func installation(_ rawID: String,
                              runtime: LocalModelRuntime = .mlx,
                              capabilities: Set<LocalModelCapability> = [.text]) -> InstalledLocalModel {
        InstalledLocalModel(
            descriptor: LocalModelDescriptor(
                id: LocalModelID(rawID),
                displayName: rawID,
                runtime: runtime,
                repositoryID: rawID,
                revision: "abc123",
                capabilities: capabilities,
                contextLength: 4096,
                estimatedWeightsBytes: 1_000,
                estimatedWorkingBytes: 1_000,
                minimumHeadroomBytes: 2_000),
            storage: .managed(directoryName: LocalModelID(rawID).storageComponent),
            installedAt: Date(timeIntervalSince1970: 0))
    }

    private let config = LocalLoadConfiguration(contextLength: 4096)

    // MARK: - Residency

    func testLoadingASecondModelEvictsTheFirstBeforeAllocatingIt() async throws {
        let backend = FakeBackend(runtime: .mlx)
        let coordinator = LocalInferenceCoordinator(backends: [backend])

        _ = try await coordinator.load(installation("a/one"), configuration: config)
        _ = try await coordinator.load(installation("b/two"), configuration: config)

        // The ordering is the invariant: the outgoing model is cancelled and unloaded *before* the
        // incoming load begins, so two multi-gigabyte allocations are never resident together.
        XCTAssertEqual(backend.calls,
                       [.load(LocalModelID("a/one")), .cancel, .unload, .load(LocalModelID("b/two"))])
        let resident = await coordinator.loadedModel
        XCTAssertEqual(resident?.id, LocalModelID("b/two"))
    }

    func testReloadingTheResidentModelIsANoOp() async throws {
        let backend = FakeBackend(runtime: .mlx)
        let coordinator = LocalInferenceCoordinator(backends: [backend])

        let first = try await coordinator.load(installation("a/one"), configuration: config)
        let second = try await coordinator.load(installation("a/one"), configuration: config)

        XCTAssertEqual(first, second)
        XCTAssertEqual(backend.calls, [.load(LocalModelID("a/one"))],
                       "a working model must not be torn down and rebuilt")
    }

    func testSwitchingRuntimesLeavesOnlyOneResident() async throws {
        let mlx = FakeBackend(runtime: .mlx)
        let gguf = FakeBackend(runtime: .llamaCpp)
        let coordinator = LocalInferenceCoordinator(backends: [mlx, gguf])

        _ = try await coordinator.load(installation("a/one"), configuration: config)
        _ = try await coordinator.load(installation("b/two", runtime: .llamaCpp), configuration: config)

        XCTAssertNil(mlx.loadedModel, "the MLX backend must have been unloaded on the way out")
        XCTAssertEqual(gguf.loadedModel?.id, LocalModelID("b/two"))
        XCTAssertEqual(mlx.calls.last, .unload)
    }

    func testUnloadCancelsBeforeReleasing() async throws {
        let backend = FakeBackend(runtime: .mlx)
        let coordinator = LocalInferenceCoordinator(backends: [backend])
        _ = try await coordinator.load(installation("a/one"), configuration: config)

        await coordinator.unload()

        XCTAssertEqual(backend.calls.suffix(2), [.cancel, .unload],
                       "freeing weights under a live token loop is the crash this order prevents")
        let resident = await coordinator.loadedModel
        XCTAssertNil(resident)
    }

    func testUnloadWithNothingResidentIsSafe() async {
        let backend = FakeBackend(runtime: .mlx)
        let coordinator = LocalInferenceCoordinator(backends: [backend])
        await coordinator.unload()
        XCTAssertEqual(backend.calls, [])
    }

    func testFailedLoadLeavesNothingResident() async {
        struct Boom: Error {}
        let backend = FakeBackend(runtime: .mlx)
        backend.loadError = Boom()
        let coordinator = LocalInferenceCoordinator(backends: [backend])

        do {
            _ = try await coordinator.load(installation("a/one"), configuration: config)
            XCTFail("expected the load to throw")
        } catch {
            // expected
        }
        let resident = await coordinator.loadedModel
        XCTAssertNil(resident, "the coordinator must not claim a lease it does not hold")
    }

    func testMissingBackendIsTypedNotASilentFallbackToAnotherRuntime() async {
        let mlx = FakeBackend(runtime: .mlx)
        let coordinator = LocalInferenceCoordinator(backends: [mlx])

        do {
            _ = try await coordinator.load(installation("b/two", runtime: .llamaCpp),
                                           configuration: config)
            XCTFail("expected .noBackend")
        } catch let error as LocalInferenceError {
            XCTAssertEqual(error, .noBackend(.llamaCpp))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(mlx.calls, [], "a missing GGUF backend must never quietly run on MLX")
    }

    // MARK: - Generation

    func testStreamConcatenationIsTheAuthoritativeText() async throws {
        let backend = FakeBackend(runtime: .mlx)
        backend.chunks = ["Good ", "morning", "."]
        let coordinator = LocalInferenceCoordinator(backends: [backend])
        _ = try await coordinator.load(installation("a/one"), configuration: config)

        var preview: [String] = []
        let request = LocalGenerationRequest(messages: [.system("s"), .user("u")],
                                             maxOutputTokens: 64,
                                             previewSink: { preview.append($0) })
        var assembled = ""
        for try await chunk in try await coordinator.generate(request) { assembled += chunk }

        XCTAssertEqual(assembled, "Good morning.")
        XCTAssertEqual(preview, ["Good ", "morning", "."],
                       "the preview channel sees the same chunks; it is a separate channel, not a "
                       + "different answer")
    }

    func testGenerateWithoutALoadedModelIsTyped() async {
        let coordinator = LocalInferenceCoordinator(backends: [FakeBackend(runtime: .mlx)])
        do {
            _ = try await coordinator.generate(
                LocalGenerationRequest(messages: [.user("u")], maxOutputTokens: 16))
            XCTFail("expected .notLoaded")
        } catch let error as LocalInferenceError {
            XCTAssertEqual(error, .notLoaded)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testGenerateRefusesWhenADifferentModelIsResident() async throws {
        let backend = FakeBackend(runtime: .mlx)
        let coordinator = LocalInferenceCoordinator(backends: [backend])
        _ = try await coordinator.load(installation("a/one"), configuration: config)

        do {
            _ = try await coordinator.generate(
                LocalGenerationRequest(messages: [.user("u")], maxOutputTokens: 16),
                expecting: LocalModelID("b/two"))
            XCTFail("expected .wrongModelResident")
        } catch let error as LocalInferenceError {
            XCTAssertEqual(error, .wrongModelResident(expected: LocalModelID("b/two"),
                                                      resident: LocalModelID("a/one")))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testImagesAreRefusedByAModelThatLoadedTextOnly() async throws {
        let backend = FakeBackend(runtime: .mlx)
        backend.loadedCapabilities = [.text]   // e.g. a VLM checkpoint demoted at load time
        let coordinator = LocalInferenceCoordinator(backends: [backend])
        _ = try await coordinator.load(installation("a/one", capabilities: [.text, .vision]),
                                       configuration: config)

        do {
            _ = try await coordinator.generate(
                LocalGenerationRequest(messages: [.user("what is this?")],
                                       images: [LocalImageInput(data: Data([0x01]))],
                                       maxOutputTokens: 16))
            XCTFail("expected .visionNotAvailable")
        } catch let error as LocalInferenceError {
            XCTAssertEqual(error, .visionNotAvailable,
                           "capability is judged as loaded, never as catalogued")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testImagesAreAcceptedByAModelThatLoadedWithVision() async throws {
        let backend = FakeBackend(runtime: .mlx)
        backend.loadedCapabilities = [.text, .vision]
        let coordinator = LocalInferenceCoordinator(backends: [backend])
        _ = try await coordinator.load(installation("a/one", capabilities: [.text, .vision]),
                                       configuration: config)

        let stream = try await coordinator.generate(
            LocalGenerationRequest(messages: [.user("what is this?")],
                                   images: [LocalImageInput(data: Data([0x01]))],
                                   maxOutputTokens: 16))
        var assembled = ""
        for try await chunk in stream { assembled += chunk }
        XCTAssertEqual(assembled, "hello")
    }

    // MARK: - Foreground-only policy

    func testBackgroundedRefusesLoadAndGenerate() async throws {
        let backend = FakeBackend(runtime: .mlx)
        let backgrounded = LockedFlag()
        let coordinator = LocalInferenceCoordinator(backends: [backend],
                                                    isBackgrounded: { backgrounded.isSet })

        _ = try await coordinator.load(installation("a/one"), configuration: config)
        backgrounded.set()

        // Generation on an already-resident model is refused rather than submitting Metal work
        // the OS forbids in the background.
        do {
            _ = try await coordinator.generate(
                LocalGenerationRequest(messages: [.user("u")], maxOutputTokens: 16))
            XCTFail("expected .backgrounded")
        } catch let error as LocalInferenceError {
            XCTAssertEqual(error, .backgrounded)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        // And a *different* model is never auto-loaded in the background — the DZ invariant that
        // local inference is foreground-best-effort, never a background service.
        do {
            _ = try await coordinator.load(installation("b/two"), configuration: config)
            XCTFail("expected .backgrounded")
        } catch let error as LocalInferenceError {
            XCTAssertEqual(error, .backgrounded)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertFalse(backend.calls.contains(.load(LocalModelID("b/two"))))
    }

    func testAlreadyResidentModelIsStillReturnedInTheBackground() async throws {
        // Re-requesting what is already resident allocates nothing and touches no accelerator, so
        // refusing it would break a foreground turn that merely re-checks its model.
        let backend = FakeBackend(runtime: .mlx)
        let backgrounded = LockedFlag()
        let coordinator = LocalInferenceCoordinator(backends: [backend],
                                                    isBackgrounded: { backgrounded.isSet })
        _ = try await coordinator.load(installation("a/one"), configuration: config)
        backgrounded.set()

        let again = try await coordinator.load(installation("a/one"), configuration: config)
        XCTAssertEqual(again.id, LocalModelID("a/one"))
        XCTAssertEqual(backend.calls, [.load(LocalModelID("a/one"))])
    }

    // MARK: - Registration

    func testRegisterAddsARuntime() async throws {
        let coordinator = LocalInferenceCoordinator()
        var runtimes = await coordinator.availableRuntimes
        XCTAssertTrue(runtimes.isEmpty)

        await coordinator.register(FakeBackend(runtime: .llamaCpp))
        runtimes = await coordinator.availableRuntimes
        XCTAssertEqual(runtimes, [.llamaCpp])
    }
}
