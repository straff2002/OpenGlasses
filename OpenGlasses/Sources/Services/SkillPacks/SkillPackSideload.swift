import Foundation

/// Plan BX P3 — the sideload/dev loop: `openglasses://skillpack?url=<zip>&sig=<base64>` from a QR
/// code or link installs a pack after an explicit in-app confirmation.
///
/// # Trust posture
///
/// A QR-scanned link cannot carry the `DeepLinkTrust` app-group token (it doesn't come from a
/// first-party widget), so this host deliberately is NOT token-gated. The compensating control is
/// that the link never *acts*: it fetches, verifies what it can, and presents a confirmation with
/// the pack's identity and signature status — the human is the gate. On top of that:
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
        case insecureSource(String)
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
            return .failure(.insecureSource(packURL.absoluteString))
        }
        let signature = items.first(where: { $0.name == "sig" })?.value
        return .success(SkillPackSideloadRequest(packURL: packURL, signature: signature))
    }

    /// HTTPS anywhere; plain HTTP only to hosts that cannot be on the public internet.
    static func isPermittedSource(_ url: URL) -> Bool {
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

/// Fetches a sideloaded pack, previews it, and holds the pending install for the confirmation UI.
@MainActor
final class SkillPackSideloadService: ObservableObject {

    /// What the confirmation alert shows and acts on.
    struct PendingInstall: Identifiable, Equatable {
        let id = UUID()
        let name: String
        let version: String
        let summary: String
        let actionCount: Int
        let signed: Bool
        let decodeSummary: String
        let manifestData: Data
        let files: [String: Data]
        let signature: String?

        static func == (lhs: PendingInstall, rhs: PendingInstall) -> Bool { lhs.id == rhs.id }

        var confirmationMessage: String {
            var lines = ["\(name) v\(version)"]
            if !summary.isEmpty { lines.append(summary) }
            lines.append("\(actionCount) action\(actionCount == 1 ? "" : "s")")
            lines.append(signed ? "Signature will be verified on install."
                                : "UNSIGNED — developer-mode install.")
            if decodeSummary != "clean" { lines.append("Partial: \(decodeSummary)") }
            return lines.joined(separator: "\n")
        }
    }

    enum Prompt: Identifiable, Equatable {
        case confirm(PendingInstall)
        case error(String)
        case installed(String)

        var id: String {
            switch self {
            case .confirm(let pending): return pending.id.uuidString
            case .error(let message): return "error-\(message)"
            case .installed(let message): return "ok-\(message)"
            }
        }
    }

    @Published var prompt: Prompt?

    private let store: SkillPackStore
    private let fetch: (URL) async throws -> Data
    private let onInstalled: () -> Void

    init(
        store: SkillPackStore,
        fetch: @escaping (URL) async throws -> Data = { url in
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
            return data
        },
        onInstalled: @escaping () -> Void = {}
    ) {
        self.store = store
        self.fetch = fetch
        self.onInstalled = onInstalled
    }

    /// Fetch + preview. Never installs — that's `confirm(_:)`, behind the user's tap.
    func handle(_ request: SkillPackSideloadRequest) async {
        let zipData: Data
        do {
            zipData = try await fetch(request.packURL)
        } catch {
            prompt = .error("Couldn't fetch the pack: \(error.localizedDescription)")
            return
        }
        guard case .success(let (manifestData, files)) = SkillPackArchive.extract(zipData: zipData) else {
            prompt = .error("That link isn't a readable skill pack archive.")
            return
        }
        let (decoded, report) = SkillPackManifest.lossyDecode(manifestData)
        guard let manifest = decoded else {
            prompt = .error("The pack's manifest is unreadable.")
            return
        }
        if request.signature == nil, !Config.skillPackDevModeEnabled {
            prompt = .error("This pack is unsigned. Turn on Developer Mode in Settings → Skill Packs to sideload unsigned packs.")
            return
        }
        prompt = .confirm(PendingInstall(
            name: manifest.name,
            version: manifest.version,
            summary: manifest.summary,
            actionCount: manifest.actions.count,
            signed: request.signature != nil,
            decodeSummary: report.summary,
            manifestData: manifestData,
            files: files,
            signature: request.signature))
    }

    /// The user tapped Install on the confirmation.
    func confirm(_ pending: PendingInstall) {
        switch store.install(
            manifestData: pending.manifestData,
            files: pending.files,
            signatureBase64: pending.signature,
            developerMode: Config.skillPackDevModeEnabled
        ) {
        case .installed(let warnings):
            onInstalled()
            prompt = .installed(warnings.isEmpty
                ? "\(pending.name) installed."
                : "\(pending.name) installed — \(warnings.joined(separator: "; "))")
        case .rejected(let reasons):
            prompt = .error("Install refused: \(reasons.joined(separator: "; "))")
        }
    }

    func dismiss() { prompt = nil }
}
