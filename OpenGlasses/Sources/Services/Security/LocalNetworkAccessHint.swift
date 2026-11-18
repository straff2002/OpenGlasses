import Foundation
import Network

/// Whether a failed request to a server on the wearer's own network may have been stopped by iOS's
/// Local Network permission, and the one line that says so.
///
/// With the permission off, iOS fails a request to a LAN host at once, and the error reads like
/// any other "can't connect" or "offline". The wearer sees "Gateway not responding" for a gateway
/// that is up and answering, with nothing pointing at the switch in Settings.
///
/// What can be known, without guessing:
///
/// - **The path said so.** A failed `URLSession` task carries the network path it was refused on,
///   and a path refused for this reason is unsatisfied with "Local network prohibited"
///   (`NWPath.UnsatisfiedReason.localNetworkDenied`). A Bonjour or `NWConnection` refusal is the
///   DNS-SD "policy denied" error. Either one is the system's own word, so it is enough on its own.
/// - **The shape fits.** Short of that, the target must be on the local network (a private,
///   link-local or `.local` host, read by `URLFetchGuard.hostClass`; loopback is never gated), and
///   the failure must be the kind a refused local path produces: "not connected to the internet",
///   or a socket error of network down, network unreachable or host unreachable. A connection
///   *refused* proves packets reached the host, so it rules the permission out.
///
/// Anything else — a timeout, a TLS failure, an HTTP status, a bad key — never gets the hint.
/// Even when it fits, the line says "if", because a phone with Wi-Fi off fails the same way.
enum LocalNetworkAccessHint {

    /// What the wearer was trying to reach, for the line's first words.
    enum Target: Equatable, Sendable {
        case agentGateway
        case hermesAgent
        case mcpServer
        case aiServer
    }

    /// The line to show or say. One short sentence of what failed, one of what to do.
    static func message(for target: Target) -> String {
        switch target {
        case .agentGateway:
            return String(localized: "Couldn't reach your agent gateway on your local network. If Local Network access is off for Avenkin, turn it on in Settings › Privacy & Security › Local Network.",
                          comment: "A request to the wearer's own agent gateway failed in the way iOS fails requests when the app's Local Network permission is off.")
        case .hermesAgent:
            return String(localized: "Couldn't reach Hermes on your local network. If Local Network access is off for Avenkin, turn it on in Settings › Privacy & Security › Local Network.",
                          comment: "A request to the wearer's own Hermes agent failed in the way iOS fails requests when the app's Local Network permission is off.")
        case .mcpServer:
            return String(localized: "Couldn't reach the MCP server on your local network. If Local Network access is off for Avenkin, turn it on in Settings › Privacy & Security › Local Network.",
                          comment: "A request to an MCP tool server on the wearer's own network failed in the way iOS fails requests when the app's Local Network permission is off.")
        case .aiServer:
            return String(localized: "Couldn't reach your AI server on your local network. If Local Network access is off for Avenkin, turn it on in Settings › Privacy & Security › Local Network.",
                          comment: "A request to the wearer's own AI model server (Ollama, LM Studio and the like) failed in the way iOS fails requests when the app's Local Network permission is off.")
        }
    }

    /// The line for `error`, or nil when the hint does not apply.
    static func line(for error: Error, host: String? = nil, target: Target) -> String? {
        isLikelyDenied(error, host: host) ? message(for: target) : nil
    }

    /// Whether `error`, from a request to `host`, may be the Local Network permission. `host`
    /// defaults to the failing URL the error itself carries.
    static func isLikelyDenied(_ error: Error, host: String? = nil) -> Bool {
        let chain = errorChain(error)
        if chain.contains(where: pathSaysDenied) { return true }

        guard let target = host ?? chain.lazy.compactMap(failingHost).first,
              isLocalNetworkHost(target) else { return false }
        // A refusal means the host answered: the path was open.
        if chain.contains(where: { posixCodes(of: $0).contains(Int(ECONNREFUSED)) }) { return false }
        return chain.contains { error in
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain, ns.code == URLError.notConnectedToInternet.rawValue { return true }
            return !posixCodes(of: error).isDisjoint(with: refusedPathCodes)
        }
    }

    /// A host the Local Network permission applies to: private, link-local or `.local`. Loopback,
    /// the shared address space (reached through a VPN) and public hosts are not gated by it.
    static func isLocalNetworkHost(_ host: String) -> Bool {
        switch URLFetchGuard.hostClass(host) {
        case .privateNetwork, .linkLocal, .localName: return true
        case .loopback, .sharedAddressSpace, .reserved, .publicHost: return false
        }
    }

    // MARK: - Reading the error

    /// ENETDOWN, ENETUNREACH, EHOSTUNREACH: what a socket on a refused local path reports.
    private static let refusedPathCodes: Set<Int> = [Int(ENETDOWN), Int(ENETUNREACH), Int(EHOSTUNREACH)]

    /// DNS-SD's "policy denied", which Bonjour and `NWConnection` report for this permission.
    private static let dnsPolicyDenied = -65570

    /// `URLSession` keeps the refused path and the socket error under these keys.
    private static let pathKey = "_NSURLErrorNWPathKey"
    private static let streamErrorCodeKey = "_kCFStreamErrorCodeKey"
    private static let streamErrorDomainKey = "_kCFStreamErrorDomainKey"
    /// `kCFStreamErrorDomainPOSIX`.
    private static let streamDomainPOSIX = 1

    /// The error and the errors underneath it, outermost first, a few deep.
    private static func errorChain(_ error: Error) -> [Error] {
        var chain: [Error] = [error]
        var current = error as NSError
        while chain.count < 5, let next = current.userInfo[NSUnderlyingErrorKey] as? NSError {
            chain.append(next)
            current = next
        }
        return chain
    }

    private static func pathSaysDenied(_ error: Error) -> Bool {
        if let nwError = error as? NWError, case .dns(let code) = nwError, Int(code) == dnsPolicyDenied {
            return true
        }
        let ns = error as NSError
        guard let path = ns.userInfo[pathKey] else { return false }
        if let path = path as? NWPath, case .unsatisfied = path.status {
            return path.unsatisfiedReason == .localNetworkDenied
        }
        let described = String(describing: path).lowercased()
        return described.contains("local network prohibited") || described.contains("localnetworkdenied")
    }

    private static func posixCodes(of error: Error) -> Set<Int> {
        var codes: Set<Int> = []
        if let nwError = error as? NWError, case .posix(let code) = nwError { codes.insert(Int(code.rawValue)) }
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain { codes.insert(ns.code) }
        if let code = ns.userInfo[streamErrorCodeKey] as? Int,
           (ns.userInfo[streamErrorDomainKey] as? Int) == streamDomainPOSIX {
            codes.insert(code)
        }
        return codes
    }

    private static func failingHost(_ error: Error) -> String? {
        let ns = error as NSError
        if let url = ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL, let host = url.host { return host }
        if let string = ns.userInfo[NSURLErrorFailingURLStringErrorKey] as? String,
           let host = URL(string: string)?.host {
            return host
        }
        return nil
    }
}
