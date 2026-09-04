import Foundation

/// One file fetch, as the download manager sees it. The seam exists so the whole acquisition
/// pipeline — redirect refusal included — runs headlessly against a fake, and so the background
/// session's delegate machinery has exactly one job.
struct LocalModelFileTransferRequest: Sendable {
    /// Stable across relaunch; becomes the task's `taskDescription`.
    let identifier: LocalModelTransferIdentifier
    let url: URL
    let expectedBytes: Int64
}

/// What a completed fetch delivered. Every field is something the manager re-checks: a transport
/// that already validated them would be a transport the tests cannot make lie.
struct LocalModelFileTransferOutcome: Sendable {
    let statusCode: Int
    /// The URL the response finally came from, after redirects. Checked against the download host
    /// policy for *every* response, not only the request we built.
    let finalURL: URL?
    /// A temporary file the manager takes ownership of. Never a `Data` — weights are gigabytes.
    let fileURL: URL
    let byteCount: Int64
}

/// Why a transfer never produced a file. Transport-level only; policy refusals are the manager's.
enum LocalModelFileTransferError: Error, Equatable, Sendable {
    case cancelled
    case redirectRefused
    case transport
    case noFileProduced
}

protocol LocalModelFileTransferring: Sendable {
    /// Fetch one file. The returned temporary file belongs to the caller.
    func transfer(_ request: LocalModelFileTransferRequest) async throws -> LocalModelFileTransferOutcome
    /// Cancel every in-flight task belonging to a plan. Cancelling a plan that has none is a no-op.
    func cancelTasks(forPlan planID: UUID) async
    /// Identifiers of tasks the system is still holding for this app. After a relaunch this is how
    /// the plan-to-task mapping is rebuilt — by reading the tasks, not by remembering them.
    func liveIdentifiers() async -> [LocalModelTransferIdentifier]
}

/// The production transfer: a background `URLSession` whose tasks survive app termination.
///
/// Three things make this different from a plain `URLSession.download`:
///
///  1. **Background configuration with a fixed identifier**, so the system keeps fetching while the
///     app is suspended and hands the results back on relaunch.
///  2. **A stable `taskDescription`** on every task, which is the only piece of state that has to
///     survive termination — the plan file on disk holds everything else.
///  3. **Redirects are refused in the delegate**, before the request is reissued. Checking the host
///     after the bytes have arrived would be checking after the request already went somewhere.
///
/// None of this is exercised by the headless suite: a background session needs a real app. What is
/// tested is everything either side of it — the identifier encoding, the host policy the delegate
/// calls, and the manager's re-validation of whatever an outcome claims.
final class LocalModelBackgroundTransfer: NSObject, LocalModelFileTransferring, @unchecked Sendable {

    /// One session per app, named so the system can hand its tasks back after a relaunch.
    static let sessionIdentifier = "com.openglasses.localmodels.download"

    private let lock = NSLock()
    private var continuations: [LocalModelTransferIdentifier: CheckedContinuation<LocalModelFileTransferOutcome, Error>] = [:]
    private var refusedRedirects: Set<LocalModelTransferIdentifier> = []
    /// Called when the system finishes delivering background events, so the app delegate's stored
    /// completion handler can be invoked.
    private var backgroundEventsHandler: (@Sendable () -> Void)?

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        // Anonymous public repositories only: nothing here may attach a stored credential.
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    /// Register the handler iOS gives the app delegate when it wakes it for this session.
    func setBackgroundEventsHandler(_ handler: (@Sendable () -> Void)?) {
        lock.lock()
        backgroundEventsHandler = handler
        lock.unlock()
    }

    func transfer(_ request: LocalModelFileTransferRequest) async throws -> LocalModelFileTransferOutcome {
        guard LocalModelRepositoryReference.isAllowedDownloadURL(request.url) else {
            throw LocalModelFileTransferError.redirectRefused
        }
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            continuations[request.identifier] = continuation
            refusedRedirects.remove(request.identifier)
            lock.unlock()

            var urlRequest = URLRequest(url: request.url)
            urlRequest.httpMethod = "GET"
            urlRequest.httpShouldHandleCookies = false
            let task = session.downloadTask(with: urlRequest)
            task.taskDescription = request.identifier.description
            task.resume()
        }
    }

    func cancelTasks(forPlan planID: UUID) async {
        let tasks = await session.allTasks
        for task in tasks {
            guard let identifier = LocalModelTransferIdentifier(task.taskDescription),
                  identifier.planID == planID else { continue }
            task.cancel()
        }
    }

    func liveIdentifiers() async -> [LocalModelTransferIdentifier] {
        await session.allTasks.compactMap { LocalModelTransferIdentifier($0.taskDescription) }
    }

    // MARK: - Delegate plumbing

    private func finish(_ identifier: LocalModelTransferIdentifier,
                        with result: Result<LocalModelFileTransferOutcome, Error>) {
        lock.lock()
        let continuation = continuations.removeValue(forKey: identifier)
        lock.unlock()
        continuation?.resume(with: result)
    }
}

extension LocalModelBackgroundTransfer: URLSessionDownloadDelegate {

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let identifier = LocalModelTransferIdentifier(downloadTask.taskDescription) else { return }
        let response = downloadTask.response as? HTTPURLResponse

        // The delegate's file is deleted the moment this method returns, so it is moved before
        // anything else — including before deciding whether the response was acceptable, which the
        // manager does with the file in hand.
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("localmodel-\(UUID().uuidString).part")
        do {
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            finish(identifier, with: .failure(LocalModelFileTransferError.noFileProduced))
            return
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)
            .flatMap { $0?.int64Value } ?? 0
        finish(identifier, with: .success(LocalModelFileTransferOutcome(
            statusCode: response?.statusCode ?? 0,
            finalURL: response?.url ?? downloadTask.originalRequest?.url,
            fileURL: destination,
            byteCount: size)))
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard LocalModelRepositoryReference.isAllowedDownloadURL(request.url) else {
            if let identifier = LocalModelTransferIdentifier(task.taskDescription) {
                lock.lock()
                refusedRedirects.insert(identifier)
                lock.unlock()
            }
            // Refusing the redirect completes the task with the redirect response instead of
            // following it. The manager still re-checks the host it ended on.
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let identifier = LocalModelTransferIdentifier(task.taskDescription) else { return }
        lock.lock()
        let wasRefused = refusedRedirects.remove(identifier) != nil
        let isPending = continuations[identifier] != nil
        lock.unlock()
        guard isPending else { return }   // success already delivered by didFinishDownloadingTo

        if wasRefused {
            finish(identifier, with: .failure(LocalModelFileTransferError.redirectRefused))
        } else if let error, (error as NSError).code == NSURLErrorCancelled {
            finish(identifier, with: .failure(LocalModelFileTransferError.cancelled))
        } else if error != nil {
            finish(identifier, with: .failure(LocalModelFileTransferError.transport))
        } else {
            finish(identifier, with: .failure(LocalModelFileTransferError.noFileProduced))
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock()
        let handler = backgroundEventsHandler
        backgroundEventsHandler = nil
        lock.unlock()
        handler?()
    }
}
