import XCTest
@testable import OpenGlasses

/// Plan MD P2 — the sites this phone remembers for Workiz clients: one per client per vault, the
/// newest choice kept, read per vault, and a protected file that is not backed up.
@MainActor
final class ClientSiteLinkStoreTests: XCTestCase {

    private var directory: URL!
    private let client = SiteSystemDocument.ExternalRef(system: "workiz", id: "CL-1042")

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClientSiteLinkStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func link(_ clientID: String, vault: String = "v1", site: String,
                      at seconds: TimeInterval = 0) -> ClientSiteLink {
        ClientSiteLink(system: "workiz", clientID: clientID, vaultId: vault, siteId: site,
                       siteLabel: "Site \(site)", createdAt: Date(timeIntervalSince1970: seconds))
    }

    // MARK: - Pure

    func testChoosingAClientAgainMovesItToTheNewSite() {
        var links = ClientSiteLinkStore.remembering(link("CL-1042", site: "a"), in: [])
        links = ClientSiteLinkStore.remembering(link("CL-7", site: "b"), in: links)
        links = ClientSiteLinkStore.remembering(link("CL-1042", site: "c", at: 9), in: links)
        XCTAssertEqual(links.map(\.clientID), ["CL-1042", "CL-7"])
        XCTAssertEqual(links.first?.siteId, "c")
    }

    func testTheLookupIsPerVault() {
        let links = [link("CL-1042", vault: "v1", site: "a"), link("CL-1042", vault: "v2", site: "b")]
        XCTAssertEqual(ClientSiteLinkStore.lookup(links, vaultId: "v1"), [client: "a"])
        XCTAssertEqual(ClientSiteLinkStore.lookup(links, vaultId: "v2"), [client: "b"])
        XCTAssertEqual(ClientSiteLinkStore.lookup(links, vaultId: "v3"), [:])
    }

    func testTheOldestLinkGoesPastTheCap() {
        var links: [ClientSiteLink] = []
        for index in 0...ClientSiteLinkStore.entryCap {
            links = ClientSiteLinkStore.remembering(link("CL-\(index)", site: "s"), in: links)
        }
        XCTAssertEqual(links.count, ClientSiteLinkStore.entryCap)
        XCTAssertFalse(links.contains { $0.clientID == "CL-0" })
        XCTAssertEqual(links.first?.clientID, "CL-\(ClientSiteLinkStore.entryCap)")
    }

    // MARK: - On disk

    func testLinksSurviveARelaunchAndCanBeForgotten() throws {
        let store = ClientSiteLinkStore(directory: directory)
        store.remember(client: client, vaultId: "v1", siteId: "elm-road", siteLabel: "Elm Road")
        let reopened = ClientSiteLinkStore(directory: directory)
        XCTAssertEqual(reopened.siteIDs(vaultId: "v1"), [client: "elm-road"])
        XCTAssertEqual(reopened.links.first?.siteLabel, "Elm Road")

        reopened.forget(id: try XCTUnwrap(reopened.links.first).id)
        XCTAssertEqual(ClientSiteLinkStore(directory: directory).links, [])
    }

    func testTheFileHoldsIdentifiersOnlyAndIsNotBackedUp() throws {
        let store = ClientSiteLinkStore(directory: directory)
        store.remember(client: client, vaultId: "v1", siteId: "elm-road", siteLabel: "Elm Road")
        let url = directory.appendingPathComponent("client-site-links.json")
        let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
        let rows = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        XCTAssertEqual(Set(try XCTUnwrap(rows.first).keys),
                       ["system", "client_id", "vault_id", "site_id", "site_label", "created_at"])
    }

    func testRemoveAllLeavesNothing() {
        let store = ClientSiteLinkStore(directory: directory)
        store.remember(client: client, vaultId: "v1", siteId: "elm-road", siteLabel: "Elm Road")
        store.removeAll()
        XCTAssertEqual(store.links, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("client-site-links.json").path))
        XCTAssertEqual(ClientSiteLinkStore(directory: directory).links, [])
    }
}
