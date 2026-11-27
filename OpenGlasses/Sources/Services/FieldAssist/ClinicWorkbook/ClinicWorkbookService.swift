import AuthenticationServices
import Foundation
import UIKit

/// Whether a clinical list may use the workbook route now (Plan NK §4). Pure. **A van's list never
/// does:** nothing is planned, queued or delivered for a list that is not a clinic's.
enum ClinicStockRouteGate: Equatable, Sendable {
    case allowed
    /// The list is a van's (or a store's): the route is a clinic's only.
    case notClinical
    /// This build carries no client id and the clinic entered none.
    case notSetUp
    case signedOut
    case noWorkbook

    init(clinical: Bool, client: EntraOAuth.Client, signedIn: Bool, workbook: GraphWorkbook?) {
        if !clinical { self = .notClinical }
        else if client == .notSetUp { self = .notSetUp }
        else if !signedIn { self = .signedOut }
        else if workbook == nil { self = .noWorkbook }
        else { self = .allowed }
    }

    var allows: Bool { self == .allowed }

    /// Why the workbook isn't in use, for the screen.
    var sentence: String? {
        switch self {
        case .allowed: return nil
        case .notClinical:
            return String(localized: "The clinic's workbook is for a clinic's stock list only.",
                          comment: "The shared workbook is refused for a list that is not a clinic's.")
        case .notSetUp:
            return String(localized: "Sharing the count through the clinic's Microsoft 365 isn't set up in this build. A clinic that registered its own app can enter its client ID below.",
                          comment: "The clinic workbook has no app registration in this build.")
        case .signedOut:
            return String(localized: "Not signed in to the clinic's Microsoft 365.", comment: "The clinic workbook is signed out.")
        case .noWorkbook:
            return String(localized: "No workbook chosen yet.", comment: "The clinic workbook has no workbook chosen.")
        }
    }
}

/// When the phone sends (Decision 3): at the end of the daily check, on demand, and on the first
/// launch of a day the last send was before. Never per movement. Pure.
enum ClinicStockSendPolicy {
    enum Reason: String, Sendable {
        case dailyCheck
        case onDemand
        case launch
    }

    /// A launch sends when nothing was planned yet today.
    static func isDueOnLaunch(lastPlanned: StockDay?, today: StockDay) -> Bool {
        lastPlanned.map { $0 < today } ?? true
    }
}

/// The support report's lines for the workbook (Plan NK P1): counts and the workbook's name only.
/// No token, no link, no account, no figure.
enum ClinicStockWorkbookReportLines {
    static func lines(gate: ClinicStockRouteGate, workbookName: String?, lastSentAt: Date?, rowsQueued: Int,
                      notice: TenantCountryNotice?) -> [String] {
        let connected = gate == .allowed
        var line = "Clinic workbook: " + (connected ? "connected" : "not connected (\(gate))")
        if connected, let workbookName { line += ", workbook \u{201C}\(workbookName)\u{201D}" }
        let sent = lastSentAt.map { ISO8601DateFormatter().string(from: $0) } ?? "never"
        line += ", last send \(sent), rows queued \(rowsQueued)"
        if let notice, notice != .none { line += ", country notice shown" }
        return [line]
    }
}

/// The clinic's shared stock count in its own Microsoft 365 workbook (Plan NK P1): the sign-in, the
/// workbook chosen, the shared figure beside the phone's own, and the sends. The edge over the
/// pure pieces; the queue's sink is `ClinicStockSyncSink`.
@MainActor
final class ClinicWorkbookService: NSObject, ObservableObject {

    struct Seams {
        var transport: any ClinicWorkbookTransport = URLSessionClinicWorkbookTransport()
        var bundledClientID: () -> String? = { Bundle.main.object(forInfoDictionaryKey: EntraOAuth.bundledClientIDKey) as? String }
        var clinicClientID: () -> String? = { UserDefaults.standard.string(forKey: ClinicWorkbookConnectionStore.clinicClientIDKey) }
        var setClinicClientID: (String?) -> Void = { UserDefaults.standard.set($0, forKey: ClinicWorkbookConnectionStore.clinicClientIDKey) }
        var lastPlanned: () -> String? = { UserDefaults.standard.string(forKey: ClinicWorkbookService.lastPlannedKey) }
        var setLastPlanned: (String) -> Void = { UserDefaults.standard.set($0, forKey: ClinicWorkbookService.lastPlannedKey) }
        var stock: @MainActor () -> (log: VanStockLog, clinical: Bool, readable: Bool) = {
            let store = VanStockStore.shared
            return (store.log, store.resolvedClinical.clinical, !store.isUnreadable)
        }
        var now: () -> Date = { Date() }
        var calendar: Calendar = .current
        var makeID: () -> String = { UUID().uuidString }
    }

    nonisolated static let lastPlannedKey = "clinicStockWorkbookLastPlannedDay"

    @Published private(set) var record: ClinicWorkbookConnectionRecord?
    @Published private(set) var comparison: ClinicalStockComparison?
    @Published private(set) var lastReadAt: Date?
    /// A plain sentence for the last thing that went wrong, or a refusal.
    @Published private(set) var problem: String?
    @Published private(set) var busy = false
    /// Rows the last read could not understand.
    @Published private(set) var skippedRows = 0

    let store: ClinicWorkbookConnectionStore
    private var seams: Seams
    /// Set by the app: the queue's sink and a flush.
    var sink: ClinicStockSyncSink?
    var flush: () async -> Void = {}

    private var refreshTask: Task<String?, Error>?
    private var activeSession: ASWebAuthenticationSession?

    init(store: ClinicWorkbookConnectionStore? = nil, seams: Seams = Seams()) {
        let store = store ?? ClinicWorkbookConnectionStore()
        self.store = store
        self.seams = seams
        super.init()
        record = store.record
    }

    // MARK: - State

    var client: EntraOAuth.Client { EntraOAuth.client(bundled: seams.bundledClientID(), clinic: seams.clinicClientID()) }
    var clinicClientID: String { seams.clinicClientID() ?? "" }

    var gate: ClinicStockRouteGate {
        ClinicStockRouteGate(clinical: seams.stock().clinical, client: client, signedIn: record != nil, workbook: record?.workbook)
    }

    var notice: TenantCountryNotice? { record.map { TenantCountryNotice(countryLetterCode: $0.country) } }

    var rowsQueued: Int { sink?.rowsQueued ?? 0 }

    var reportLines: [String] {
        ClinicStockWorkbookReportLines.lines(gate: gate, workbookName: record?.workbookName, lastSentAt: record?.lastSentAt,
                                             rowsQueued: rowsQueued, notice: notice)
    }

    /// The clinic's own client id, or none to use the build's. Signs out when it changes.
    func setClinicClientID(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.isEmpty ? nil : trimmed
        guard value != seams.clinicClientID() else { return }
        if record != nil { signOut() }
        seams.setClinicClientID(value)
        objectWillChange.send()
    }

    // MARK: - The client the queue and the screens use

    /// The calls on the chosen workbook, with this connection's tokens. Nil while signed out.
    func makeClient() -> ClinicWorkbookClient? {
        guard record != nil else { return nil }
        return ClinicWorkbookClient(
            transport: seams.transport, workbook: record?.workbook,
            token: { [weak self] in
                guard let token = try await self?.validToken() else { throw ClinicWorkbookFailure.unauthorized }
                return token
            },
            tokenAfterRejecting: { [weak self] rejected in try await self?.token(afterRejecting: rejected) })
    }

    /// The sink's view of the connection.
    func queueConnection() -> ClinicStockSyncSink.Connection {
        switch gate {
        case .allowed: return makeClient().map { .connected($0) } ?? .removed
        case .notClinical, .notSetUp, .signedOut, .noWorkbook: return .removed
        }
    }

    // MARK: - Sign-in

    /// Sign in through the browser. True on success; a failure lands in `problem`.
    @discardableResult
    func signIn() async -> Bool {
        guard let clientID = client.id else {
            problem = ClinicStockRouteGate.notSetUp.sentence
            return false
        }
        let verifier = PKCE.makeVerifier()
        let state = PKCE.makeVerifier()
        guard let url = EntraOAuth.authorizeURL(clientID: clientID, verifier: verifier, state: state) else { return false }
        busy = true
        defer { busy = false }
        do {
            let callback = try await runBrowserSession(url: url)
            switch EntraOAuth.parseCallback(callback, expectedState: state) {
            case .invalid:
                problem = EntraOAuth.refusalSentence("invalid")
                return false
            case .refused(let code):
                problem = EntraOAuth.refusalSentence(code)
                return false
            case .code(let code):
                let response = try await tokenCall(EntraOAuth.tokenRequest(clientID: clientID, code: code, verifier: verifier))
                var record = ClinicWorkbookConnectionRecord(
                    clientID: clientID, credentials: EntraOAuth.Credentials(response: response, now: seams.now()),
                    account: nil, workbook: nil, workbookName: nil, country: nil, lastSentAt: nil)
                guard store.save(record) else {
                    problem = String(localized: "The sign-in couldn't be kept on this phone. Try again.",
                                     comment: "The clinic workbook tokens could not be saved to the Keychain.")
                    return false
                }
                self.record = record
                // Who, and where the organisation keeps its data: read once, shown, never a block.
                if let client = makeClient() {
                    record.account = try? await client.account()
                    record.country = try? await client.country()
                    store.save(record)
                    self.record = record
                }
                problem = nil
                return true
            }
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            return false
        } catch let failure as ClinicWorkbookFailure {
            problem = failure.sentence
            return false
        } catch {
            problem = EntraOAuth.refusalSentence("unknown")
            return false
        }
    }

    /// Sign out: the tokens and the workbook choice go; what is queued ends and is made again by
    /// the next send.
    func signOut() {
        refreshTask?.cancel()
        refreshTask = nil
        sink?.endAll()
        store.signOut()
        record = nil
        comparison = nil
        lastReadAt = nil
        problem = nil
    }

    // MARK: - The workbook

    /// Find the workbook from its sharing link, make its two tables if they are missing, and keep
    /// it. A workbook that already holds this phone's rows (a new install) rebuilds the ledger from
    /// them, so nothing is added twice.
    @discardableResult
    func choose(link: String) async -> Bool {
        guard var record, let base = makeClient() else { return false }
        busy = true
        defer { busy = false }
        do {
            let item = try await base.resolve(link: link)
            let client = ClinicWorkbookClient(transport: seams.transport, workbook: item.workbook, token: base.token,
                                              tokenAfterRejecting: base.tokenAfterRejecting)
            try await client.ensureTables()
            if record.workbook != item.workbook { sink?.endAll() }
            record.workbook = item.workbook
            record.workbookName = item.name
            guard store.save(record) else { return false }
            self.record = record
            problem = nil
            await refresh()
            return true
        } catch let setup as ClinicWorkbookSetupError {
            problem = setup.sentence
        } catch let failure as ClinicWorkbookFailure {
            problem = failure.sentence
        } catch is MedicalEgressRefusal {
            problem = MedicalEgressRefusal.userMessage
        } catch {
            problem = ClinicWorkbookFailure.malformedResponse.sentence
        }
        return false
    }

    /// Read both tables back, fold them, and set the shared figure beside the phone's own.
    func refresh() async {
        guard gate.allows, let client = makeClient(), let workbook = record?.workbook else { return }
        do {
            switch try await client.read() {
            case .failure(let refusal):
                comparison = nil
                problem = refusal.sentence
            case .success(let read):
                let stock = seams.stock()
                comparison = ClinicalStockComparison.compare(shared: ClinicalStockWorkbookFold.fold(read.entries),
                                                             own: ClinicalStockWorkbookFold.own(stock.log))
                skippedRows = read.skipped
                lastReadAt = seams.now()
                problem = nil
                // A phone whose ledger is empty (a new install) takes what the workbook already
                // holds from its own seat, so a send never adds those rows again.
                var ledger = store.ledger(for: workbook)
                if ledger.entries.isEmpty {
                    let rows = ClinicalStockShare.rows(stock.log, calendar: seams.calendar)
                    let seat = store.seat()
                    let byKey = Dictionary(rows.map { (ClinicalStockRowKey.base($0, seat: seat), $0) },
                                           uniquingKeysWith: { first, _ in first })
                    let rowsByKey = Dictionary(read.entries.compactMap { entry -> (String, ClinicalStockShareRow)? in
                        guard let key = entry.key, let base = ClinicalStockRowKey.parse(key)?.base, let row = byKey[base] else { return nil }
                        return (key, row)
                    }, uniquingKeysWith: { first, _ in first })
                    ledger = ClinicalStockSendLedger.rebuilt(from: read.entries, rowsByKey: rowsByKey, seat: seat)
                    if !ledger.entries.isEmpty { store.saveLedger(ledger, for: workbook) }
                }
            }
        } catch let failure as ClinicWorkbookFailure {
            problem = failure.sentence
        } catch is MedicalEgressRefusal {
            problem = MedicalEgressRefusal.userMessage
        } catch {
            problem = ClinicWorkbookFailure.malformedResponse.sentence
        }
    }

    // MARK: - Sending (Decision 3)

    /// Plan the rows the workbook does not have yet and queue them. The number of rows queued; 0
    /// when nothing changed, or the route is not open for this list.
    @discardableResult
    func send(_ reason: ClinicStockSendPolicy.Reason) async -> Int {
        let stock = seams.stock()
        guard gate.allows, stock.readable, let workbook = record?.workbook, let sink else { return 0 }
        let now = seams.now()
        let seat = store.seat()
        let ledger = store.ledger(for: workbook)
        let range = ClinicalStockSendPlan.range(ledger: ledger, now: now, calendar: seams.calendar)
        let current = ClinicalStockShare.rows(stock.log, calendar: seams.calendar, range: range)
        var plan = ClinicalStockSendPlan.plan(current: current, ledger: ledger, seat: seat, range: range)
        seams.setLastPlanned(StockDay(now, calendar: seams.calendar).description)
        guard !plan.rows.isEmpty else { return 0 }
        var kept = plan.ledger
        if let range { kept.prune(before: range.first) }
        plan = ClinicalStockSendPlan.Plan(rows: plan.rows, ledger: kept)
        // The ledger first: a row queued and not on the ledger could be planned twice.
        guard store.saveLedger(plan.ledger, for: workbook),
              sink.enqueue(plan.rows, workbook: workbook, batchID: seams.makeID()) != nil else { return 0 }
        objectWillChange.send()
        await flush()
        return plan.rows.count
    }

    /// The first launch of a day sends what the last day left (Decision 3).
    func sendOnLaunchIfDue() async {
        let today = StockDay(seams.now(), calendar: seams.calendar)
        guard gate.allows,
              ClinicStockSendPolicy.isDueOnLaunch(lastPlanned: seams.lastPlanned().flatMap(StockDay.init(iso:)), today: today)
        else { return }
        await send(.launch)
    }

    /// The sink delivered a batch.
    func delivered(_ batch: ClinicStockQueuedBatch) {
        guard var record, record.workbook == batch.workbook else { return }
        record.lastSentAt = seams.now()
        if store.save(record) { self.record = record }
        Task { await refresh() }
    }

    /// The sink gave up on rows: take them off the ledger so the next send makes them again.
    func abandoned(_ keys: [String], workbook: GraphWorkbook) {
        var ledger = store.ledger(for: workbook)
        ledger.rollBack(keys)
        store.saveLedger(ledger, for: workbook)
        objectWillChange.send()
    }

    // MARK: - Tokens

    private func validToken() async throws -> String? {
        guard let record else { return nil }
        guard record.credentials.needsRefresh(now: seams.now()) else { return record.credentials.accessToken }
        return try await refreshed()
    }

    private func token(afterRejecting rejected: String) async throws -> String? {
        guard let record else { return nil }
        if record.credentials.accessToken != rejected { return record.credentials.accessToken }
        return try await refreshed()
    }

    /// One refresh at a time; callers that arrive meanwhile wait for the same one.
    private func refreshed() async throws -> String? {
        if let refreshTask { return try await refreshTask.value }
        let task = Task<String?, Error> { [weak self] in
            guard let self, let record = self.record, let refresh = record.credentials.refreshToken else {
                throw ClinicWorkbookFailure.unauthorized
            }
            let response = try await self.tokenCall(EntraOAuth.refreshRequest(clientID: record.clientID, refreshToken: refresh))
            guard var current = self.record, current.clientID == record.clientID else { throw ClinicWorkbookFailure.unauthorized }
            current.credentials = EntraOAuth.Credentials(response: response, now: self.seams.now(), previousRefreshToken: refresh)
            if self.store.save(current) { self.record = current }
            return current.credentials.accessToken
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    /// A token request through the workbook's own transport. A `400` from the token endpoint is a
    /// spent or withdrawn refresh token: sign in again.
    private func tokenCall(_ request: GraphRequest) async throws -> EntraOAuth.TokenResponse {
        let response = try await seams.transport.send(request, bearer: nil, workbook: nil)
        if response.status == 400 || response.status == 401 { throw ClinicWorkbookFailure.unauthorized }
        if let failure = ClinicWorkbookFailure.from(status: response.status, retryAfter: response.retryAfter) { throw failure }
        guard let token = EntraOAuth.parseToken(response.body) else { throw ClinicWorkbookFailure.malformedResponse }
        return token
    }

    // MARK: - The browser

    private func runBrowserSession(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: EntraOAuth.callbackScheme) { callbackURL, error in
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: error ?? ASWebAuthenticationSessionError(.canceledLogin))
                }
            }
            session.presentationContextProvider = self
            // No cookies shared with Safari: a clinic phone may be passed between staff.
            session.prefersEphemeralWebBrowserSession = true
            activeSession = session
            session.start()
        }
    }
}

extension ClinicWorkbookService: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            if let anchor = scenes.first(where: { $0.activationState == .foregroundActive })?.keyWindow { return anchor }
            if let anchor = scenes.lazy.compactMap(\.keyWindow).first { return anchor }
            if let anchor = scenes.lazy.flatMap(\.windows).first { return anchor }
            if let scene = scenes.first { return UIWindow(windowScene: scene) }
            preconditionFailure("presentationAnchor requested with no connected UIWindowScene")
        }
    }
}
