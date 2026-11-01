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
        case .permissionRequired: return "Open Avenkin to review permission for this service in Devices & Privacy > Cloud AI Sharing."
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
    static let shared = CloudProcessingConsent()
    struct Prompt: Identifiable {
        let id = UUID()
        let terms: CloudProcessingTerms
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
    private var waiting: [Waiting] = []
    private var declined: Set<CloudProcessingTerms> = []
    private var leases: [WeakLease] = []

    init(store: ConsentStore? = nil, foreground: (() -> Bool)? = nil) {
        self.store = store ?? .shared
        self.foreground = foreground ?? {
            guard UIApplication.shared.applicationState == .active,
                  let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                    .first(where: { $0.activationState == .foregroundActive }),
                  let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { return false }
            return root.presentedViewController == nil
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
        guard presenterAvailable, foreground() else { throw CloudProcessingRefusal.permissionRequired }
        let waiter = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (reply: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else { reply.resume(throwing: CancellationError()); return }
                if let index = waiting.firstIndex(where: { $0.prompt.terms == terms }) {
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
        let terms = next.prompt.terms
        if allow {
            store.recordWearerApproval(purpose: .aiProcessing, dataClass: terms.scope.dataClass,
                                      recipient: terms.origin, version: CloudProcessingTerms.version)
            declined.remove(terms)
        } else { declined.insert(terms) }
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
