import Foundation

/// Categorizes network requests by destination.
enum NetworkCategory: String, CaseIterable {
    case meta = "Meta"
    case aiProvider = "AI Provider"
    case appService = "App Service"
    case other = "Other"

    var icon: String {
        switch self {
        case .meta: return "m.circle.fill"
        case .aiProvider: return "brain"
        case .appService: return "cloud"
        case .other: return "network"
        }
    }

    static func categorize(host: String) -> NetworkCategory {
        let h = host.lowercased()
        // Meta / Facebook
        if h.contains("facebook.com") || h.contains("meta.com") || h.contains("fbcdn")
            || h.contains("wearables") || h.contains("instagram.com") || h.contains("fb.com") {
            return .meta
        }
        // AI providers
        if h.contains("anthropic.com") || h.contains("openai.com") || h.contains("googleapis.com")
            || h.contains("groq.com") || h.contains("together") || h.contains("perplexity")
            || h.contains("deepseek") || h.contains("mistral") || h.contains("dashscope") {
            return .aiProvider
        }
        // App services
        if h.contains("weather") || h.contains("openweather") || h.contains("duckduckgo")
            || h.contains("elevenlabs") || h.contains("newsapi") || h.contains("exchangerate")
            || h.contains("shazam") || h.contains("apple.com") {
            return .appService
        }
        return .other
    }
}

/// A single captured network request.
struct NetworkEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let method: String
    let host: String
    let path: String
    let requestSize: Int
    var responseSize: Int = 0
    var statusCode: Int = 0
    var duration: TimeInterval = 0
    let category: NetworkCategory

    var url: String { host + path }
}

/// Monitors all URLSession network requests via URLProtocol interception.
@MainActor
final class NetworkMonitorService: ObservableObject {
    static let shared = NetworkMonitorService()

    @Published var entries: [NetworkEntry] = []
    private let maxEntries = 200

    var metaEntries: [NetworkEntry] { entries.filter { $0.category == .meta } }
    var aiEntries: [NetworkEntry] { entries.filter { $0.category == .aiProvider } }
    var appEntries: [NetworkEntry] { entries.filter { $0.category == .appService } }
    var otherEntries: [NetworkEntry] { entries.filter { $0.category == .other } }

    var totalBytesSent: Int { entries.reduce(0) { $0 + $1.requestSize } }
    var totalBytesReceived: Int { entries.reduce(0) { $0 + $1.responseSize } }
    var metaBytesSent: Int { metaEntries.reduce(0) { $0 + $1.requestSize } }

    func addEntry(_ entry: NetworkEntry) {
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries.removeLast()
        }
    }

    func updateEntry(id: UUID, responseSize: Int, statusCode: Int, duration: TimeInterval) {
        if let idx = entries.firstIndex(where: { $0.id == id }) {
            entries[idx].responseSize = responseSize
            entries[idx].statusCode = statusCode
            entries[idx].duration = duration
        }
    }

    func clear() {
        entries.removeAll()
    }

    /// Register the URLProtocol interceptor. Call at app launch.
    static func register() {
        URLProtocol.registerClass(NetworkInterceptor.self)
    }
}

// MARK: - URLProtocol Interceptor

final class NetworkInterceptor: URLProtocol {
    private var startTime: Date?
    private var entryId: UUID?
    private var responseData = Data()

    static let monitoredKey = "NetworkInterceptor.monitored"

    override class func canInit(with request: URLRequest) -> Bool {
        // Don't re-intercept already-monitored requests
        if URLProtocol.property(forKey: monitoredKey, in: request) != nil {
            return false
        }
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        startTime = Date()

        guard let url = request.url, let host = url.host else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let entry = NetworkEntry(
            timestamp: Date(),
            method: request.httpMethod ?? "GET",
            host: host,
            path: url.path,
            requestSize: request.httpBody?.count ?? 0,
            category: NetworkCategory.categorize(host: host)
        )

        entryId = entry.id

        Task { @MainActor in
            NetworkMonitorService.shared.addEntry(entry)
        }

        // Forward the request with a tag to prevent re-interception
        let mutableRequest = (request as NSURLRequest).mutableCopy() as! NSMutableURLRequest
        URLProtocol.setProperty(true, forKey: Self.monitoredKey, in: mutableRequest)

        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let task = session.dataTask(with: mutableRequest as URLRequest)
        task.resume()
    }

    override func stopLoading() {
        // Cleanup handled by delegate
    }
}

extension NetworkInterceptor: URLSessionDataDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        responseData.append(data)
        client?.urlProtocol(self, didLoad: data)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let duration = startTime.map { Date().timeIntervalSince($0) } ?? 0
        let statusCode = (task.response as? HTTPURLResponse)?.statusCode ?? 0

        if let id = entryId {
            Task { @MainActor in
                NetworkMonitorService.shared.updateEntry(
                    id: id,
                    responseSize: responseData.count,
                    statusCode: statusCode,
                    duration: duration
                )
            }
        }

        if let error {
            client?.urlProtocol(self, didFailWithError: error)
        } else {
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}
