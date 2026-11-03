import Combine
import Foundation
import UIKit

/// Permissions are scoped to the actual network origin and use, never a model name or API key.
enum CloudProcessingScope: String, CaseIterable, Identifiable, Hashable, Sendable {
    case conversation, speechOutput, speechRecognition, liveSession, webSearch
    var id: String { rawValue }
    var title: String {
        switch self {
        case .conversation: return "Conversation processing"
        case .speechOutput: return "Spoken replies"
        case .speechRecognition: return "Speech transcription"
        case .liveSession: return "Live voice and camera"
        case .webSearch: return "Web search"
        }
    }
    var dataClass: ConsentDataClass {
        switch self {
        case .conversation: return .assistantContext
        case .speechOutput: return .transcript
        case .speechRecognition: return .audio
        case .liveSession: return .liveMedia
        case .webSearch: return .searchTerms
        }
    }
    var disclosure: String {
        switch self {
        case .conversation:
            return "Your questions, recent conversation, selected manual passages and photos, and tool results needed for your request will be sent to this service. Tool results can include contacts, calendar entries, location and health information you separately allow."
        case .speechOutput:
            return "The text of replies will be sent to this service to create speech. Replies can contain personal information from your conversation, documents and tool results."
        case .speechRecognition:
            return "Microphone audio will be sent to this service for transcription. Audio may include nearby voices as well as your own."
        case .liveSession:
            return "Microphone audio, conversation context and tool results will be sent during a live session. Camera frames will also be sent if you enable the camera. These can contain personal information and nearby people."
        case .webSearch:
            return "Search terms will be sent to this service to find information or generate a search answer. Terms can include names, locations and other details from your request."
        }
    }
}

struct CloudProcessingTerms: Hashable, Sendable {
    let origin: String
    let scope: CloudProcessingScope
    static let version = 1

    /// For an origin these terms have already normalised.
    init(origin: String, scope: CloudProcessingScope) {
        self.origin = origin
        self.scope = scope
    }

    init(url: URL, scope: CloudProcessingScope) throws {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased(), !host.isEmpty,
              let scheme = components.scheme?.lowercased(), ["https", "http", "wss", "ws"].contains(scheme) else {
            throw CloudProcessingRefusal.invalidDestination
        }
        components = URLComponents()
        components.scheme = ["wss": "https", "ws": "http"][scheme] ?? scheme
        components.host = host
        let port = url.port
        if port != (components.scheme == "https" ? 443 : 80) { components.port = port }
        guard let origin = components.string else { throw CloudProcessingRefusal.invalidDestination }
        self.origin = origin
        self.scope = scope
    }
}

enum CloudProcessingRefusal: Error, LocalizedError {
    case invalidDestination, permissionRequired, withdrawn, unavailable
    var errorDescription: String? {
        switch self {
        case .invalidDestination: return "The service address isn't valid."
        case .permissionRequired: return "Avenkin needs your permission to use this service. You can allow it in Devices & Privacy > Cloud AI Sharing."
        case .withdrawn: return "Sharing permission for this service is off. You can review it in Devices & Privacy > Cloud AI Sharing."
        case .unavailable: return "Sharing permissions are unavailable. No content was sent."
        }
    }
}

/// A live authorization is invalidated on withdrawal, including for queued realtime packets.
final class CloudProcessingLease: @unchecked Sendable {
    let terms: CloudProcessingTerms
    private let lock = NSLock()
    private var valid = true
    private var cancellations: [UUID: () -> Void] = [:]
    init(terms: CloudProcessingTerms) { self.terms = terms }
    var isValid: Bool { lock.lock(); defer { lock.unlock() }; return valid }
    @discardableResult
    func onWithdrawal(_ cancel: @escaping () -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        if valid { cancellations[id] = cancel; lock.unlock() }
        else { lock.unlock(); cancel() }
        return id
    }
    func removeWithdrawalHandler(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        cancellations.removeValue(forKey: id)
    }
    func invalidate() {
        lock.lock()
        valid = false
        let callbacks = Array(cancellations.values)
        cancellations.removeAll()
        lock.unlock()
        callbacks.forEach { $0() }
    }
    func trackRequests(in session: URLSession, to url: URL) {
        onWithdrawal { [weak session] in
            session?.getAllTasks { tasks in
                tasks.filter { $0.originalRequest?.url == url }.forEach { $0.cancel() }
            }
        }
    }
}

@MainActor
final class CloudProcessingConsent: ObservableObject {
    /// Replaced only by a test that drives a service which reads it, with its own approvals.
    static var shared = CloudProcessingConsent()
    /// One question about one origin. It can cover several uses, so that a key which serves chat
    /// and speech is asked about once.
    struct Prompt: Identifiable {
        let id = UUID()
        let terms: CloudProcessingTerms
        var scopes: [CloudProcessingScope]
        var serviceName: String?
        init(terms: CloudProcessingTerms, scopes: [CloudProcessingScope]? = nil, serviceName: String? = nil) {
            self.terms = terms
            self.scopes = scopes ?? [terms.scope]
            self.serviceName = serviceName
        }
        var allTerms: [CloudProcessingTerms] {
            scopes.map { CloudProcessingTerms(origin: terms.origin, scope: $0) }
        }
        func covers(_ other: CloudProcessingTerms) -> Bool {
            other.origin == terms.origin && scopes.contains(other.scope)
        }
    }
    private struct Waiting {
        let prompt: Prompt
        var replies: [UUID: CheckedContinuation<Void, Error>]
    }
    private final class WeakLease {
        weak var value: CloudProcessingLease?
        init(_ value: CloudProcessingLease) { self.value = value }
    }
    @Published private(set) var pending: Prompt?
    @Published private(set) var revision = 0
    @Published private(set) var storageNotice: String?
    var presenterAvailable = false
    private let store: ConsentStore
    private let foreground: () -> Bool
    private let defaults: UserDefaults
    private var waiting: [Waiting] = []
    private var declined: Set<CloudProcessingTerms> = []
    private var leases: [WeakLease] = []

    /// The question has a window of its own, so an open sheet doesn't stop it being seen.
    init(store: ConsentStore? = nil, defaults: UserDefaults = .standard, foreground: (() -> Bool)? = nil) {
        self.store = store ?? .shared
        self.defaults = defaults
        self.foreground = foreground ?? {
            UIApplication.shared.applicationState == .active
                && UIApplication.shared.connectedScenes.contains {
                    $0 is UIWindowScene && $0.activationState == .foregroundActive
                }
        }
    }

    var approvals: [ConsentRecord] {
        guard store.storageAvailable else { return [] }
        return store.records.filter { record in
            guard record.purpose == .aiProcessing, !record.isWithdrawn,
                  let scope = CloudProcessingScope.allCases.first(where: { $0.dataClass == record.dataClass }),
                  let url = URL(string: record.recipient),
                  let terms = try? CloudProcessingTerms(url: url, scope: scope),
                  case .granted(let current) = outcome(terms) else { return false }
            return current.id == record.id
        }
    }
    private func outcome(_ terms: CloudProcessingTerms) -> ConsentOutcome {
        store.evaluate(purpose: .aiProcessing, dataClass: terms.scope.dataClass,
                       recipient: terms.origin, requiredVersion: CloudProcessingTerms.version)
    }
    func hasApproval(url: URL, scope: CloudProcessingScope) -> Bool {
        guard store.storageAvailable, let terms = try? CloudProcessingTerms(url: url, scope: scope) else { return false }
        return outcome(terms).allowsProcessing
    }
    func existingLease(url: URL, scope: CloudProcessingScope) throws -> CloudProcessingLease {
        guard store.storageAvailable else { throw CloudProcessingRefusal.unavailable }
        let terms = try CloudProcessingTerms(url: url, scope: scope)
        guard outcome(terms).allowsProcessing else { throw CloudProcessingRefusal.permissionRequired }
        return lease(for: terms)
    }

    func authorize(url: URL, scope: CloudProcessingScope, reviewAgain: Bool = false) async throws -> CloudProcessingLease {
        guard store.storageAvailable else { throw CloudProcessingRefusal.unavailable }
        let terms = try CloudProcessingTerms(url: url, scope: scope)
        if !reviewAgain, outcome(terms).allowsProcessing { return lease(for: terms) }
        if !reviewAgain {
            if case .withdrawn = outcome(terms) { throw CloudProcessingRefusal.withdrawn }
            if declined.contains(terms) { throw CloudProcessingRefusal.permissionRequired }
        }
        guard presenterAvailable, foreground() else {
            // Nobody can answer now, so the question waits for the next time someone can.
            noteRefused(terms)
            throw CloudProcessingRefusal.permissionRequired
        }
        let waiter = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (reply: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else { reply.resume(throwing: CancellationError()); return }
                if let index = waiting.firstIndex(where: { $0.prompt.covers(terms) }) {
                    waiting[index].replies[waiter] = reply
                } else {
                    waiting.append(Waiting(prompt: Prompt(terms: terms), replies: [waiter: reply]))
                }
                pending = waiting.first?.prompt
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(waiter: waiter) }
        }
        // Approval can be withdrawn while a suspended caller is resuming.
        return try existingLease(url: url, scope: scope)
    }

    func respond(allow: Bool) {
        guard !waiting.isEmpty else { return }
        let next = waiting.removeFirst()
        for terms in next.prompt.allTerms {
            if allow {
                store.recordWearerApproval(purpose: .aiProcessing, dataClass: terms.scope.dataClass,
                                          recipient: terms.origin, version: CloudProcessingTerms.version)
                declined.remove(terms)
            } else { declined.insert(terms) }
            noteAnswered(terms)
        }
        revision += 1
        pending = waiting.first?.prompt
        if !store.storageAvailable {
            leases.forEach { $0.value?.invalidate() }
            storageNotice = "Sharing permissions couldn't be saved. Content sharing is blocked. Check permissions after restarting the app."
            cancelPending()
        }
        for reply in next.replies.values {
            if !store.storageAvailable { reply.resume(throwing: CloudProcessingRefusal.unavailable) }
            else if allow { reply.resume() }
            else { reply.resume(throwing: CloudProcessingRefusal.permissionRequired) }
        }
    }

    // MARK: Asking ahead of use

    /// Which of a service's uses to ask about now. A use is left alone once it's approved or
    /// answered; Not now is remembered across launches, so this never nags. A request that was
    /// refused with nobody there is asked about once, because someone wanted it to work. `forced`
    /// is the person picking the service again, which reopens Not now and a withdrawal.
    func scopesToAsk(_ service: CloudService, forced: Bool = false) -> [CloudProcessingScope] {
        guard store.storageAvailable else { return [] }
        return service.scopes.filter { scope in
            let terms = CloudProcessingTerms(origin: service.origin, scope: scope)
            let current = outcome(terms)
            if current.allowsProcessing { return false }
            if forced { return true }
            if case .withdrawn = current { return false }
            if declined.contains(terms) { return false }
            return refused.contains(Self.ledgerKey(terms))
                || (service.asked.contains(scope) && !answered.contains(Self.ledgerKey(terms)))
        }
    }

    /// `services` plus anything refused that the list doesn't name, such as a gateway.
    func withRefusedServices(_ services: [CloudService]) -> [CloudService] {
        var merged = services
        for key in refused {
            guard let terms = Self.terms(fromLedgerKey: key), let url = URL(string: terms.origin) else { continue }
            if let index = merged.firstIndex(where: { $0.origin == terms.origin }) {
                if !merged[index].scopes.contains(terms.scope) { merged[index].scopes.append(terms.scope) }
            } else {
                merged.append(CloudService(name: ProcessingFacts.host(of: terms.origin) ?? terms.origin, url: url,
                                           origin: terms.origin, scopes: [terms.scope], asked: []))
            }
        }
        return merged
    }

    /// Shows one question and waits for it. False when it went unanswered because the person left.
    func ask(about service: CloudService, scopes: [CloudProcessingScope]) async -> Bool {
        guard let first = scopes.first, presenterAvailable, foreground() else { return false }
        let terms = CloudProcessingTerms(origin: service.origin, scope: first)
        do {
            try await withCheckedThrowingContinuation { (reply: CheckedContinuation<Void, Error>) in
                if let index = waiting.firstIndex(where: { $0.prompt.covers(terms) }) {
                    waiting[index].replies[UUID()] = reply
                } else {
                    waiting.append(Waiting(prompt: Prompt(terms: terms, scopes: scopes, serviceName: service.name),
                                           replies: [UUID(): reply]))
                }
                pending = waiting.first?.prompt
            }
            return true
        } catch {
            return answered.contains(Self.ledgerKey(terms))
        }
    }

    /// The person's own request from the service list, which also reopens a withdrawal.
    func allow(_ service: CloudService, scope: CloudProcessingScope) async throws {
        _ = try await authorize(url: service.url, scope: scope, reviewAgain: true)
    }

    func hasApproval(_ service: CloudService, scope: CloudProcessingScope) -> Bool {
        guard store.storageAvailable else { return false }
        return outcome(CloudProcessingTerms(origin: service.origin, scope: scope)).allowsProcessing
    }

    func approval(_ service: CloudService, scope: CloudProcessingScope) -> ConsentRecord? {
        approvals.first { $0.recipient == service.origin && $0.dataClass == scope.dataClass }
    }

    private static let answeredKey = "cloudSharingAnswered"
    private static let refusedKey = "cloudSharingRefused"
    private var answered: Set<String> { Set(defaults.stringArray(forKey: Self.answeredKey) ?? []) }
    private var refused: [String] { defaults.stringArray(forKey: Self.refusedKey) ?? [] }
    private static func ledgerKey(_ terms: CloudProcessingTerms) -> String { "\(terms.scope.rawValue) \(terms.origin)" }
    private static func terms(fromLedgerKey key: String) -> CloudProcessingTerms? {
        let parts = key.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, let scope = CloudProcessingScope(rawValue: parts[0]) else { return nil }
        return CloudProcessingTerms(origin: parts[1], scope: scope)
    }
    private func noteRefused(_ terms: CloudProcessingTerms) {
        let key = Self.ledgerKey(terms)
        guard !refused.contains(key) else { return }
        defaults.set(refused + [key], forKey: Self.refusedKey)
    }
    private func noteAnswered(_ terms: CloudProcessingTerms) {
        let key = Self.ledgerKey(terms)
        defaults.set(Array(answered.union([key])).sorted(), forKey: Self.answeredKey)
        defaults.set(refused.filter { $0 != key }, forKey: Self.refusedKey)
    }

    func withdraw(_ record: ConsentRecord) {
        _ = store.withdraw(id: record.id)
        for box in leases {
            if let lease = box.value, !store.storageAvailable || !outcome(lease.terms).allowsProcessing { lease.invalidate() }
        }
        if !store.storageAvailable {
            storageNotice = "Sharing stopped for this session, but the withdrawal couldn't be saved. Check permissions after restarting the app."
            cancelPending()
        }
        leases.removeAll { $0.value == nil }
        revision += 1
    }
    func cancelPending() {
        let replies = waiting.flatMap { $0.replies.values }
        waiting.removeAll(); pending = nil
        replies.forEach { $0.resume(throwing: CloudProcessingRefusal.permissionRequired) }
    }
    private func cancel(waiter: UUID) {
        for index in waiting.indices {
            if let reply = waiting[index].replies.removeValue(forKey: waiter) { reply.resume(throwing: CancellationError()) }
        }
        waiting.removeAll { $0.replies.isEmpty }
        pending = waiting.first?.prompt
    }
    private func lease(for terms: CloudProcessingTerms) -> CloudProcessingLease {
        let lease = CloudProcessingLease(terms: terms)
        leases.removeAll { $0.value == nil }
        leases.append(WeakLease(lease))
        return lease
    }
}

/// Retained by Foundation throughout a request/stream, so withdrawal also cancels in-flight work.
final class CloudProcessingTransferDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let lease: CloudProcessingLease
    let allowSameOriginRedirects: Bool
    init(lease: CloudProcessingLease, session: URLSession, url: URL, allowSameOriginRedirects: Bool = true) {
        self.lease = lease
        self.allowSameOriginRedirects = allowSameOriginRedirects
        super.init()
        lease.trackRequests(in: session, to: url)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard allowSameOriginRedirects, lease.isValid, let url = request.url,
              let destination = try? CloudProcessingTerms(url: url, scope: lease.terms.scope),
              destination == lease.terms else { completionHandler(nil); return }
        completionHandler(request)
    }
}

/// Gateway factories stay synchronous, but their sockets remain suspended until the first
/// authorized send/receive. Scripted test transports do not make network requests.
final class CloudProcessingSocketAuthorization: @unchecked Sendable {
    private let lock = NSLock()
    private var permissionTask: Task<CloudProcessingLease, Error>?
    private var permission: CloudProcessingLease?
    private var resumed = false
    private var cancelled = false

    private func approval(for url: URL, scope: CloudProcessingScope) -> Task<CloudProcessingLease, Error> {
        lock.lock(); defer { lock.unlock() }
        if let permissionTask { return permissionTask }
        let pending = Task { @MainActor in try await CloudProcessingConsent.shared.authorize(url: url, scope: scope) }
        permissionTask = pending
        if cancelled { pending.cancel() }
        return pending
    }
    private func activate(_ lease: CloudProcessingLease) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled, lease.isValid else { throw CloudProcessingRefusal.withdrawn }
        guard !resumed else { return false }
        permission = lease
        resumed = true
        return true
    }
    func prepare(_ task: URLSessionWebSocketTask, session: URLSession, scope: CloudProcessingScope) async throws {
        guard let url = task.originalRequest?.url else { throw CloudProcessingRefusal.invalidDestination }
        let lease = try await approval(for: url, scope: scope).value
        if try activate(lease) {
            task.delegate = CloudProcessingTransferDelegate(lease: lease, session: session, url: url)
            lease.onWithdrawal { [weak task] in task?.cancel(with: .policyViolation, reason: nil) }
            guard lease.isValid else { throw CloudProcessingRefusal.withdrawn }
            task.resume()
        }
        try requireValid()
    }
    func requireValid() throws {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled, permission?.isValid == true else { throw CloudProcessingRefusal.withdrawn }
    }
    func cancel() {
        lock.lock()
        cancelled = true
        let pending = permissionTask
        lock.unlock()
        pending?.cancel()
    }
}

extension URLSession {
    @MainActor
    func consentedData(for request: URLRequest, scope: CloudProcessingScope,
                       consent: CloudProcessingConsent? = nil,
                       allowSameOriginRedirects: Bool = true) async throws -> (Data, URLResponse) {
        guard let url = request.url else { throw CloudProcessingRefusal.invalidDestination }
        let lease = try await (consent ?? .shared).authorize(url: url, scope: scope)
        guard lease.isValid else { throw CloudProcessingRefusal.withdrawn }
        let transfer = Task {
            try Task.checkCancellation()
            return try await data(for: request, delegate: CloudProcessingTransferDelegate(lease: lease, session: self, url: url,
                                                                                        allowSameOriginRedirects: allowSameOriginRedirects))
        }
        let cancellation = lease.onWithdrawal { transfer.cancel() }
        defer { lease.removeWithdrawalHandler(cancellation) }
        do {
            return try await withTaskCancellationHandler { try await transfer.value } onCancel: { transfer.cancel() }
        } catch {
            if !lease.isValid { throw CloudProcessingRefusal.withdrawn }
            throw error
        }
    }
    @MainActor
    func consentedBytes(for request: URLRequest, scope: CloudProcessingScope,
                        consent: CloudProcessingConsent? = nil) async throws -> (URLSession.AsyncBytes, URLResponse) {
        guard let url = request.url else { throw CloudProcessingRefusal.invalidDestination }
        let lease = try await (consent ?? .shared).authorize(url: url, scope: scope)
        guard lease.isValid else { throw CloudProcessingRefusal.withdrawn }
        let transfer = Task {
            try Task.checkCancellation()
            return try await bytes(for: request, delegate: CloudProcessingTransferDelegate(lease: lease, session: self, url: url))
        }
        let cancellation = lease.onWithdrawal { transfer.cancel() }
        defer { lease.removeWithdrawalHandler(cancellation) }
        let result = try await withTaskCancellationHandler { try await transfer.value } onCancel: { transfer.cancel() }
        lease.onWithdrawal { [weak task = result.0.task] in task?.cancel() }
        guard lease.isValid else { throw CloudProcessingRefusal.withdrawn }
        return result
    }
}
