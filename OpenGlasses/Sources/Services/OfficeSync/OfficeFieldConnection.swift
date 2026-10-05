import Foundation

/// Keeps a paired phone connected to its office while the app is open, and says how.
///
/// Each run verifies the saved approval again (vendor and administrator signatures, live lease,
/// this phone's keys, the generation high-water) before it starts the engine, and again every
/// 30 seconds while it runs; when the approval no longer verifies the engine stops and the state
/// says why. The engine opens no listener, and only the two managed folders the verified binding
/// calls for (`OfficePairingService.openFoldersWithApprovedOffice`). Nothing runs in the
/// background: leaving the screen stops it, and coming back starts it again.
///
/// One engine serves the app, so the pairing screen's own connection test `suspend()`s this and
/// `resume()`s it afterwards, and joining an office by its code `restart()`s it. Engine work is
/// chained: a run starts only after the previous one has finished and the engine has stopped.
///
/// The decisions are `OfficeFieldConnectionPolicy`'s; this drives them.
@MainActor
final class OfficeFieldConnection: ObservableObject {
    typealias Policy = OfficeFieldConnectionPolicy
    typealias State = OfficeFieldConnectionPolicy.State

    /// What a run needs from a saved approval that has just verified again.
    struct Approved: Equatable, Sendable {
        let transportPolicy: OfficePairingService.TransportPolicy
        let lanHint: String?
        /// Identifies the signed binding, so a replaced one is noticed while running.
        let bindingSHA256: String

        init(transportPolicy: OfficePairingService.TransportPolicy, lanHint: String?, bindingSHA256: String) {
            self.transportPolicy = transportPolicy
            self.lanHint = lanHint
            self.bindingSHA256 = bindingSHA256
        }

        init(_ office: OfficePairingService.ApprovedOffice) {
            self.init(transportPolicy: office.transportPolicy, lanHint: office.lanHint,
                      bindingSHA256: office.binding.payloadSHA256)
        }
    }

    struct Seams {
        /// The saved approval, verified again now. Throws when it no longer verifies.
        var approvedOffice: @MainActor () async throws -> Approved = {
            Approved(try await OfficePairingService().currentApprovedPeer())
        }
        /// Starts the managed engine and its two folders from the saved approval, which it verifies
        /// again before and after.
        var start: @MainActor () async throws -> Void = {
            guard let folders = OfficeManagedFolderMobilecoreTransport.makeIfAvailable() else {
                throw OfficeTransportIdentity.Refusal.unavailable
            }
            try await OfficePairingService().openFoldersWithApprovedOffice(folders)
        }
        /// Asked on every poll while the engine runs: take in what the office has sent.
        var takeIn: @MainActor () async -> Void = {}
        var stop: @MainActor () async -> Void = { await OfficeTransportIdentity.shared.stop() }
        /// The engine's public status JSON.
        var snapshot: @MainActor () async throws -> String = { try await OfficeTransportIdentity.shared.snapshot() }
        var sleep: (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
        var clock: () -> Date = Date.init
    }

    /// Why `restart()` did not start the connection.
    enum NotStarted: Error, Equatable {
        /// No office transport in this build, the app is in the background, or the pairing
        /// screen has the engine.
        case notRunning
        /// Superseded by a later start or stop before it finished.
        case superseded
    }

    @Published private(set) var state: State

    private let enabled: Bool
    private let seams: Seams
    private var active = false
    private var suspended = false
    /// The current chain of engine work: a run, or a stop.
    private var work: Task<Void, Never>?
    /// Bumped by every start or stop, so a run that has been replaced changes nothing.
    private var generation = 0
    private var running = false
    private var notConnectedSince: Date?
    /// When the engine was last started again to look the office up afresh (automatic only).
    private var lastLookedAgain: Date?
    /// The saved approval is known to have changed: check it on the next poll, not the next interval.
    private var approvalCheckDue = false
    /// `restart()`'s caller, told how the run it asked for first started.
    private var firstStart: CheckedContinuation<Void, Error>?

    /// - Parameter enabled: false in a build without the office transport: nothing ever runs.
    init(enabled: Bool = OfficeTransportIdentity.isAvailable, seams: Seams = Seams()) {
        self.enabled = enabled
        self.seams = seams
        state = enabled ? .paused : .unavailable
    }

    private var mayRun: Bool { enabled && active && !suspended }

    // MARK: - The app's lifecycle

    /// The app is on screen. Starts the connection unless it is already running; called from
    /// every activation and once at launch, so a repeat does nothing.
    func appBecameActive() {
        active = true
        guard mayRun, !running else { return }
        launch()
    }

    /// The app left the screen: the engine stops, and starts again when the app comes back.
    func appEnteredBackground() {
        active = false
        halt()
    }

    /// The phone's network has just come back. A connection that has not reached the office for
    /// a while starts again now rather than waiting out its backoff.
    func networkBecameAvailable() {
        guard mayRun, running,
              Policy.restartsOnNetworkReturn(state, notConnectedSince: notConnectedSince, now: seams.clock())
        else { return }
        launch()
    }

    // MARK: - Others that need the engine

    /// The pairing screen takes the engine for its own connection test. Returns once this
    /// connection's engine has stopped.
    func suspend() async {
        suspended = true
        halt()
        await work?.value
    }

    /// The pairing screen has finished with the engine (and stopped its test).
    func resume() {
        suspended = false
        guard mayRun else { return }
        launch()
    }

    /// Start again from the saved approval now: after joining an office, or a change of pairing.
    /// Returns once the engine has started; throws why it did not. The connection keeps trying
    /// afterwards either way, unless the approval itself was refused.
    func restart() async throws {
        guard mayRun else { throw NotStarted.notRunning }
        launch()
        let awaited = generation
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            if generation == awaited, running {
                firstStart = continuation
            } else {
                continuation.resume(throwing: NotStarted.superseded)
            }
        }
    }

    /// The saved approval has just been replaced (a renewed binding). The running connection
    /// checks it on its next poll and starts the folders again under the new one.
    func approvalChanged() {
        approvalCheckDue = true
    }

    // MARK: - Engine work

    /// Replace whatever runs with a new run, after the previous work has finished.
    private func launch() {
        reportFirstStart(NotStarted.superseded)
        let previous = work
        previous?.cancel()
        generation += 1
        let current = generation
        running = true
        notConnectedSince = seams.clock()
        lastLookedAgain = nil
        approvalCheckDue = false
        work = Task { [weak self] in
            await previous?.value
            await self?.run(current)
        }
    }

    /// Stop whatever runs and the engine with it.
    private func halt() {
        let previous = work
        previous?.cancel()
        generation += 1
        reportFirstStart(NotStarted.superseded)
        running = false
        if state != .unavailable { state = .paused }
        guard enabled else { return }
        let stop = seams.stop
        work = Task {
            await previous?.value
            await stop()
        }
    }

    private func isCurrent(_ run: Int) -> Bool { run == generation && !Task.isCancelled }

    private func run(_ run: Int) async {
        await seams.stop()
        var failures = 0
        while isCurrent(run) {
            // The approval first: nothing starts on a pairing that no longer verifies.
            let office: Approved
            do {
                office = try await seams.approvedOffice()
            } catch {
                guard isCurrent(run) else { return }
                if await handle(error, run: run, failures: &failures) { continue }
                return
            }
            guard isCurrent(run) else { return }
            if office.transportPolicy == .privateLan, office.lanHint == nil {
                await finish(run, .noOfficeAddress)
                return
            }
            state = .waiting(office.transportPolicy)
            do {
                try await seams.start()
            } catch {
                guard isCurrent(run) else { return }
                if await handle(error, run: run, failures: &failures) { continue }
                return
            }
            guard isCurrent(run) else { return }
            failures = 0
            reportFirstStart(nil)
            // Running: watch it, and keep checking the approval it rests on.
            switch await monitor(run, office: office) {
            case .ended:
                return
            case .lookAgain:
                continue   // started again straight away, from the approval
            case .startAgain:
                // The engine stopped by itself, or the approval changed: start again after a pause.
                failures += 1
                guard await pause(run, failures: failures) else { return }
            }
        }
    }

    private enum AfterMonitoring {
        /// Stopped, replaced, or the approval was refused.
        case ended
        /// The engine went away, or the approval was replaced by a newer one that verifies.
        case startAgain
        /// Still no office under `automatic`: start again now so discovery is asked afresh.
        case lookAgain
    }

    private func monitor(_ run: Int, office: Approved) async -> AfterMonitoring {
        var lastApprovalCheck = seams.clock()
        while isCurrent(run) {
            do { try await seams.sleep(UInt64(Policy.pollInterval * 1_000_000_000)) } catch { return .ended }
            guard isCurrent(run) else { return .ended }
            if approvalCheckDue
                || seams.clock().timeIntervalSince(lastApprovalCheck) >= Policy.approvalRecheckInterval {
                approvalCheckDue = false
                do {
                    let latest = try await seams.approvedOffice()
                    guard isCurrent(run) else { return .ended }
                    lastApprovalCheck = seams.clock()
                    if latest != office {
                        await seams.stop()
                        return isCurrent(run) ? .startAgain : .ended
                    }
                } catch {
                    guard isCurrent(run) else { return .ended }
                    switch Policy.afterFailure(error) {
                    case .stop(let reason):
                        await finish(run, reason)
                        return .ended
                    case .retry:
                        break   // checked again on the next poll
                    }
                }
            }
            let observed: Policy.Observation
            if let snapshot = try? await seams.snapshot() {
                observed = Policy.observe(snapshot: snapshot)
            } else {
                observed = .notRunning
            }
            guard isCurrent(run) else { return .ended }
            if observed != .notRunning {
                // A job committed while the office was out of reach is still taken in.
                await seams.takeIn()
                guard isCurrent(run) else { return .ended }
            }
            switch observed {
            case .connected(let route):
                notConnectedSince = nil
                lastLookedAgain = nil
                state = .connected(route)
            case .waiting:
                if notConnectedSince == nil { notConnectedSince = seams.clock() }
                state = .waiting(office.transportPolicy)
                if Policy.restartsToLookAgain(policy: office.transportPolicy, notConnectedSince: notConnectedSince,
                                              lastLookedAgain: lastLookedAgain, now: seams.clock()) {
                    lastLookedAgain = seams.clock()
                    await seams.stop()
                    return isCurrent(run) ? .lookAgain : .ended
                }
            case .notRunning:
                if notConnectedSince == nil { notConnectedSince = seams.clock() }
                state = .waiting(office.transportPolicy)
                await seams.stop()
                return isCurrent(run) ? .startAgain : .ended
            }
        }
        return .ended
    }

    /// A failed approval check or start. Returns true to try again (after the backoff).
    private func handle(_ error: Error, run: Int, failures: inout Int) async -> Bool {
        switch Policy.afterFailure(error) {
        case .stop(let reason):
            await finish(run, reason)
            return false
        case .retry:
            failures += 1
            reportFirstStart(error)
            return await pause(run, failures: failures)
        }
    }

    private func pause(_ run: Int, failures: Int) async -> Bool {
        let seconds = Policy.backoff(afterFailures: failures)
        do { try await seams.sleep(UInt64(seconds * 1_000_000_000)) } catch { return false }
        return isCurrent(run)
    }

    /// The approval no longer verifies (or cannot be used): stop the engine and say why.
    private func finish(_ run: Int, _ reason: Policy.StopReason) async {
        reportFirstStart(StoppedError(reason: reason))
        await seams.stop()
        guard isCurrent(run) else { return }
        running = false
        state = .stopped(reason)
    }

    private func reportFirstStart(_ error: Error?) {
        guard let pending = firstStart else { return }
        firstStart = nil
        if let error {
            pending.resume(throwing: error)
        } else {
            pending.resume()
        }
    }

    /// `restart()`'s error when the approval was refused.
    struct StoppedError: Error, Equatable {
        let reason: Policy.StopReason
    }
}
