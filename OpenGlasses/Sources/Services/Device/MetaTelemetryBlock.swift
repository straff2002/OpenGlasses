import Foundation

/// Stops the Meta wearables SDK from phoning home.
///
/// # Why this exists
///
/// `MWDATCore` ships an analytics pipeline that POSTs SDK event batches
/// (`ar_wearables_sdk_*` — session, stream, permission, display, crash) to a hard-coded
/// endpoint on `api2.ar.meta.com`. The supported way to switch that off is the
/// `MWDAT/Analytics/OptOut` and `MWDAT/CrashReporting/OptOut` Info.plist keys, which this
/// app sets. Those keys are the primary control and this type is *not* a substitute for them.
///
/// This is the backstop. The opt-out is a plist flag read by a closed-source binary we ship
/// but do not build: a stale personal plist, a missed key after an SDK bump, or a change in
/// how that flag is honoured would silently restore the uploads, and nothing in a build log
/// would say so. Registering a `URLProtocol` puts the guarantee in code we own — the request
/// cannot leave the process regardless of what the SDK decides — and gives us a counter that
/// makes a regression visible instead of silent.
///
/// # Scope
///
/// Only the telemetry endpoint is intercepted. Attestation
/// (`/wearables/attestation/challenge`) is how the SDK proves the app is entitled to talk to
/// the glasses; blocking that would break device access, not privacy, so it is deliberately
/// left alone. Nothing else in the app routes through here.
enum MetaTelemetryBlock {

    /// Host that serves both the telemetry and attestation endpoints.
    static let telemetryHost = "api2.ar.meta.com"

    /// Path prefix of the SDK's analytics/crash upload endpoint.
    static let telemetryPathPrefix = "/mwsdk/telemetry"

    /// Number of uploads stopped this process. Non-zero means the plist opt-out did not take —
    /// worth surfacing in diagnostics rather than leaving to a packet capture to discover.
    private(set) nonisolated(unsafe) static var blockedCount = 0

    private nonisolated(unsafe) static var isInstalled = false

    /// Whether `url` is the SDK's telemetry upload endpoint.
    ///
    /// Matched on host + path prefix rather than the full string: the SDK appends its own
    /// query/segments, and matching the whole URL would fail open on the first change.
    static func isTelemetryURL(_ url: URL?) -> Bool {
        guard let url, let host = url.host?.lowercased() else { return false }
        guard host == telemetryHost else { return false }
        return url.path.hasPrefix(telemetryPathPrefix)
    }

    // MARK: - Info.plist opt-out (the primary control)

    /// Whether the SDK's two data-collection opt-outs are set in an Info dictionary.
    ///
    /// Pure and dictionary-injected so the Developer panel can assert the *shipped* bundle
    /// really carries them. The keys live at `MWDAT/Analytics/OptOut` and
    /// `MWDAT/CrashReporting/OptOut`, and absent means opted **in** — so a missing key has to
    /// read as `false` here, never as a benign default.
    static func plistOptOut(in infoDictionary: [String: Any]?) -> (analytics: Bool, crashReporting: Bool) {
        let mwdat = infoDictionary?["MWDAT"] as? [String: Any]
        func optOut(_ section: String) -> Bool {
            ((mwdat?[section] as? [String: Any])?["OptOut"] as? Bool) ?? false
        }
        return (optOut("Analytics"), optOut("CrashReporting"))
    }

    /// The running app's opt-out state.
    static var bundleOptOut: (analytics: Bool, crashReporting: Bool) {
        plistOptOut(in: Bundle.main.infoDictionary)
    }

    // MARK: - Disclosure

    /// What Settings tells the user about the glasses SDK's data collection.
    ///
    /// Deliberately has an honest failure case. `.off` is only claimed when the opt-out is
    /// present *and* nothing has had to be intercepted — a privacy claim the app cannot back
    /// up is worse than no claim.
    enum Disclosure: Equatable {
        /// Opt-out set and no upload ever attempted.
        case off
        /// Opt-out set but ignored; `count` uploads were stopped at the network layer.
        case blocked(Int)
        /// Opt-out missing from the bundle — the SDK's default, which is opted in.
        case on

        var summary: String {
            switch self {
            case .off: return "Off"
            case .blocked: return "Blocked"
            case .on: return "On"
            }
        }
    }

    /// Pure form, so the disclosure can be tested without a bundle or a live process.
    static func disclosure(optOut: (analytics: Bool, crashReporting: Bool),
                           blockedCount: Int) -> Disclosure {
        guard optOut.analytics && optOut.crashReporting else { return .on }
        return blockedCount == 0 ? .off : .blocked(blockedCount)
    }

    /// The running app's disclosure state.
    static var disclosureState: Disclosure {
        disclosure(optOut: bundleOptOut, blockedCount: blockedCount)
    }

    /// Register the interceptor. Idempotent; call before `Wearables.configure()`.
    static func install() {
        guard !isInstalled else { return }
        isInstalled = true
        URLProtocol.registerClass(Interceptor.self)
    }

    /// One-line state for diagnostics surfaces.
    static var statusDescription: String {
        guard isInstalled else { return "not installed" }
        return blockedCount == 0 ? "installed" : "installed — \(blockedCount) upload(s) blocked"
    }

    fileprivate static func recordBlock(_ url: URL?) {
        blockedCount += 1
        if blockedCount == 1 {
            NSLog("[MetaTelemetryBlock] blocked SDK telemetry upload to %@ (plist opt-out did not take)",
                  url?.absoluteString ?? "?")
        }
    }

    /// Answers the upload locally instead of letting it reach the network.
    final class Interceptor: URLProtocol {

        override class func canInit(with request: URLRequest) -> Bool {
            isTelemetryURL(request.url)
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            MetaTelemetryBlock.recordBlock(request.url)
            // 204 rather than an error: the uploader treats a failure as "retry later" and keeps
            // the batch on disk, so failing it would leave a growing local queue and a retry loop
            // for uploads that can never succeed. A success drops the batch — the payload is
            // discarded here and never sent.
            let response = HTTPURLResponse(url: request.url ?? URL(string: "https://\(MetaTelemetryBlock.telemetryHost)")!,
                                           statusCode: 204,
                                           httpVersion: "HTTP/1.1",
                                           headerFields: nil)
            if let response {
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            }
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    #if DEBUG
    /// Reset counters for tests. Registration itself is process-wide and is left in place.
    static func resetCountForTesting() {
        blockedCount = 0
    }
    #endif
}
