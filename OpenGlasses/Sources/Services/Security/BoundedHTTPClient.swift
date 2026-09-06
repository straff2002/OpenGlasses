import Foundation
import Network
import Security
import Darwin
import os.lock

/// A narrow HTTP GET client for attacker-selected URLs. Each hop is resolved once, every returned
/// address is classified, and the socket connects to one approved numeric address while TLS still
/// verifies the original hostname. Redirects are parsed by this client rather than URLSession.
struct BoundedHTTPClient {
    struct Profile: Equatable {
        let name: String
        let maximumBytes: Int
        let acceptedMIMETypes: Set<String>
        let maximumRedirects: Int
        let allowsPrivateHTTP: Bool
        let totalTimeout: TimeInterval

        static let qrContext = Profile(
            name: "qrContext",
            maximumBytes: 256 * 1024,
            acceptedMIMETypes: ["application/json", "text/plain", "text/html"],
            maximumRedirects: 3,
            allowsPrivateHTTP: false,
            totalTimeout: 20
        )

        static let signedCatalog = Profile(
            name: "signedCatalog",
            maximumBytes: 512 * 1024,
            acceptedMIMETypes: ["application/json"],
            maximumRedirects: 3,
            allowsPrivateHTTP: false,
            totalTimeout: 20
        )

        static let skillPack = Profile(
            name: "skillPack",
            maximumBytes: SkillPackArchive.maxArchiveBytes,
            acceptedMIMETypes: ["application/zip", "application/octet-stream", "application/x-zip-compressed"],
            maximumRedirects: 3,
            allowsPrivateHTTP: false,
            totalTimeout: 30
        )

        #if DEBUG
        static let internalSkillPack = Profile(
            name: "internalSkillPack",
            maximumBytes: SkillPackArchive.maxArchiveBytes,
            acceptedMIMETypes: ["application/zip", "application/octet-stream", "application/x-zip-compressed"],
            maximumRedirects: 0,
            allowsPrivateHTTP: true,
            totalTimeout: 30
        )
        #endif
    }

    struct PinnedRequest: Equatable {
        let url: URL
        let address: String
        let host: String
        let port: UInt16
        let usesTLS: Bool
    }

    struct Response: Equatable {
        let statusCode: Int
        let headers: [String: String]
        let finalURL: URL
        let byteCount: Int
    }

    enum ClientError: Error, Equatable, CustomStringConvertible {
        case invalidURL
        case credentialsOrFragment
        case disallowedScheme
        case disallowedPort
        case resolutionFailed
        case disallowedAddress
        case mixedAddressPolicy
        case redirectMissingLocation
        case redirectLoop
        case tooManyRedirects
        case insecureRedirect
        case badResponse
        case unsupportedTransferEncoding
        case unsupportedContentEncoding
        case unacceptableMIMEType
        case responseTooLarge
        case truncatedResponse
        case timeout
        case transport

        var description: String {
            switch self {
            case .invalidURL: return "invalid URL"
            case .credentialsOrFragment: return "credentials and fragments are not allowed"
            case .disallowedScheme: return "only public HTTPS is allowed"
            case .disallowedPort: return "the destination port is not allowed"
            case .resolutionFailed: return "the destination could not be resolved"
            case .disallowedAddress, .mixedAddressPolicy: return "the destination resolved to a private or reserved network"
            case .redirectMissingLocation: return "the redirect had no valid destination"
            case .redirectLoop: return "the redirect looped"
            case .tooManyRedirects: return "too many redirects"
            case .insecureRedirect: return "the redirect weakened transport security"
            case .badResponse: return "the server returned an invalid response"
            case .unsupportedTransferEncoding: return "the response transfer encoding is unsupported"
            case .unsupportedContentEncoding: return "compressed HTTP responses are not accepted"
            case .unacceptableMIMEType: return "the response content type is not allowed"
            case .responseTooLarge: return "the response exceeded its byte limit"
            case .truncatedResponse: return "the response ended before its declared length"
            case .timeout: return "the request timed out"
            case .transport: return "the secure connection failed"
            }
        }
    }

    typealias Resolver = (String) async throws -> [String]
    typealias BodySink = (Data) throws -> Void
    typealias Transport = (PinnedRequest, Profile, BodySink) async throws -> Response

    private let resolve: Resolver
    private let transport: Transport

    init(
        resolve: @escaping Resolver = BoundedHTTPClient.resolveHost,
        transport: @escaping Transport = BoundedHTTPClient.performPinnedRequest
    ) {
        self.resolve = resolve
        self.transport = transport
    }

    func fetch(
        _ initialURL: URL,
        profile: Profile,
        bodySink: @escaping BodySink
    ) async throws -> Response {
        try await withThrowingTaskGroup(of: Response.self) { group in
            group.addTask {
                try await fetchWithoutTimeout(initialURL, profile: profile, bodySink: bodySink)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(profile.totalTimeout * 1_000_000_000))
                throw ClientError.timeout
            }
            guard let first = try await group.next() else { throw ClientError.transport }
            group.cancelAll()
            return first
        }
    }

    func fetchData(_ url: URL, profile: Profile) async throws -> (Data, Response) {
        var body = Data()
        let response = try await fetch(url, profile: profile) { body.append($0) }
        return (body, response)
    }

    private func fetchWithoutTimeout(
        _ initialURL: URL,
        profile: Profile,
        bodySink: @escaping BodySink
    ) async throws -> Response {
        var current = initialURL
        var visited = Set<String>()
        for hop in 0...profile.maximumRedirects {
            let request = try await pinnedRequest(for: current, profile: profile)
            let key = canonicalRedirectKey(current)
            guard visited.insert(key).inserted else { throw ClientError.redirectLoop }

            // The transport parses the response head before delivering body bytes and suppresses
            // redirect bodies, so a final response can flow straight to the caller's bounded sink.
            let response = try await transport(request, profile, bodySink)
            guard Self.redirectStatusCodes.contains(response.statusCode) else {
                return response
            }
            guard hop < profile.maximumRedirects else { throw ClientError.tooManyRedirects }
            guard let rawLocation = response.headers["location"],
                  let next = URL(string: rawLocation, relativeTo: current)?.absoluteURL else {
                throw ClientError.redirectMissingLocation
            }
            if current.scheme?.lowercased() == "https", next.scheme?.lowercased() != "https" {
                throw ClientError.insecureRedirect
            }
            current = next
        }
        throw ClientError.tooManyRedirects
    }

    private func pinnedRequest(for url: URL, profile: Profile) async throws -> PinnedRequest {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty else {
            throw ClientError.invalidURL
        }
        guard components.user == nil, components.password == nil, components.fragment == nil else {
            throw ClientError.credentialsOrFragment
        }

        let usesTLS: Bool
        switch scheme {
        case "https": usesTLS = true
        case "http" where profile.allowsPrivateHTTP: usesTLS = false
        default: throw ClientError.disallowedScheme
        }
        let defaultPort: UInt16 = usesTLS ? 443 : 80
        let portValue = components.port ?? Int(defaultPort)
        guard (1...65_535).contains(portValue),
              profile.allowsPrivateHTTP || portValue == Int(defaultPort) else {
            throw ClientError.disallowedPort
        }

        let addresses: [String]
        if Self.isNumericAddress(host) {
            addresses = [host]
        } else {
            do { addresses = try await resolve(host) }
            catch { throw ClientError.resolutionFailed }
        }
        guard !addresses.isEmpty else { throw ClientError.resolutionFailed }
        let blocked = addresses.map(URLFetchGuard.isBlockedHost)
        if profile.allowsPrivateHTTP && !usesTLS {
            guard blocked.allSatisfy({ $0 }) else { throw ClientError.mixedAddressPolicy }
        } else {
            guard blocked.allSatisfy({ !$0 }) else {
                throw blocked.contains(false) ? ClientError.mixedAddressPolicy : ClientError.disallowedAddress
            }
        }

        return PinnedRequest(
            url: url,
            address: addresses.sorted().first!,
            host: host,
            port: UInt16(portValue),
            usesTLS: usesTLS
        )
    }

    private func canonicalRedirectKey(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let scheme = components?.scheme?.lowercased()
        let host = components?.host?.lowercased()
        components?.scheme = scheme
        components?.host = host
        return components?.string ?? url.absoluteString
    }

    private static let redirectStatusCodes: Set<Int> = [301, 302, 303, 307, 308]

    private static func isNumericAddress(_ host: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        return host.withCString { inet_pton(AF_INET, $0, &v4) == 1 }
            || host.withCString { inet_pton(AF_INET6, $0, &v6) == 1 }
    }

    private static func resolveHost(_ host: String) async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var hints = addrinfo(
                    ai_flags: AI_ADDRCONFIG,
                    ai_family: AF_UNSPEC,
                    ai_socktype: SOCK_STREAM,
                    ai_protocol: IPPROTO_TCP,
                    ai_addrlen: 0,
                    ai_canonname: nil,
                    ai_addr: nil,
                    ai_next: nil
                )
                var result: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else {
                    continuation.resume(throwing: ClientError.resolutionFailed)
                    return
                }
                defer { freeaddrinfo(first) }
                var addresses = Set<String>()
                var cursor: UnsafeMutablePointer<addrinfo>? = first
                while let item = cursor?.pointee {
                    var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(item.ai_addr, item.ai_addrlen, &buffer, socklen_t(buffer.count),
                                   nil, 0, NI_NUMERICHOST) == 0 {
                        addresses.insert(String(cString: buffer))
                    }
                    cursor = item.ai_next
                }
                continuation.resume(returning: addresses.sorted())
            }
        }
    }

    private static func performPinnedRequest(
        _ request: PinnedRequest,
        profile: Profile,
        sink: BodySink
    ) async throws -> Response {
        let parameters: NWParameters
        if request.usesTLS {
            let tls = NWProtocolTLS.Options()
            let queue = DispatchQueue(label: "nz.co.openglasses.bounded-http.verify")
            sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, request.host)
            sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
                let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
                SecTrustSetPolicies(secTrust, SecPolicyCreateSSL(true, request.host as CFString))
                complete(SecTrustEvaluateWithError(secTrust, nil))
            }, queue)
            let tcp = NWProtocolTCP.Options()
            tcp.connectionTimeout = 10
            tcp.connectionDropTime = 5
            parameters = NWParameters(tls: tls, tcp: tcp)
        } else {
            let tcp = NWProtocolTCP.Options()
            tcp.connectionTimeout = 10
            tcp.connectionDropTime = 5
            parameters = NWParameters(tls: nil, tcp: tcp)
        }

        let connection = NWConnection(
            host: NWEndpoint.Host(request.address),
            port: NWEndpoint.Port(rawValue: request.port)!,
            using: parameters
        )
        let queue = DispatchQueue(label: "nz.co.openglasses.bounded-http.connection")
        connection.start(queue: queue)
        defer { connection.cancel() }

        return try await withoutActuallyEscaping(sink) { escapingSink in
            try await withTaskCancellationHandler(operation: {
                try await waitUntilReady(connection)
                guard let components = URLComponents(url: request.url, resolvingAgainstBaseURL: false) else {
                    throw ClientError.invalidURL
                }
                let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
                let query = components.percentEncodedQuery.map { "?\($0)" } ?? ""
                let hostName = request.host.contains(":") ? "[\(request.host)]" : request.host
                let hostHeader = request.url.port == nil ? hostName : "\(hostName):\(request.port)"
                let wire = "GET \(path)\(query) HTTP/1.1\r\nHost: \(hostHeader)\r\nAccept: \(profile.acceptedMIMETypes.sorted().joined(separator: ", "))\r\nAccept-Encoding: identity\r\nConnection: close\r\nUser-Agent: OpenGlasses/BoundedFetch\r\n\r\n"
                try await send(Data(wire.utf8), on: connection)

                let parser = HTTPResponseParser(url: request.url, profile: profile, sink: escapingSink)
                while true {
                    let (bytes, complete) = try await receive(on: connection)
                    if !bytes.isEmpty, try parser.feed(bytes) { return try parser.response() }
                    if complete { return try parser.finish() }
                }
            }, onCancel: {
                connection.cancel()
            })
        }
    }

    private static func waitUntilReady(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let resolved = OSAllocatedUnfairLock(initialState: false)
            @Sendable func claim() -> Bool {
                resolved.withLock { alreadyResolved in
                    if alreadyResolved { return false }
                    alreadyResolved = true
                    return true
                }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard claim() else { return }
                    continuation.resume()
                case .failed, .cancelled:
                    guard claim() else { return }
                    continuation.resume(throwing: ClientError.transport)
                default:
                    break
                }
            }
        }
    }

    private static func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { error in
                if error == nil { continuation.resume() }
                else { continuation.resume(throwing: ClientError.transport) }
            })
        }
    }

    private static func receive(on connection: NWConnection) async throws -> (Data, Bool) {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
                data, _, complete, error in
                if let error {
                    _ = error
                    continuation.resume(throwing: ClientError.transport)
                } else {
                    continuation.resume(returning: (data ?? Data(), complete))
                }
            }
        }
    }
}

final class HTTPResponseParser {
    private enum Mode {
        case headers
        case fixed(Int)
        case chunkSize
        case chunkData(Int)
        case chunkTerminator
        case chunkTrailer
        case untilClose
        case done
    }

    private let url: URL
    private let profile: BoundedHTTPClient.Profile
    private let sink: BoundedHTTPClient.BodySink
    private var buffer = Data()
    private var mode: Mode = .headers
    private var statusCode = 0
    private var headers: [String: String] = [:]
    private var delivered = 0

    init(url: URL, profile: BoundedHTTPClient.Profile, sink: @escaping BoundedHTTPClient.BodySink) {
        self.url = url
        self.profile = profile
        self.sink = sink
    }

    func feed(_ data: Data) throws -> Bool {
        buffer.append(data)
        if case .headers = mode, buffer.count > 32 * 1024 {
            throw BoundedHTTPClient.ClientError.badResponse
        }
        while true {
            switch mode {
            case .headers:
                guard let range = buffer.range(of: Data("\r\n\r\n".utf8)) else { return false }
                let head = buffer[..<range.lowerBound]
                buffer.removeSubrange(..<range.upperBound)
                try parseHeaders(Data(head))
            case .fixed(let remaining):
                if remaining == 0 { mode = .done; return true }
                guard !buffer.isEmpty else { return false }
                let count = min(remaining, buffer.count)
                try deliver(Data(buffer.prefix(count)))
                buffer.removeFirst(count)
                mode = .fixed(remaining - count)
            case .untilClose:
                if !buffer.isEmpty { try deliver(buffer); buffer.removeAll(keepingCapacity: true) }
                return false
            case .chunkSize:
                guard let range = buffer.range(of: Data("\r\n".utf8)) else {
                    if buffer.count > 128 { throw BoundedHTTPClient.ClientError.badResponse }
                    return false
                }
                let line = String(decoding: buffer[..<range.lowerBound], as: UTF8.self)
                buffer.removeSubrange(..<range.upperBound)
                let token = line.split(separator: ";", maxSplits: 1).first ?? ""
                guard let count = Int(token.trimmingCharacters(in: .whitespaces), radix: 16), count >= 0,
                      count <= profile.maximumBytes - delivered else {
                    throw BoundedHTTPClient.ClientError.responseTooLarge
                }
                mode = count == 0 ? .chunkTrailer : .chunkData(count)
            case .chunkData(let remaining):
                guard !buffer.isEmpty else { return false }
                let count = min(remaining, buffer.count)
                try deliver(Data(buffer.prefix(count)))
                buffer.removeFirst(count)
                mode = count == remaining ? .chunkTerminator : .chunkData(remaining - count)
            case .chunkTerminator:
                guard buffer.count >= 2 else { return false }
                guard buffer.prefix(2) == Data("\r\n".utf8) else {
                    throw BoundedHTTPClient.ClientError.badResponse
                }
                buffer.removeFirst(2)
                mode = .chunkSize
            case .chunkTrailer:
                if buffer.prefix(2) == Data("\r\n".utf8) {
                    buffer.removeFirst(2); mode = .done; return true
                }
                guard let range = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                    if buffer.count > 8 * 1024 { throw BoundedHTTPClient.ClientError.badResponse }
                    return false
                }
                buffer.removeSubrange(..<range.upperBound)
                mode = .done
                return true
            case .done:
                return true
            }
        }
    }

    func finish() throws -> BoundedHTTPClient.Response {
        if case .untilClose = mode {
            if !buffer.isEmpty { try deliver(buffer); buffer.removeAll() }
            mode = .done
        }
        guard case .done = mode else { throw BoundedHTTPClient.ClientError.truncatedResponse }
        return try response()
    }

    func response() throws -> BoundedHTTPClient.Response {
        guard case .done = mode else { throw BoundedHTTPClient.ClientError.truncatedResponse }
        return .init(statusCode: statusCode, headers: headers, finalURL: url, byteCount: delivered)
    }

    private func parseHeaders(_ bytes: Data) throws {
        let lines = String(decoding: bytes, as: UTF8.self).components(separatedBy: "\r\n")
        guard let status = lines.first?.split(separator: " "), status.count >= 2,
              status[0].hasPrefix("HTTP/1."), let code = Int(status[1]) else {
            throw BoundedHTTPClient.ClientError.badResponse
        }
        statusCode = code
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw BoundedHTTPClient.ClientError.badResponse }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { throw BoundedHTTPClient.ClientError.badResponse }
            if let prior = headers[name] { headers[name] = prior + "," + value }
            else { headers[name] = value }
        }

        if [301, 302, 303, 307, 308].contains(code) {
            mode = .done
            return
        }
        if code == 204 || code == 304 || (100...199).contains(code) {
            mode = .done
            return
        }
        if let encoding = headers["content-encoding"]?.lowercased(), encoding != "identity" {
            throw BoundedHTTPClient.ClientError.unsupportedContentEncoding
        }
        let mime = headers["content-type"]?.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespaces).lowercased()
        guard let mime, profile.acceptedMIMETypes.contains(mime) else {
            throw BoundedHTTPClient.ClientError.unacceptableMIMEType
        }
        if let transfer = headers["transfer-encoding"]?.lowercased() {
            let codings = transfer.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard codings == ["chunked"] else {
                throw BoundedHTTPClient.ClientError.unsupportedTransferEncoding
            }
            mode = .chunkSize
        } else if let rawLength = headers["content-length"] {
            guard let length = Int(rawLength), length >= 0 else {
                throw BoundedHTTPClient.ClientError.badResponse
            }
            guard length <= profile.maximumBytes else { throw BoundedHTTPClient.ClientError.responseTooLarge }
            mode = .fixed(length)
        } else {
            mode = .untilClose
        }
    }

    private func deliver(_ bytes: Data) throws {
        let (next, overflow) = delivered.addingReportingOverflow(bytes.count)
        guard !overflow, next <= profile.maximumBytes else {
            throw BoundedHTTPClient.ClientError.responseTooLarge
        }
        try sink(bytes)
        delivered = next
    }
}
