import Foundation

/// Plan BX P3 — the sideload/dev loop: `openglasses://skillpack?url=<zip>&sig=<base64>` from a QR
/// code or link offers a pack for download and installation through two explicit confirmations.
///
/// # Trust posture
///
/// A QR-scanned link cannot carry the `DeepLinkTrust` app-group token (it doesn't come from a
/// first-party widget), so this host deliberately is NOT token-gated. The compensating control is
/// that the link never starts transport: it first presents the normalized origin and download
/// limits. A second confirmation follows inspection and shows the pack's identity and signature
/// status. On top of that:
///
/// - The source URL must be HTTPS, or plain HTTP only to a **private/LAN** host (the dev loop:
///   `Scripts/serve-skillpack.sh` on your own network). Public plain-HTTP is refused outright.
/// - Unsigned packs still require developer mode, exactly like every other install path.
/// - The store's signature → decode → validate pipeline is unchanged underneath.
struct SkillPackSideloadRequest: Equatable {
    let packURL: URL
    /// Optional detached pack signature (base64), for signed sideloads.
    let signature: String?
}

enum SkillPackSideload {

    enum ParseError: Error, Equatable {
        case notASideloadLink
        case missingURL
        case insecureSource
    }

    /// Parse `openglasses://skillpack?url=…&sig=…`.
    static func parse(_ url: URL) -> Result<SkillPackSideloadRequest, ParseError> {
        guard url.scheme == "openglasses", url.host == "skillpack" else {
            return .failure(.notASideloadLink)
        }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let raw = items.first(where: { $0.name == "url" })?.value,
              let packURL = URL(string: raw) else {
            return .failure(.missingURL)
        }
        guard isPermittedSource(packURL) else {
            return .failure(.insecureSource)
        }
        let signature = items.first(where: { $0.name == "sig" })?.value
        return .success(SkillPackSideloadRequest(packURL: packURL, signature: signature))
    }

    /// HTTPS anywhere; plain HTTP only to hosts that cannot be on the public internet.
    static func isPermittedSource(_ url: URL) -> Bool {
        guard url.host != nil, url.user == nil, url.password == nil, url.fragment == nil else {
            return false
        }
        switch url.scheme?.lowercased() {
        case "https":
            return true
        case "http":
            guard let host = url.host?.lowercased() else { return false }
            return isPrivateHost(host)
        default:
            return false
        }
    }

    /// Loopback, RFC 1918 ranges, link-local, and mDNS `.local` names — the shapes a LAN dev
    /// server actually has.
    static func isPrivateHost(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".local") { return true }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return false }
        switch (octets[0], octets[1]) {
        case (127, _): return true                    // loopback
        case (10, _): return true                     // 10/8
        case (192, 168): return true                  // 192.168/16
        case (172, 16...31): return true              // 172.16/12
        case (169, 254): return true                  // link-local
        default: return false
        }
    }
}

struct StagedSkillPackArchive: Equatable {
    let id: UUID
    let fileURL: URL
    let finalURL: URL?

    init(id: UUID, fileURL: URL, finalURL: URL? = nil) {
        self.id = id
        self.fileURL = fileURL
        self.finalURL = finalURL
    }

    var directory: URL { fileURL.deletingLastPathComponent() }
}

enum SkillPackStagingError: Error, Equatable {
    case setupFailed
    case writeFailed
    case unavailable
    case archiveTooLarge
}

/// Protected, backup-excluded storage for one consented sideload attempt.
final class SkillPackStagingStore {
    let root: URL

    private let fileManager: FileManager
    private let protect: (URL) throws -> Void

    init(
        root: URL? = nil,
        fileManager: FileManager = .default,
        protect: @escaping (URL) throws -> Void = SkillPackStagingStore.applyProtection
    ) {
        self.fileManager = fileManager
        let cacheRoot = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        self.root = root ?? cacheRoot.appendingPathComponent("SkillPackSideload", isDirectory: true)
        self.protect = protect
    }

    func stage(_ data: Data) throws -> StagedSkillPackArchive {
        guard data.count <= SkillPackArchive.maxArchiveBytes else { throw SkillPackStagingError.archiveTooLarge }
        let archive = try createArchive()
        do {
            try append(data, to: archive)
            return archive
        } catch {
            remove(archive)
            throw error
        }
    }

    /// Creates and protects an empty archive before any untrusted response byte is written.
    func createArchive() throws -> StagedSkillPackArchive {
        let id = UUID()
        let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("archive.zip")
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            try protect(root)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
            try protect(directory)
            guard fileManager.createFile(
                atPath: fileURL.path,
                contents: nil,
                attributes: [.protectionKey: FileProtectionType.complete]
            ) else { throw SkillPackStagingError.setupFailed }
            try protect(fileURL)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw SkillPackStagingError.setupFailed
        }
        return StagedSkillPackArchive(id: id, fileURL: fileURL)
    }

    /// Appends one bounded network chunk. The on-disk size is authoritative across every call.
    func append(_ data: Data, to archive: StagedSkillPackArchive) throws {
        guard isContained(archive.fileURL), fileManager.fileExists(atPath: archive.fileURL.path),
              let size = try? fileManager.attributesOfItem(atPath: archive.fileURL.path)[.size] as? NSNumber,
              size.intValue <= SkillPackArchive.maxArchiveBytes,
              data.count <= SkillPackArchive.maxArchiveBytes - size.intValue else {
            throw SkillPackStagingError.archiveTooLarge
        }
        do {
            let handle = try FileHandle(forWritingTo: archive.fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            throw SkillPackStagingError.writeFailed
        }
    }

    func load(_ archive: StagedSkillPackArchive) throws -> Data {
        guard isContained(archive.fileURL), fileManager.fileExists(atPath: archive.fileURL.path),
              let size = try fileManager.attributesOfItem(atPath: archive.fileURL.path)[.size] as? NSNumber,
              size.intValue <= SkillPackArchive.maxArchiveBytes else {
            throw SkillPackStagingError.unavailable
        }
        // The compressed archive is already capped on disk. Map it for random-access ZIP metadata
        // reads so extraction does not duplicate the full attacker-controlled archive in heap.
        return try Data(contentsOf: archive.fileURL, options: .mappedIfSafe)
    }

    func remove(_ archive: StagedSkillPackArchive) {
        guard isContained(archive.directory) else { return }
        try? fileManager.removeItem(at: archive.directory)
    }

    /// No sideload approval survives process termination, so UUID session directories found when
    /// the service is reconstructed are abandoned. Ignore unrelated files under an injected root.
    func removeAbandonedSessions() {
        guard let children = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for child in children where UUID(uuidString: child.lastPathComponent) != nil && isContained(child) {
            try? fileManager.removeItem(at: child)
        }
    }

    private func isContained(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/")
    }

    private static func applyProtection(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutableURL.setResourceValues(values)
    }
}

/// Fetches a sideloaded pack, previews it, and holds the pending install for the confirmation UI.
@MainActor
final class SkillPackSideloadService: ObservableObject {

    struct DownloadOffer: Identifiable, Equatable {
        let id: UUID
        let request: SkillPackSideloadRequest
        let origin: String
        let expiresAt: Date

        var consentMessage: String {
            "Source: \(origin)\n\nThis source is untrusted. Download up to 8 MiB for inspection? Nothing will be installed yet."
        }
    }

    /// What the confirmation alert shows and acts on.
    struct PendingInstall: Identifiable, Equatable {
        let id = UUID()
        let name: String
        let version: String
        let summary: String
        let actionCount: Int
        let actionNames: [String]
        let origin: String
        let capabilities: [String]
        let settingKeys: [String]
        let warnings: [String]
        let signed: Bool
        let decodeSummary: String
        let signature: String?
        let stagedArchive: StagedSkillPackArchive
        let archiveSHA256: String

        static func == (lhs: PendingInstall, rhs: PendingInstall) -> Bool { lhs.id == rhs.id }

        var confirmationMessage: String {
            var lines = ["\(name) v\(version)"]
            if !summary.isEmpty { lines.append(summary) }
            lines.append("Source: \(origin)")
            lines.append("Archive SHA-256: \(archiveSHA256)")
            lines.append("Actions (\(actionCount)): \(actionNames.isEmpty ? "none" : actionNames.joined(separator: ", "))")
            lines.append("Capabilities: \(capabilities.isEmpty ? "none" : capabilities.joined(separator: ", "))")
            lines.append("Settings: \(settingKeys.isEmpty ? "none" : settingKeys.joined(separator: ", "))")
            lines.append(signed ? "Signature verified for this review."
                                : "UNSIGNED — developer-mode install.")
            let visibleWarnings = warnings.filter { !$0.isEmpty && !$0.hasPrefix("UNSIGNED") }
            if !visibleWarnings.isEmpty { lines.append("Warnings: \(visibleWarnings.joined(separator: "; "))") }
            if decodeSummary != "clean", !visibleWarnings.contains(where: { $0.contains(decodeSummary) }) {
                lines.append("Partial: \(decodeSummary)")
            }
            return lines.joined(separator: "\n")
        }
    }

    enum Prompt: Identifiable, Equatable {
        case downloadConsent(DownloadOffer)
        case confirm(PendingInstall)
        case error(String)
        case installed(String)

        var id: String {
            switch self {
            case .downloadConsent(let offer): return offer.id.uuidString
            case .confirm(let pending): return pending.id.uuidString
            case .error(let message): return "error-\(message)"
            case .installed(let message): return "ok-\(message)"
            }
        }
    }

    @Published var prompt: Prompt?

    private let store: SkillPackStore
    private let download: (URL, SkillPackStagingStore) async throws -> StagedSkillPackArchive
    private let onInstalled: () -> Void
    private let networkDecision: UntrustedNetworkFeaturePolicy.Decision
    private let now: () -> Date
    private let stagingStore: SkillPackStagingStore
    private var pendingDownload: DownloadOffer?
    private var pendingInstallID: UUID?
    private var stagedArchive: StagedSkillPackArchive?
    private var activeDownload: Task<StagedSkillPackArchive, Error>?
    private var activeDownloadID: UUID?

    static let consentLifetime: TimeInterval = 5 * 60

    init(
        store: SkillPackStore,
        download: @escaping (URL, SkillPackStagingStore) async throws -> StagedSkillPackArchive =
            SkillPackSideloadService.streamDownload,
        networkDecision: UntrustedNetworkFeaturePolicy.Decision =
            UntrustedNetworkFeaturePolicy.currentDecision(for: .skillPackDeepLinkFetch),
        now: @escaping () -> Date = Date.init,
        stagingStore: SkillPackStagingStore = SkillPackStagingStore(),
        onInstalled: @escaping () -> Void = {}
    ) {
        self.store = store
        self.download = download
        self.networkDecision = networkDecision
        self.now = now
        self.stagingStore = stagingStore
        self.onInstalled = onInstalled
        stagingStore.removeAbandonedSessions()
    }

    /// Fixture-friendly adapter. Production uses the streaming initializer above.
    convenience init(
        store: SkillPackStore,
        fetch: @escaping (URL) async throws -> Data,
        networkDecision: UntrustedNetworkFeaturePolicy.Decision =
            UntrustedNetworkFeaturePolicy.currentDecision(for: .skillPackDeepLinkFetch),
        now: @escaping () -> Date = Date.init,
        stagingStore: SkillPackStagingStore = SkillPackStagingStore(),
        onInstalled: @escaping () -> Void = {}
    ) {
        self.init(
            store: store,
            download: { url, stagingStore in
                let data = try await fetch(url)
                try Task.checkCancellation()
                return try stagingStore.stage(data)
            },
            networkDecision: networkDecision,
            now: now,
            stagingStore: stagingStore,
            onInstalled: onInstalled
        )
    }

    /// Presents a non-network download offer. No transport closure is invoked here.
    func handle(_ request: SkillPackSideloadRequest) async {
        cancelAndCleanUp()
        guard networkDecision.allowsRequest else {
            prompt = .error(UntrustedNetworkFeaturePolicy.unavailableMessage)
            return
        }

        let offer = DownloadOffer(
            id: UUID(),
            request: request,
            origin: Self.displayOrigin(for: request.packURL),
            expiresAt: now().addingTimeInterval(Self.consentLifetime))
        pendingDownload = offer
        prompt = .downloadConsent(offer)
    }

    /// Consumes a single-use consent offer and downloads the exact URL bound to it.
    func approveDownload(_ offer: DownloadOffer) async {
        guard let pendingDownload, pendingDownload.id == offer.id,
              pendingDownload.request == offer.request else {
            prompt = .error("That download approval is no longer valid.")
            return
        }
        self.pendingDownload = nil
        guard now() <= offer.expiresAt else {
            prompt = .error("That download approval expired. Open the link again to review it.")
            return
        }

        let downloadID = UUID()
        let task = Task { try await download(offer.request.packURL, stagingStore) }
        activeDownloadID = downloadID
        activeDownload = task

        let staged: StagedSkillPackArchive
        do {
            staged = try await task.value
        } catch {
            guard activeDownloadID == downloadID else { return }
            activeDownload = nil
            activeDownloadID = nil
            prompt = .error("Couldn't fetch the pack: \(error.localizedDescription)")
            return
        }
        guard activeDownloadID == downloadID else {
            stagingStore.remove(staged)
            return
        }
        activeDownload = nil
        activeDownloadID = nil
        stagedArchive = staged
        let zipData: Data
        do {
            zipData = try stagingStore.load(staged)
        } catch {
            cleanUpStagedArchive()
            prompt = .error("The downloaded pack is no longer available for inspection.")
            return
        }
        guard case .success(let (manifestData, files)) = SkillPackArchive.extract(zipData: zipData) else {
            cleanUpStagedArchive()
            prompt = .error("That link isn't a readable skill pack archive.")
            return
        }
        let (decoded, report) = SkillPackManifest.lossyDecode(manifestData)
        guard let manifest = decoded else {
            cleanUpStagedArchive()
            prompt = .error("The pack's manifest is unreadable.")
            return
        }
        let reviewWarnings: [String]
        switch store.review(
            manifestData: manifestData,
            files: files,
            signatureBase64: offer.request.signature,
            developerMode: Config.skillPackDevModeEnabled
        ) {
        case .accepted(let warnings):
            reviewWarnings = warnings
        case .rejected(let reasons):
            cleanUpStagedArchive()
            prompt = .error("Install review refused: \(reasons.joined(separator: "; "))")
            return
        }
        let pending = PendingInstall(
            name: manifest.name,
            version: manifest.version,
            summary: manifest.summary,
            actionCount: manifest.actions.count,
            actionNames: manifest.actions.map(\.name).sorted(),
            origin: Self.displayOrigin(for: staged.finalURL ?? offer.request.packURL),
            capabilities: Self.capabilityDetails(for: manifest),
            settingKeys: manifest.settings.map(\.key).sorted(),
            warnings: reviewWarnings,
            signed: offer.request.signature != nil,
            decodeSummary: report.summary,
            signature: offer.request.signature,
            stagedArchive: staged,
            archiveSHA256: SkillPackArchive.sha256Hex(zipData))
        pendingInstallID = pending.id
        prompt = .confirm(pending)
    }

    /// The user tapped Install on the confirmation.
    func confirm(_ pending: PendingInstall) {
        guard pendingInstallID == pending.id else {
            prompt = .error("That install approval is no longer valid.")
            return
        }
        pendingInstallID = nil

        let reviewedManifest: Data
        let reviewedFiles: [String: Data]
        do {
            let exactArchive = try stagingStore.load(pending.stagedArchive)
            guard SkillPackArchive.sha256Hex(exactArchive) == pending.archiveSHA256,
                  case .success(let extracted) = SkillPackArchive.extract(zipData: exactArchive) else {
                cleanUpStagedArchive()
                prompt = .error("Install refused because the reviewed archive changed.")
                return
            }
            reviewedManifest = extracted.manifestData
            reviewedFiles = extracted.files
        } catch {
            cleanUpStagedArchive()
            prompt = .error("Install refused because the reviewed archive is unavailable.")
            return
        }

        switch store.install(
            manifestData: reviewedManifest,
            files: reviewedFiles,
            signatureBase64: pending.signature,
            developerMode: Config.skillPackDevModeEnabled
        ) {
        case .installed(let warnings):
            cleanUpStagedArchive()
            onInstalled()
            prompt = .installed(warnings.isEmpty
                ? "\(pending.name) installed."
                : "\(pending.name) installed — \(warnings.joined(separator: "; "))")
        case .rejected(let reasons):
            cleanUpStagedArchive()
            prompt = .error("Install refused: \(reasons.joined(separator: "; "))")
        }
    }

    func dismiss() {
        cancelAndCleanUp()
        prompt = nil
    }

    /// A consent or reviewed archive never survives loss of the foreground scene.
    func handleBackground() {
        dismiss()
    }

    private func cancelAndCleanUp() {
        activeDownload?.cancel()
        activeDownload = nil
        activeDownloadID = nil
        pendingDownload = nil
        pendingInstallID = nil
        cleanUpStagedArchive()
    }

    private func cleanUpStagedArchive() {
        if let stagedArchive { stagingStore.remove(stagedArchive) }
        stagedArchive = nil
    }

    private static func displayOrigin(for url: URL) -> String {
        let scheme = url.scheme?.lowercased() ?? "https"
        let host = url.host?.lowercased() ?? "unknown"
        guard let port = url.port else { return "\(scheme)://\(host)" }
        return "\(scheme)://\(host):\(port)"
    }

    private static func capabilityDetails(for manifest: SkillPackManifest) -> [String] {
        var details = Set<String>()
        for requirement in manifest.hardware {
            details.insert("\(requirement.type.rawValue) hardware (\(requirement.level.rawValue))")
        }
        for action in manifest.actions {
            switch action.binding {
            case .prompt:
                details.insert("model prompt generation")
            case .tool(let target, _):
                details.insert("native tool: \(target)")
            case .procedure(let id):
                details.insert("procedure: \(id)")
            case .gateway:
                details.insert("remote agent delegation")
            }
        }
        return details.sorted()
    }

    /// Streams the response into the already-protected file with a small rolling memory buffer.
    private static func streamDownload(
        from url: URL,
        stagingStore: SkillPackStagingStore
    ) async throws -> StagedSkillPackArchive {
        let staged = try stagingStore.createArchive()
        do {
            let profile: BoundedHTTPClient.Profile
            #if DEBUG
            profile = url.scheme?.lowercased() == "http" ? .internalSkillPack : .skillPack
            #else
            profile = .skillPack
            #endif
            let response = try await BoundedHTTPClient().fetch(url, profile: profile) { chunk in
                try stagingStore.append(chunk, to: staged)
            }
            guard (200...299).contains(response.statusCode) else { throw URLError(.badServerResponse) }
            return StagedSkillPackArchive(id: staged.id, fileURL: staged.fileURL, finalURL: response.finalURL)
        } catch {
            stagingStore.remove(staged)
            throw error
        }
    }
}
