import Foundation
import UIKit

/// The screen-facing half of the acquisition pipeline: one object that owns the repository, the
/// background transfer and the download manager, and publishes what a row needs to draw
/// (docs/plans/DZ-local-gguf-and-durable-agent-runtime.md, "Local model manager and diagnostics").
///
/// It exists so three things have exactly one owner:
///
///  - **The background `URLSession`.** iOS hands its completion handler to the app delegate, which
///    needs to reach the same transfer object the screen is driving. A view cannot be that owner —
///    it is gone by the time the system wakes the app.
///  - **The plan-to-row mapping.** Rows are keyed by `LocalModelID`; plans are keyed by UUID. One
///    place derives one from the other, so cancel and retry cannot act on a different plan than the
///    row was drawn from.
///  - **Announcements.** Progress is announced at bounded intervals and completion immediately, and
///    the announcer's state has to outlive a redraw.
///
/// Everything decision-shaped lives in the pure types this drives (`LocalModelFitReport`,
/// `LocalModelRowState`, `LocalModelProgressAnnouncer`); what is here is wiring and lifecycle.
@MainActor
final class LocalModelAcquisition: ObservableObject {

    /// The app's instance. The app delegate reaches it to deliver background events; the model
    /// manager observes it.
    static let shared = LocalModelAcquisition()

    let repository: LocalModelRepository
    private let transfer: LocalModelBackgroundTransfer
    /// Lazy so its `unloadIfResident` hook can route back through this object: the closure has to
    /// capture `self`, and a stored property cannot during initialization.
    private lazy var manager = LocalModelDownloadManager(
        repository: repository,
        transfer: transfer,
        unloadIfResident: { [weak self] id in await self?.callReleaseResident(id) })

    /// Release a resident model before its files go. Set by whoever owns residency (the model
    /// manager wires it to the inference coordinator); nil means nothing can be resident.
    var releaseResident: ((LocalModelID) async -> Void)?

    // MARK: - Published state

    @Published private(set) var installed: [InstalledLocalModel] = []
    /// Acquisitions in flight, by the model they install.
    @Published private(set) var staging: [LocalModelID: LocalModelStagingSummary] = [:]
    /// The descriptor of anything staged but not yet installed, so an import can be shown as a row
    /// before it exists on disk.
    @Published private(set) var stagedDescriptors: [LocalModelID: LocalModelDescriptor] = [:]
    /// The last failure worth showing, already user-ready.
    @Published var errorMessage: String?
    /// True while a plan is being created or run from this screen.
    @Published private(set) var isWorking = false

    private var planIDs: [LocalModelID: UUID] = [:]
    private var announcers: [LocalModelID: LocalModelProgressAnnouncer] = [:]
    private var runTask: Task<Void, Never>?

    init(repository: LocalModelRepository = LocalModelRepository()) {
        self.repository = repository
        self.transfer = LocalModelBackgroundTransfer()
    }

    private func callReleaseResident(_ id: LocalModelID) async {
        await releaseResident?(id)
    }

    // MARK: - Background session

    /// Whether an identifier belongs to the model-download session. The app delegate serves more
    /// than one background session, and answering "not mine" correctly is what keeps the other
    /// one's completion handler from being swallowed here.
    nonisolated static func ownsBackgroundSession(_ identifier: String) -> Bool {
        identifier == LocalModelBackgroundTransfer.sessionIdentifier
    }

    /// Take the system's completion handler for a relaunch caused by a finished background
    /// transfer. It is invoked once the session has delivered everything it held.
    func adoptBackgroundEventsHandler(_ handler: @escaping @Sendable () -> Void) {
        transfer.setBackgroundEventsHandler(handler)
        // Delivery wakes the app with plans on disk and tasks the system still holds; restoring is
        // what turns that into installed models.
        Task { await self.restore() }
    }

    // MARK: - Refresh

    func refresh() async {
        installed = repository.installedModels()
        await refreshPlans()
    }

    /// Re-derive the staging map. Called on a timer while the screen is visible, which is also what
    /// drives the progress bar and the bounded announcements.
    func refreshPlans() async {
        let plans = await manager.plans()
        var staging: [LocalModelID: LocalModelStagingSummary] = [:]
        var descriptors: [LocalModelID: LocalModelDescriptor] = [:]
        var ids: [LocalModelID: UUID] = [:]
        for plan in plans {
            let live = await manager.progress(plan.id)?.completedBytes
            guard let summary = LocalModelStagingSummary(plan: plan, completedBytes: live) else {
                continue
            }
            staging[plan.descriptor.id] = summary
            descriptors[plan.descriptor.id] = plan.descriptor
            ids[plan.descriptor.id] = plan.id
        }
        self.staging = staging
        self.stagedDescriptors = descriptors
        self.planIDs = ids
        announceProgress(for: staging)
    }

    /// Restore after a relaunch and finish anything that was mid-install.
    func restore() async {
        _ = await manager.restore()
        await refresh()
    }

    // MARK: - Fit

    /// The fit report for a descriptor, taken against live readings of this device.
    ///
    /// Both readings are taken here, on the main actor, next to the surface that shows them — the
    /// download manager requires the report rather than recomputing it precisely so the plan is
    /// built from the numbers the user agreed to.
    func fitReport(for descriptor: LocalModelDescriptor,
                   acceptedLicenseRevision: String? = nil) -> LocalModelFitReport {
        LocalModelFitReport.make(.init(
            descriptor: descriptor,
            availableStorageBytes: OfflineModelOffer.freeDiskBytes(),
            availableProcessBytes: MemoryHeadroom.availableBytes(),
            acceptedLicenseRevision: acceptedLicenseRevision))
    }

    // MARK: - Starting a download

    /// Create, consent to, and run a plan. One call, because a plan that is created and not
    /// consented to is a directory on disk that nothing will ever finish.
    func startDownload(descriptor: LocalModelDescriptor,
                       origin: LocalModelDownloadPlan.Origin,
                       acceptedLicenseRevision: String? = nil) async {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        let fit = fitReport(for: descriptor, acceptedLicenseRevision: acceptedLicenseRevision)
        guard fit.canInstall else {
            errorMessage = fit.blockers.first?.localizedMessage
                ?? "This model can't be downloaded."
            return
        }
        do {
            let plan = try await manager.createPlan(descriptor: descriptor, origin: origin, fit: fit)
            _ = try await manager.grantConsent(planID: plan.id,
                                               acceptedLicenseRevision: acceptedLicenseRevision)
            announcers[descriptor.id] = LocalModelProgressAnnouncer(modelName: descriptor.displayName)
            await refreshPlans()
            run(planID: plan.id, modelID: descriptor.id)
        } catch let error as LocalModelDownloadManager.ManagerError {
            errorMessage = Self.message(for: error)
        } catch {
            errorMessage = "The download couldn't be started."
        }
    }

    private func run(planID: UUID, modelID: LocalModelID) {
        runTask?.cancel()
        runTask = Task { [weak self] in
            guard let self else { return }
            let finished = await self.manager.run(planID: planID)
            await self.finish(plan: finished, modelID: modelID)
        }
    }

    private func finish(plan: LocalModelDownloadPlan?, modelID: LocalModelID) async {
        await refresh()
        guard let plan else { return }
        switch plan.state {
        case .installed:
            announce(.completed, for: modelID)
        case .cancelled:
            announce(.cancelled, for: modelID)
        case .failed(let failure):
            let message = LocalModelRowState.retryExplanation(failure.reason)
            errorMessage = message
            announce(.failed(message), for: modelID)
        default:
            break
        }
    }

    // MARK: - Cancel, retry, delete

    func cancel(_ id: LocalModelID) async {
        guard let planID = planIDs[id] else { return }
        runTask?.cancel()
        _ = await manager.cancel(planID: planID)
        announce(.cancelled, for: id)
        await refresh()
    }

    func retry(_ id: LocalModelID) async {
        guard let planID = planIDs[id] else { return }
        announcers[id]?.restart()
        errorMessage = nil
        await refreshPlans()
        run(planID: planID, modelID: id)
    }

    /// Remove an installation. Cancels anything fetching it and releases it if resident first —
    /// both inside the download manager, which is where that ordering is already proved.
    func delete(_ id: LocalModelID) async {
        errorMessage = nil
        do {
            try await manager.deleteInstallation(id)
            announcers[id] = nil
        } catch let error as LocalModelDownloadManager.ManagerError {
            errorMessage = Self.message(for: error)
        } catch {
            errorMessage = "That model couldn't be removed."
        }
        await refresh()
    }

    /// What a removal will actually delete, named before it happens.
    ///
    /// The plan requires the confirmation to say whether staged *and* installed files go. Both can
    /// exist at once — a re-download of an installed model stages a second copy — and a person
    /// agreeing to "delete" deserves to know they are agreeing to both.
    func removalConfirmation(for id: LocalModelID, displayName: String) -> String {
        let hasInstall = repository.installation(for: id) != nil
        let hasStaging = staging[id] != nil
        switch (hasInstall, hasStaging) {
        case (true, true):
            return "Remove \(displayName)? Its installed files and the partly downloaded copy are "
                + "both deleted. It can be downloaded again later."
        case (true, false):
            return "Remove \(displayName)? Its installed files are deleted from this iPhone. It can "
                + "be downloaded again later."
        case (false, true):
            return "Stop and remove \(displayName)? The partly downloaded files are deleted. "
                + "Nothing was installed."
        case (false, false):
            return "Remove \(displayName)?"
        }
    }

    // MARK: - Announcements

    private func announceProgress(for staging: [LocalModelID: LocalModelStagingSummary]) {
        for (id, summary) in staging {
            guard case .downloading = summary.phase else { continue }
            announce(.progress(fraction: summary.fractionCompleted), for: id)
        }
    }

    private func announce(_ event: LocalModelProgressAnnouncer.Event, for id: LocalModelID) {
        let name = stagedDescriptors[id]?.displayName
            ?? repository.installation(for: id)?.descriptor.displayName
            ?? id.rawValue
        var announcer = announcers[id] ?? LocalModelProgressAnnouncer(modelName: name)
        let sentence = announcer.announcement(for: event, at: Date())
        announcers[id] = announcer
        guard let sentence else { return }
        Self.post(sentence)
    }

    /// Say something to VoiceOver. Nothing happens when it is off, which is why the announcer's
    /// interval logic lives in a pure type rather than being inferred from the absence of speech.
    static func post(_ announcement: String) {
        UIAccessibility.post(notification: .announcement, argument: announcement)
    }

    /// The sentence a person sees when they leave the screen mid-download.
    func backgroundContinuationNotice() -> String? {
        let running = staging.first { summary in
            switch summary.value.phase {
            case .queued, .downloading, .validating, .installing: return true
            case .awaitingConsent, .retryable: return false
            }
        }
        guard let running else { return nil }
        let name = stagedDescriptors[running.key]?.displayName ?? running.key.rawValue
        return LocalModelProgressAnnouncer.backgroundContinuationNotice(modelName: name)
    }

    // MARK: - Errors

    /// Manager faults, said in words. A blocker list is collapsed to its first entry: the consent
    /// screen shows them all, and this path is the one where a plan was refused *after* consent,
    /// where the first reason is the one that changed.
    static func message(for error: LocalModelDownloadManager.ManagerError) -> String {
        switch error {
        case .anotherPlanActive:
            return "Another model is downloading. Wait for it to finish, or cancel it first."
        case .planNotFound:
            return "That download is no longer available."
        case .descriptorNotInstallable:
            return "This model isn't described precisely enough to install safely."
        case .fitRefused(let blockers):
            return blockers.first?.localizedMessage ?? "This model can't be downloaded."
        case .consentRequired:
            return "Accept this model's licence to continue."
        case .installationNotFound:
            return "That model isn't installed."
        case .containmentRefused:
            return "That model's files couldn't be removed safely, so nothing was deleted."
        case .storageUnavailable:
            return "There wasn't room to write to storage."
        }
    }
}
