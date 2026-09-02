import Foundation

/// Owns local-model residency across every runtime (Plan DZ invariant 2: "One coordinator owns
/// local model residency").
///
/// The rules it exists to enforce, none of which any single backend can enforce alone:
///
///  1. **At most one resident model, ever.** Two multi-gigabyte allocations resident at once is the
///     jetsam kill this whole seam is defending against. A load that changes model always runs
///     cancel → unload → *await both* → load, in that order.
///  2. **No reentrancy during a transition.** A second load arriving mid-transition is refused with
///     `.transitionInProgress` rather than queued: queueing would hide a caller bug behind a
///     multi-gigabyte pause, and the caller can retry.
///  3. **Foreground only.** Metal work in the background is an uncatchable process kill, so both
///     load and generate consult an injected `isBackgrounded` probe first (Plan DZ invariant 12 —
///     local inference is foreground-best-effort, and nothing here ever auto-loads a model).
///
/// The background probe is injected rather than read from `UIApplication` so the actor stays
/// headless-testable; production passes the real check.
actor LocalInferenceCoordinator {

    /// Backends by runtime. Registered at construction; a runtime with no backend is simply
    /// unavailable and reports `.noBackend` rather than falling back to a different engine.
    private var backends: [LocalModelRuntime: any LocalInferenceBackend] = [:]

    /// The one resident model, and which backend holds it.
    private var residentRuntime: LocalModelRuntime?
    private var resident: LocalLoadedModel?

    /// True between the start and end of a load/unload. Guards against actor reentrancy across the
    /// `await`s inside a transition.
    private var isTransitioning = false

    private let isBackgrounded: @Sendable () -> Bool

    init(backends: [any LocalInferenceBackend] = [],
         isBackgrounded: @escaping @Sendable () -> Bool = { false }) {
        self.isBackgrounded = isBackgrounded
        for backend in backends { self.backends[backend.runtime] = backend }
    }

    func register(_ backend: any LocalInferenceBackend) {
        backends[backend.runtime] = backend
    }

    /// What is loaded right now, or nil.
    var loadedModel: LocalLoadedModel? { resident }

    /// Runtimes with a registered backend.
    var availableRuntimes: Set<LocalModelRuntime> { Set(backends.keys) }

    // MARK: - Residency

    /// Make `installation` the resident model, evicting whatever else was resident.
    ///
    /// Re-requesting the already-resident model is a no-op that returns the existing lease — it
    /// must not tear down and rebuild a working model, which is both slow and a memory spike.
    @discardableResult
    func load(_ installation: InstalledLocalModel,
              configuration: LocalLoadConfiguration) async throws -> LocalLoadedModel {
        guard !isTransitioning else { throw LocalInferenceError.transitionInProgress }
        if let resident, resident.id == installation.id, residentRuntime == installation.runtime {
            return resident
        }
        guard !isBackgrounded() else { throw LocalInferenceError.backgrounded }
        guard let backend = backends[installation.runtime] else {
            throw LocalInferenceError.noBackend(installation.runtime)
        }

        isTransitioning = true
        defer { isTransitioning = false }

        // Evict first, and fully. `unloadResident` awaits the outgoing backend's cancellation and
        // unload, so the incoming allocation never overlaps the outgoing one.
        await unloadResident()

        do {
            let loaded = try await backend.load(installation, configuration: configuration)
            resident = loaded
            residentRuntime = installation.runtime
            PrivacyLog.localModel(.loaded, model: PrivacyToken(installation.id.rawValue),
                                  vision: loaded.supportsVision,
                                  detail: PrivacyToken("coordinator-\(installation.runtime.rawValue)"))
            return loaded
        } catch {
            // A failed load leaves nothing resident: the backend is responsible for tearing down
            // its own partial state, and the coordinator must not claim a lease it doesn't hold.
            resident = nil
            residentRuntime = nil
            PrivacyLog.localModel(.loadFailed, model: PrivacyToken(installation.id.rawValue),
                                  detail: PrivacyToken("coordinator-\(installation.runtime.rawValue)"),
                                  error: SafeErrorSummary(error))
            throw error
        }
    }

    /// Generate against the resident model.
    ///
    /// `expecting` is the model the caller believes is loaded. Supplying it turns a stale caller
    /// into a typed error instead of an answer from the wrong model — worth having because the
    /// user can switch models between assembling a turn and running it.
    func generate(_ request: LocalGenerationRequest,
                  expecting expected: LocalModelID? = nil) throws -> AsyncThrowingStream<String, Error> {
        guard !isTransitioning else { throw LocalInferenceError.transitionInProgress }
        guard let resident, let residentRuntime else { throw LocalInferenceError.notLoaded }
        if let expected, expected != resident.id {
            throw LocalInferenceError.wrongModelResident(expected: expected, resident: resident.id)
        }
        guard !isBackgrounded() else { throw LocalInferenceError.backgrounded }
        if !request.images.isEmpty, !resident.supportsVision {
            throw LocalInferenceError.visionNotAvailable
        }
        guard let backend = backends[residentRuntime] else {
            throw LocalInferenceError.noBackend(residentRuntime)
        }
        return backend.generate(request)
    }

    /// Stop the in-flight generation on the resident backend and wait for it to have stopped.
    func cancelGeneration() async {
        guard let residentRuntime, let backend = backends[residentRuntime] else { return }
        await backend.cancelGeneration()
    }

    /// Release the resident model. Safe when nothing is resident.
    func unload() async {
        guard !isTransitioning else { return }
        isTransitioning = true
        defer { isTransitioning = false }
        await unloadResident()
    }

    /// Cancel-then-unload the resident backend and clear the lease. Callers hold `isTransitioning`.
    private func unloadResident() async {
        guard let runtime = residentRuntime, let backend = backends[runtime] else {
            resident = nil
            residentRuntime = nil
            return
        }
        await backend.cancelGeneration()
        await backend.unload()
        resident = nil
        residentRuntime = nil
    }
}
