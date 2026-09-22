import Foundation

/// Plan FS §3 — receiving a vault from a link or a QR code.
///
/// The app **receives** vaults and never helps pass one on: there is no share-as-link, no QR
/// generation and no upload anywhere in it (owner decision, 2026-09-21). What arrives here is a
/// publisher's `https://` address — pasted, or scanned from the publisher's own code — and the
/// path it takes is fixed:
///
/// 1. **Policy.** https only, no credentials in the URL, and the `openglasses://vault?src=…`
///    route carries that one parameter and nothing else. The host is the only part of the link
///    the app ever renders, logs or records.
/// 2. **Offer.** Nothing reaches the network until the reader has seen the site and agreed to
///    fetch from it, with the ceiling and — on cellular — the connection named.
/// 3. **Download** under a hard byte cap, with progress, into a protected staging file.
/// 4. **Review.** The vault, its version, the publisher or the highlighted unverified-source
///    warning, the host the bytes actually came from, the size, the manuals by title, and what a
///    vault does to the assistant's answers. A tampered archive or a revoked publisher stops here
///    with the reason and no install button.
/// 5. **Confirm** — plus a second, explicit acknowledgement when the archive is unverified. The
///    staged file is read again, checked against the digest that was reviewed, verified again, and
///    only then installed under the per-vault lock.
///
/// The archive is re-read and re-verified at the confirmation rather than carried in memory across
/// it, which is both why a large vault does not sit in the heap while somebody reads a sheet and
/// why "what was installed" cannot drift from "what was reviewed".
///
/// Every seam is injected, so the whole pipeline including its refusal ordering runs headless
/// against fixture bytes: no network, no catalog, no entitlement and no clock of its own.
@MainActor
final class VaultLinkService: ObservableObject {

    // MARK: - Stages

    /// What the reader is asked before a single byte is fetched.
    struct FetchOffer: Identifiable, Equatable {
        let id = UUID()
        let host: String
        let isOnCellular: Bool
        let maximumBytes: Int

        static func == (lhs: FetchOffer, rhs: FetchOffer) -> Bool { lhs.id == rhs.id }

        var sizeCeilingText: String {
            ByteCountFormatter.string(fromByteCount: Int64(maximumBytes), countStyle: .file)
        }

        var message: String {
            var lines = [
                "Fetch a vault from \(host)?",
                "Up to \(sizeCeilingText) is downloaded so you can see what it contains. Nothing is installed until you have reviewed it.",
            ]
            if isOnCellular { lines.append("You are on cellular data.") }
            return lines.joined(separator: "\n\n")
        }
    }

    struct Progress: Equatable {
        let received: Int

        var text: String {
            "Downloading… " + ByteCountFormatter.string(fromByteCount: Int64(received), countStyle: .file)
        }
    }

    enum Stage: Equatable {
        case idle
        case offer(FetchOffer)
        case downloading(Progress)
        case reviewing(VaultLinkReview)
        case installing
        case installed(String)
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .downloading, .installing: return true
            default: return false
            }
        }
    }

    @Published private(set) var stage: Stage = .idle
    /// The second acknowledgement, held here rather than in a view so the enablement rule is one
    /// function of two values and both are testable.
    @Published var acknowledgedUnverified = false

    // MARK: - Seams

    struct Download: Equatable {
        let data: Data
        /// Where the bytes actually came from, once redirects were followed.
        let finalURL: URL
    }

    private let download: (URL, VaultLinkStagingStore, @escaping @MainActor (Int) -> Void) async throws -> (StagedVaultArchive, URL)
    private let publishers: () async -> [VaultPublisher]
    private let capability: () -> FieldAssistCapabilityCheck
    private let policy: () -> VaultLinkInstallPolicy
    private let isOnCellular: () -> Bool
    private let installedManifest: (String) -> VaultManifest?
    private let install: (VaultLinkInstaller.Request) async throws -> VaultLinkInstaller.Outcome
    private let audit: (String, Bool) -> Void
    private let now: () -> Date
    private let maximumBytes: Int
    private let cellularWarningBytes: Int
    private let onInstalled: (VaultLinkInstaller.Outcome) -> Void
    private let staging: VaultLinkStagingStore

    /// What the reader is reviewing: the staged file, the host its bytes came from, and the digest
    /// of exactly those bytes. Dropped the moment the review ends, whichever way it ends.
    private var reviewed: (archive: StagedVaultArchive, host: String, sha256: String)?
    private var pendingURL: URL?
    private var activeDownload: Task<(StagedVaultArchive, URL), Error>?

    init(download: @escaping (URL, VaultLinkStagingStore, @escaping @MainActor (Int) -> Void) async throws -> (StagedVaultArchive, URL)
            = VaultLinkService.boundedDownload,
         publishers: @escaping () async -> [VaultPublisher]
            = { await VaultPublisherDirectory.shared.current() },
         capability: @escaping () -> FieldAssistCapabilityCheck
            = { FieldAssistEntitlement.shared.check(.ownVaults) },
         policy: @escaping () -> VaultLinkInstallPolicy = { VaultLinkInstallPolicy.current() },
         isOnCellular: @escaping () -> Bool = { false },
         installedManifest: @escaping (String) -> VaultManifest?
            = { id in VaultImporter.installedManifests().first { $0.id == id } },
         install: @escaping (VaultLinkInstaller.Request) async throws -> VaultLinkInstaller.Outcome
            = VaultLinkInstaller.install,
         audit: @escaping (String, Bool) -> Void = VaultLinkService.auditToOpenSession,
         now: @escaping () -> Date = Date.init,
         maximumBytes: Int = Config.vaultLinkMaxBytes,
         cellularWarningBytes: Int = Config.vaultLinkCellularWarningBytes,
         staging: VaultLinkStagingStore? = nil,
         onInstalled: @escaping (VaultLinkInstaller.Outcome) -> Void = { _ in }) {
        self.download = download
        self.publishers = publishers
        self.capability = capability
        self.policy = policy
        self.isOnCellular = isOnCellular
        self.installedManifest = installedManifest
        self.install = install
        self.audit = audit
        self.now = now
        self.maximumBytes = maximumBytes
        self.cellularWarningBytes = cellularWarningBytes
        self.staging = staging ?? VaultLinkStagingStore(maximumBytes: maximumBytes)
        self.onInstalled = onInstalled
        self.staging.removeAbandonedSessions()
    }

    // MARK: - Step 1 · a link arrives

    /// A pasted address or a scanned code. Nothing touches the network from here — the reader is
    /// shown the site and asked first.
    func open(_ raw: String) {
        reset()
        switch VaultLinkPolicy.resolve(raw) {
        case .failure(let refusal): stage = .failed(refusal.message)
        case .success(let url): offer(url)
        }
    }

    /// The `openglasses://vault?src=…` route, from a code scanned with the phone's own camera.
    func open(_ url: URL) {
        reset()
        switch VaultLinkPolicy.resolve(url) {
        case .failure(let refusal): stage = .failed(refusal.message)
        case .success(let source): offer(source)
        }
    }

    private func offer(_ url: URL) {
        let check = capability()
        guard check.isGranted else {
            stage = .failed(CustomVaultGateState.resolve(check).explanation
                            ?? FieldAssistPaywallCopy.ownVaultsLocked)
            return
        }
        pendingURL = url
        stage = .offer(FetchOffer(host: VaultLinkPolicy.displayHost(url),
                                  isOnCellular: isOnCellular(),
                                  maximumBytes: maximumBytes))
    }

    // MARK: - Step 2 · fetch, under a cap

    func approveFetch() async {
        guard case .offer = stage, let url = pendingURL else { return }
        pendingURL = nil
        stage = .downloading(Progress(received: 0))
        let staging = self.staging
        let task = Task { [download] in
            try await download(url, staging) { [weak self] received in
                guard let self, case .downloading = self.stage else { return }
                self.stage = .downloading(Progress(received: received))
            }
        }
        activeDownload = task
        let archive: StagedVaultArchive
        let finalURL: URL
        do {
            (archive, finalURL) = try await task.value
        } catch is CancellationError {
            activeDownload = nil
            return
        } catch {
            activeDownload = nil
            stage = .failed("Couldn't fetch the vault: \(error.localizedDescription)")
            return
        }
        activeDownload = nil
        guard !Task.isCancelled, case .downloading = stage else {
            staging.remove(archive)
            return
        }
        await inspect(archive, finalURL: finalURL)
    }

    // MARK: - Step 3 · read it, check it, and show what it is

    private func inspect(_ archive: StagedVaultArchive, finalURL: URL) async {
        let bytes: Data
        do {
            bytes = try staging.load(archive)
        } catch {
            staging.remove(archive)
            stage = .failed("The downloaded vault is no longer available to review.")
            return
        }
        guard bytes.count <= maximumBytes else {
            staging.remove(archive)
            stage = .failed("That vault is larger than this app will install.")
            return
        }
        let extracted: VaultArchiveReader.Extracted
        switch VaultArchiveReader.extract(zipData: bytes, maximumTotalBytes: maximumBytes) {
        case .failure(let error):
            staging.remove(archive)
            stage = .failed(VaultArchiveReader.describe(error))
            return
        case .success(let value):
            extracted = value
        }

        let verification = VaultArchiveVerifier.verify(extracted, publishers: await publishers())
        // The host the bytes actually came from, not the one that was typed: a link that redirects
        // to another site is reviewed against where it landed. Nothing has been trusted yet — the
        // review below is the first and only confirmation, and it names this host.
        let host = VaultLinkPolicy.displayHost(finalURL)
        let header = extracted.header
        let review = VaultLinkReview(
            vaultName: header.vaultName, vaultVersion: header.vaultVersion, vaultId: header.vaultId,
            host: host, totalBytes: bytes.count,
            manuals: header.manuals.map(\.title),
            includesOriginalPDFs: header.originalDocumentsIncluded,
            verification: verification, policy: policy(),
            isOnCellular: isOnCellular(), cellularWarningBytes: cellularWarningBytes,
            installedVersion: installedManifest(header.vaultId)?.version)
        reviewed = (archive, host, VaultArchiveReader.sha256Hex(bytes))
        acknowledgedUnverified = false
        audit("vault link reviewed — " + review.auditNote, false)
        stage = .reviewing(review)
    }

    // MARK: - Step 4 · the reader says yes

    func confirmInstall() async {
        guard case .reviewing(let review) = stage, let reviewed else { return }
        guard review.allowsInstall(acknowledged: acknowledgedUnverified) else { return }
        // The capability is asked again at the boundary that writes, not only at the one that
        // offered: a subscription can lapse between a review and a confirmation.
        guard capability().isGranted else {
            discardReviewed()
            stage = .failed(FieldAssistPaywallCopy.ownVaultsLapsed)
            return
        }
        stage = .installing

        // Re-read and re-verify the exact bytes that were reviewed. A digest mismatch means the
        // staged file is not the one the sheet described, which is a refusal and never a retry.
        let bytes: Data
        do {
            bytes = try staging.load(reviewed.archive)
        } catch {
            discardReviewed()
            stage = .failed("Install refused because the reviewed archive is no longer available.")
            return
        }
        guard VaultArchiveReader.sha256Hex(bytes) == reviewed.sha256,
              case .success(let extracted) = VaultArchiveReader.extract(zipData: bytes,
                                                                        maximumTotalBytes: maximumBytes) else {
            discardReviewed()
            stage = .failed("Install refused because the reviewed archive changed.")
            return
        }
        let verification = VaultArchiveVerifier.verify(extracted, publishers: await publishers())
        guard verification == review.verification,
              review.allowsInstall(acknowledged: acknowledgedUnverified) else {
            discardReviewed()
            stage = .failed("Install refused because the reviewed archive changed.")
            return
        }

        let host = reviewed.host
        let receipt = VaultReceipt.make(verification: verification, host: host,
                                        now: now(), archiveSHA256: reviewed.sha256)
        do {
            let outcome = try await install(.init(files: extracted.files, receipt: receipt))
            discardReviewed()
            audit("vault installed from a link — vault=\(outcome.vaultId), host=\(host), "
                  + receipt.verification.rawValue, true)
            onInstalled(outcome)
            stage = .installed(outcome.vaultName)
        } catch {
            discardReviewed()
            stage = .failed(error.localizedDescription)
        }
    }

    /// Dismiss whatever is on screen. A download in flight is cancelled and the reviewed archive
    /// is deleted — nothing half-installed, nothing kept.
    func dismiss() {
        reset()
        stage = .idle
    }

    /// Foreground loss ends a pending review, on the reasoning the skill-pack sideload follows:
    /// an approval the reader cannot see is not an approval.
    func handleBackground() {
        if case .installing = stage { return }
        dismiss()
    }

    private func reset() {
        activeDownload?.cancel()
        activeDownload = nil
        pendingURL = nil
        discardReviewed()
        acknowledgedUnverified = false
    }

    private func discardReviewed() {
        if let reviewed { staging.remove(reviewed.archive) }
        reviewed = nil
    }

    // MARK: - Production seams

    /// Bounded GET with progress, through the client every attacker-selected URL goes through:
    /// one resolved address per hop, TLS verified against the original hostname, redirects parsed
    /// there rather than by URLSession, and the profile's byte cap enforced as bytes arrive.
    ///
    /// It carries no `NetworkRoute` case, which is the treatment the two paths of this shape
    /// already get — the QR-context fetch and the skill-pack sideload download. `NetworkRoute`'s
    /// guard finds a route's owner by scraping for a `URLSession` or `NWConnection` held by the
    /// type itself, and a `BoundedHTTPClient`-only caller owns neither; declaring one anyway would
    /// mean naming the shared transport as the owner, which is exactly what that registry's
    /// exemption for `BoundedHTTPClient` says not to do. Worth fixing for all three together
    /// rather than bending the guard for one.
    static func boundedDownload(_ url: URL, staging: VaultLinkStagingStore,
                                progress: @escaping @MainActor (Int) -> Void) async throws -> (StagedVaultArchive, URL) {
        let archive = try staging.create()
        do {
            var received = 0
            let response = try await BoundedHTTPClient().fetch(url, profile: .vaultArchive) { chunk in
                try staging.append(chunk, to: archive)
                received += chunk.count
                let got = received
                Task { @MainActor in progress(got) }
            }
            guard (200...299).contains(response.statusCode) else { throw URLError(.badServerResponse) }
            return (archive, response.finalURL)
        } catch {
            staging.remove(archive)
            throw error
        }
    }

    /// Plan FS §4 — the review outcome and the install are audit-logged when a field session is
    /// open. The note carries the host and never the link.
    static func auditToOpenSession(_ note: String, installed: Bool) {
        FieldSessionService.shared.noteVaultLink(note, installed: installed)
    }
}
