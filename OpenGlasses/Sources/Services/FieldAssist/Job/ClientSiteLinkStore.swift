import Foundation

/// That one client in a connected system is one documented site in a vault (Plan MD §4): a
/// Workiz `CL-…` and the site document's id. Remembered when a technician chooses a documented
/// site for that client's job on New job, and read by `SiteSystemMatcher` as the location of
/// every later job for the client.
///
/// Identifiers only, plus the site's own label so the settings list can name it while its vault
/// is locked. Never the client's name, address or phone: those stay on the job.
struct ClientSiteLink: Codable, Equatable, Identifiable, Sendable {
    /// The connected system's token, `workiz` today.
    let system: String
    /// The client's id in that system.
    let clientID: String
    let vaultId: String
    let siteId: String
    /// The site's `location_label`, else its name, as it was when the link was made.
    let siteLabel: String
    let createdAt: Date

    var id: String { "\(system):\(clientID)@\(vaultId)" }

    var client: SiteSystemDocument.ExternalRef { .init(system: system, id: clientID) }

    enum CodingKeys: String, CodingKey {
        case system
        case clientID = "client_id"
        case vaultId = "vault_id"
        case siteId = "site_id"
        case siteLabel = "site_label"
        case createdAt = "created_at"
    }
}

/// Where remembered client sites live (Plan MD §4, P2).
///
/// One JSON file in Application Support beside the jobs ahead, loaded at construction and written
/// on every change — the same shape as `UpcomingJobStore`. Registered in `DataStoreRegistry` as
/// `clientSiteLinks`: a client id names a customer of the firm, so the file is protected and kept
/// out of backup, and it goes with the organisation's content when the phone leaves it.
///
/// **Phone-local, never sent.** Nothing here is written back to Workiz or any other system.
@MainActor
final class ClientSiteLinkStore: ObservableObject {

    static let shared = ClientSiteLinkStore()

    /// How many clients a phone remembers. A firm's regular customers are a few hundred at most.
    nonisolated static let entryCap = 500

    /// First-unlock, for the reason `UpcomingJobStore` gives: a job can start from a voice turn on
    /// a locked phone, and that start reads this file.
    nonisolated static let fileProtection = FileProtectionType.completeUntilFirstUserAuthentication

    @Published private(set) var links: [ClientSiteLink]
    private let fileURL: URL

    init(directory: URL? = nil) {
        let folder = directory ?? DeliveryQueueStore.defaultDirectory()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("client-site-links.json")
        links = Self.read(fileURL) ?? []
        protectFile()
    }

    // MARK: - Reading

    /// The remembered sites for this vault, keyed by the client — what the matcher reads.
    func siteIDs(vaultId: String) -> [SiteSystemDocument.ExternalRef: String] {
        Self.lookup(links, vaultId: vaultId)
    }

    nonisolated static func lookup(_ links: [ClientSiteLink],
                                   vaultId: String) -> [SiteSystemDocument.ExternalRef: String] {
        var result: [SiteSystemDocument.ExternalRef: String] = [:]
        for link in links where link.vaultId == vaultId { result[link.client] = link.siteId }
        return result
    }

    // MARK: - Mutations

    /// Remember that this client is this site in this vault. A client chosen again for another
    /// site is moved to it: the newest choice is the one kept.
    func remember(client: SiteSystemDocument.ExternalRef, vaultId: String, siteId: String,
                  siteLabel: String, at date: Date = Date()) {
        let link = ClientSiteLink(system: client.system, clientID: client.id, vaultId: vaultId,
                                  siteId: siteId, siteLabel: siteLabel, createdAt: date)
        links = Self.remembering(link, in: links)
        save()
    }

    /// The list with this link in it: any earlier link for the same client and vault replaced,
    /// newest first, and the oldest dropped past the cap.
    nonisolated static func remembering(_ link: ClientSiteLink, in links: [ClientSiteLink]) -> [ClientSiteLink] {
        let others = links.filter { $0.id != link.id }
        return Array(([link] + others).prefix(entryCap))
    }

    /// Forget one link, from the settings list.
    func forget(id: String) {
        guard links.contains(where: { $0.id == id }) else { return }
        links.removeAll { $0.id == id }
        save()
    }

    /// Everything, for a wipe — what the registry's "delete all" column names.
    func removeAll() {
        links = []
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - Storage

    private static func read(_ url: URL) -> [ClientSiteLink]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode([ClientSiteLink].self, from: data)
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(links) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        protectFile()
    }

    /// First-unlock protection and no backup: a restored copy would match jobs this phone never
    /// chose a site for.
    private func protectFile() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try? FileManager.default.setAttributes(
            [.protectionKey: Self.fileProtection], ofItemAtPath: fileURL.path)
        var url = fileURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}
