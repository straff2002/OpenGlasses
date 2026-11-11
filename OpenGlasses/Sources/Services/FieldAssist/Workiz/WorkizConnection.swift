import Foundation
import Combine

/// Key and technician choice share one atomic, device-only Keychain item. No profile or defaults
/// may carry the key readable: a profile carries it only sealed (`OrgCredentialSync` writes it here).
/// WorkizConnection is registered with DataStoreRegistry as workizConnection.
struct WorkizCredential: Codable {
    var key: String
    var generation = UUID().uuidString
    var technicianID: String?
    var technicianName: String?
    /// The organisation whose profile supplied the key. Nil for a key pasted on this phone.
    var managedBy: String?
    /// The technician answered "Which one are you?" for a key the profile supplied: their name and
    /// technician ID were set from Workiz once, and only an administrator changes them.
    var technicianConfirmed: Bool?
}
@MainActor
final class WorkizConnection: ObservableObject {
    nonisolated static let keychainAccount = "workizDirectCredential"
    struct Storage {
        var read: () throws -> Data? = { try KeychainService.readData(for: keychainAccount) }
        var write: (Data) throws -> Void = { try KeychainService.upsertDataAtomically($0, for: keychainAccount, accessibility: .afterFirstUnlockThisDeviceOnly) }
        var erase: () throws -> Void = { try KeychainService.deleteItem(keychainAccount) }
        var needsNewKey: () -> Bool = { UserDefaults.standard.bool(forKey: "workizNeedsNewKey") }
        var setNeedsNewKey: (Bool) -> Void = { UserDefaults.standard.set($0, forKey: "workizNeedsNewKey") }
    }
    private let storage: Storage
    private let licensed: () -> Bool
    @Published private(set) var credential: WorkizCredential?
    @Published private(set) var problem: String?
    @Published private(set) var revision = 0
    init(storage: Storage = Storage(), licensed: @escaping () -> Bool = { Config.fieldAssistUnlocked }) {
        self.storage = storage; self.licensed = licensed
        do { if !storage.needsNewKey(), let data = try storage.read() { credential = try JSONDecoder().decode(WorkizCredential.self, from: data) } }
        catch { problem = "Unlock this phone to read the Workiz connection." }
    }
    static func forApp() -> WorkizConnection {
        #if DEBUG
        if UITestSupport.isSet(.workizFixture) {
            var memory: Data? = nil
            if WorkizFixtureTransport.state != "empty" {
                var value = WorkizCredential(key: "synthetic-fixture-key")
                value.technicianID = "USR-jamie"; value.technicianName = "Jamie Lee"
                memory = try? JSONEncoder().encode(value)
            }
            return WorkizConnection(storage: Storage(read: { memory }, write: { memory = $0 }, erase: { memory = nil }, needsNewKey: { false }, setNeedsNewKey: { _ in }))
        }
        #endif
        return WorkizConnection()
    }
    var isRunning: Bool { credential != nil && enabled && !officeRoute && licensed() }
    var officeRoute: Bool { PolicyEnvelope.string(.organizationFieldServiceRoute, stored: "") == "office" }
    var enabled: Bool { PolicyEnvelope.bool(.workizEnabled, stored: UserDefaults.standard.object(forKey: "workizEnabled") as? Bool ?? true) }
    var fieldName: String { PolicyEnvelope.string(.workizReportFieldName, stored: UserDefaults.standard.string(forKey: "workizReportFieldName") ?? WorkizWriteBack.defaultFieldName) }
    var clientNotes: Bool { PolicyEnvelope.bool(.workizClientNotes, stored: UserDefaults.standard.bool(forKey: "workizClientNotes")) }
    var timeZone: TimeZone { TimeZone(identifier: UserDefaults.standard.string(forKey: "workizAccountTimeZone") ?? "") ?? .current }
    /// The key came from the organisation's profile, not from this phone.
    var isManagedKey: Bool { credential?.managedBy != nil }
    /// The last four characters, for an administrator only ("Key set · ends in …a1b2"). Never the key.
    var keyEnding: String? { credential.map { String($0.key.suffix(4)) } }
    /// Name and technician ID were confirmed from Workiz for a profile-supplied key, so they are set once.
    var technicianPinned: Bool { isManagedKey && credential?.technicianConfirmed == true && credential?.technicianID != nil }
    /// "Which one are you?" is waiting: a profile-supplied key with nobody confirmed yet.
    var needsTechnicianConfirmation: Bool { isManagedKey && !technicianPinned }
    /// The save path checks the administrator session too: disabling a SecureField alone is not a gate.
    func pasteKey(_ key: String, administrator: Bool) throws {
        guard !officeRoute, !PolicyEnvelope.isManaged || administrator else { throw WorkizFailure.disabled }
        let cleaned = key.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try WorkizAPI.request(.users, key: cleaned)
        var next = WorkizCredential(key: cleaned)
        next.technicianID = credential?.technicianID; next.technicianName = credential?.technicianName
        try commit(next)
    }
    /// Written with no prompt: the organisation's partner set this key centrally. The technician
    /// choice carries over, so a replaced key for the same Workiz account keeps who the technician
    /// is; `WorkizController.testConnection` clears an ID the new key's account does not have.
    /// Returns whether anything changed.
    @discardableResult
    func setManagedKey(_ key: String, organization: String) throws -> Bool {
        guard !officeRoute else { throw WorkizFailure.disabled }
        if let current = credential, current.key == key, current.managedBy == organization { return false }
        _ = try WorkizAPI.request(.users, key: key)
        var next = WorkizCredential(key: key)
        next.managedBy = organization
        next.technicianID = credential?.technicianID; next.technicianName = credential?.technicianName
        next.technicianConfirmed = credential?.technicianConfirmed
        try commit(next)
        return true
    }
    /// The profile stopped carrying a key: the one it supplied goes. A pasted key stays.
    @discardableResult
    func removeManagedKey() throws -> Bool {
        guard isManagedKey else { return false }
        try remove()
        return true
    }
    /// Once a profile-supplied key's technician is confirmed, only an administrator chooses again.
    func select(_ user: WorkizUser, confirmed: Bool = false, administrator: Bool = false) throws {
        guard var next = credential, !officeRoute, user.active, user.fieldTech,
              !technicianPinned || administrator else { throw WorkizFailure.disabled }
        next.technicianID = user.id; next.technicianName = user.name
        if confirmed { next.technicianConfirmed = true }
        try commit(next)
    }
    func clearTechnician() throws {
        guard var next = credential else { return }
        next.technicianID = nil; next.technicianName = nil; next.technicianConfirmed = nil; try commit(next)
    }
    private func commit(_ next: WorkizCredential) throws {
        try storage.write(JSONEncoder().encode(next))
        storage.setNeedsNewKey(false)
        credential = next; problem = nil; revision += 1
    }
    /// Erasure failures keep the connector stopped and are retried on every policy change/launch.
    func remove() throws {
        storage.setNeedsNewKey(true)
        credential = nil; revision += 1
        do { try storage.erase(); problem = nil }
        catch { problem = "Workiz is stopped. Unlock this phone to finish removing its key."; throw error }
    }
}

@MainActor
protocol WorkizTransport: AnyObject {
    func send(_ request: URLRequest) async throws -> (Data, Int)
    func cancel()
}
/// A dedicated ephemeral session, with no cookies, cache, redirects or arbitrary endpoints.
final class URLSessionWorkizTransport: NSObject, WorkizTransport, URLSessionTaskDelegate {
    private var session: URLSession!
    override init() {
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        try MedicalEgressGuard.check(.workizAPI)
        guard request.url?.host == WorkizAPI.baseURL.host, request.url?.scheme == "https" else { throw WorkizFailure.disabled }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw WorkizFailure.malformed }
            var data = Data()
            for try await byte in bytes {
                guard data.count < WorkizAPI.maximumBytes else { throw WorkizFailure.malformed }
                data.append(byte)
            }
            return (data, http.statusCode)
        } catch let error as WorkizFailure { throw error }
        catch { throw WorkizFailure.offline }
    }
    func cancel() { session.invalidateAndCancel() }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

@MainActor
final class WorkizAPIClient {
    let connection: WorkizConnection
    private var transport: WorkizTransport
    private let makeTransport: @MainActor () -> WorkizTransport
    static func appTransport() -> WorkizTransport {
        #if DEBUG
        if UITestSupport.isSet(.workizFixture) { return WorkizFixtureTransport() }
        #endif
        return URLSessionWorkizTransport()
    }
    init(connection: WorkizConnection, transport: @escaping @MainActor () -> WorkizTransport = { WorkizAPIClient.appTransport() }) {
        self.connection = connection; makeTransport = transport; self.transport = transport()
    }
    func cancel() { transport.cancel(); transport = makeTransport() }
    func get(_ resource: WorkizAPI.Resource, query: [URLQueryItem] = [], method: String = "GET", body: Data? = nil) async throws -> Data {
        guard connection.isRunning, let credential = connection.credential else { throw WorkizFailure.disabled }
        try MedicalEgressGuard.check(.workizAPI)
        let request = try WorkizAPI.request(resource, key: credential.key, query: query, method: method, body: body)
        let result: (Data, Int)
        do { result = try await transport.send(request) }
        catch let failure as WorkizFailure { throw failure }
        catch { throw WorkizFailure.offline }
        guard connection.isRunning, connection.credential?.generation == credential.generation else { throw WorkizFailure.disabled }
        if let failure = WorkizFailure.status(result.1, resource: resource.permission) { throw failure }
        return result.0
    }
    func pages<T>(_ resource: WorkizAPI.Resource, query: [URLQueryItem] = [], decode: ([String: Any]) -> T?) async throws -> [T] {
        var result: [T] = []
        for page in 1...WorkizAPI.pageBudget {
            let data = try await get(resource, query: query + [.init(name: "pageSize", value: "100"), .init(name: "page", value: String(page))])
            let response = try WorkizAPI.page(data, decode: decode)
            // Never reconcile a partial snapshot or silently discard a malformed assignment.
            guard response.dropped == 0 else { throw WorkizFailure.malformed }
            result += response.data
            if !response.hasMore { return result }
        }
        throw WorkizFailure.pageBudget
    }
}

@MainActor
final class WorkizController: ObservableObject {
    let connection: WorkizConnection
    let client: WorkizAPIClient
    private let jobs: UpcomingJobStore
    private let started: () -> Set<String>
    @Published private(set) var message: String?
    @Published private(set) var connectionMessage: String?
    @Published private(set) var testing = false
    @Published private(set) var refreshing = false
    @Published private(set) var users: [WorkizUser] = []
    private var pendingRefresh = false
    init(connection: WorkizConnection, jobs: UpcomingJobStore, client: WorkizAPIClient? = nil, started: @escaping () -> Set<String> = { [] }) {
        self.connection = connection; self.jobs = jobs; self.client = client ?? WorkizAPIClient(connection: connection); self.started = started
        enforceRoute()
    }
    func enforceRoute() {
        guard connection.officeRoute else { return }
        client.cancel(); try? connection.remove(); users = []; message = nil; connectionMessage = nil
        jobs.removeWorkizJobs()
    }
    func remove() {
        client.cancel(); try? connection.remove(); users = []; jobs.removeWorkizJobs()
        message = connection.problem; connectionMessage = nil
    }
    func keyChanged() { client.cancel(); jobs.removeWorkizJobs(); users = []; message = nil; connectionMessage = nil }
    func choose(_ user: WorkizUser) async throws {
        client.cancel(); try connection.select(user); jobs.removeWorkizJobs()
        await refresh(force: true)
    }
    /// "Which one are you?" answered for a key the profile supplied, after the one-time confirmation:
    /// the Field Assist technician name and ID are filled from Workiz. Every other field stays the
    /// technician's to edit.
    func confirm(_ user: WorkizUser, administrator: Bool = false) async throws {
        client.cancel(); try connection.select(user, confirmed: true, administrator: administrator); jobs.removeWorkizJobs()
        fillIdentity(user)
        await refresh(force: true)
    }
    /// An administrator lets the technician answer "Which one are you?" again.
    func chooseAgain() throws {
        client.cancel(); try connection.clearTechnician(); jobs.removeWorkizJobs()
    }
    var fillIdentity: (WorkizUser) -> Void = { user in
        Config.technicianFullName = user.name
        Config.technicianID = user.id
    }
    func testConnection() async {
        guard !testing else { return }; testing = true; defer { testing = false }
        do {
            _ = try await client.get(.users, query: [.init(name: "pageSize", value: "1")])
            _ = try await client.get(.jobs, query: [.init(name: "pageSize", value: "1")])
            let fields = try await client.pages(.customFields, decode: WorkizAPI.field)
            _ = try WorkizWriteBack.field(fields, named: connection.fieldName)
            users = try await client.pages(.users, decode: WorkizAPI.user).filter { $0.active && $0.fieldTech }
            if let id = connection.credential?.technicianID, !users.contains(where: { $0.id == id }) {
                try connection.clearTechnician(); jobs.removeWorkizJobs()
            }
            // A key the profile supplied asks "Which one are you?" and is confirmed once; it is never guessed.
            if connection.credential?.technicianID == nil, !connection.isManagedKey {
                let name = Config.technicianFullName.trimmingCharacters(in: .whitespacesAndNewlines)
                let matches = users.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
                if matches.count == 1, let match = matches.first { try connection.select(match) }
            }
            connectionMessage = "Connected to Workiz. Jobs ✓ Users ✓ Report field ✓ — client notes \(connection.clientNotes ? "on" : "off"). Write access is checked on the first send."
            await refresh(force: true)
        } catch { connectionMessage = (error as? WorkizFailure)?.localizedDescription ?? "The Workiz connection could not be saved." }
    }
    func refresh(force: Bool = false, now: Date = Date()) async {
        enforceRoute()
        if refreshing { if force { pendingRefresh = true }; return }
        guard connection.isRunning, let technician = connection.credential?.technicianID,
              force || jobs.workizLastPull.map({ now.timeIntervalSince($0) >= 600 }) ?? true else { return }
        refreshing = true
        defer {
            refreshing = false
            if pendingRefresh { pendingRefresh = false; Task { await self.refresh(force: true) } }
        }
        let generation = connection.credential?.generation
        do {
            var fetched: [WorkizJob] = []
            for query in WorkizMyJobs.queries(now: now, timeZone: connection.timeZone) {
                fetched += try await client.pages(.jobs, query: query, decode: WorkizAPI.job)
            }
            guard connection.isRunning, connection.credential?.generation == generation, connection.credential?.technicianID == technician else { return }
            let selected = WorkizMyJobs.select(fetched, technicianID: technician, now: now, timeZone: connection.timeZone, cap: UpcomingJobStore.entryCap)
                .filter { !started().contains($0.id) }
            let old = jobs.jobs.filter { $0.provenance?.connector == "workiz" }
            let ids = Set(selected.map(\.id))
            for previous in old {
                if let id = previous.provenance?.external?.jobID, !ids.contains(id), !fetched.contains(where: { $0.id == id }) {
                    do { fetched.append(try WorkizAPI.job(await client.get(.job(id)))) }
                    catch WorkizFailure.notFound { /* deleted jobs leave the ahead list */ }
                }
            }
            guard connection.isRunning, connection.credential?.generation == generation, connection.credential?.technicianID == technician else { return }
            let cancelled = old.filter { job in
                guard let id = job.provenance?.external?.jobID, !ids.contains(id) else { return false }
                return fetched.last(where: { $0.id == id })?.isCancelled == true
            }.map { "Job \($0.jobReference ?? "") was cancelled in Workiz." }
            jobs.reconcileWorkiz(selected.map { WorkizJobMapper.map($0, technicianID: technician, now: now, timeZone: connection.timeZone) }, at: now, notice: (Array(cancelled.prefix(3)) + (cancelled.count > 3 ? ["And \(cancelled.count - 3) more jobs were cancelled in Workiz."] : [])).joined(separator: "\n"))
            message = nil
        } catch { message = (error as? WorkizFailure)?.localizedDescription ?? WorkizFailure.offline.localizedDescription }
    }
}
