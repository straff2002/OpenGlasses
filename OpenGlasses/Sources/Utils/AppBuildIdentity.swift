import Foundation

/// Which copy of the app this is: version, build, the source it was generated from, how it was
/// installed and under which bundle id.
///
/// A support report used to carry the version and build alone, and a build number does not name a
/// commit — several merges can share one — nor say whether the phone runs the published app or a
/// contributor's own build of it (support report, 2026-10-05: neither could be answered).
struct AppBuildIdentity: Equatable {
    enum Channel: String, Equatable {
        case appStore = "App Store"
        case testFlight = "TestFlight"
        /// Signed with a development or ad-hoc profile: built and installed from Xcode, or
        /// side-loaded. A contributor's own build is always this.
        case development = "development build"
        case simulator = "simulator"
    }

    /// The Info.plist key the generated project fills with the commit (see
    /// `Scripts/generate-xcodeproj.sh`).
    static let commitKey = "AvenkinSourceCommit"

    var version: String
    var build: String
    /// The commit the Xcode project was generated at, shortened. Exact for a cloud build, which
    /// generates on every run; for a local build it is the commit at the last regeneration, so the
    /// source can be newer — never older. Nil when the build was not stamped.
    var commit: String?
    var channel: Channel
    var bundleID: String

    /// How this copy was installed, from what the bundle carries. A store or TestFlight build has
    /// its provisioning profile stripped; only TestFlight's receipt is the sandbox one.
    static func channel(isSimulator: Bool, hasEmbeddedProfile: Bool, receiptName: String?) -> Channel {
        if isSimulator { return .simulator }
        if hasEmbeddedProfile { return .development }
        return receiptName == "sandboxReceipt" ? .testFlight : .appStore
    }

    /// An unstamped build leaves the placeholder unexpanded, empty or "unknown"; none is a commit.
    static func commit(fromInfoValue value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespaces),
              !value.isEmpty, value != "unknown", !value.contains("$"),
              value.allSatisfy(\.isHexDigit) else { return nil }
        return String(value.prefix(9))
    }

    /// One line, for a report's header: `2026.10 (460) · 1a2b3c4d5 · TestFlight · com.example.app`.
    var summary: String {
        (["\(version) (\(build))"] + [commit, channel.rawValue, bundleID].compactMap { $0 })
            .joined(separator: " · ")
    }

    static var current: AppBuildIdentity {
        let bundle = Bundle.main
        func info(_ key: String) -> String? { bundle.object(forInfoDictionaryKey: key) as? String }
        #if targetEnvironment(simulator)
        let isSimulator = true
        #else
        let isSimulator = false
        #endif
        return AppBuildIdentity(
            version: info("CFBundleShortVersionString") ?? "–",
            build: info("CFBundleVersion") ?? "–",
            commit: commit(fromInfoValue: info(commitKey)),
            channel: channel(
                isSimulator: isSimulator,
                hasEmbeddedProfile: bundle.url(forResource: "embedded", withExtension: "mobileprovision") != nil,
                receiptName: receiptName(in: bundle)),
            bundleID: bundle.bundleIdentifier ?? "–")
    }

    /// The receipt's file name: `receipt` for a store install, `sandboxReceipt` for TestFlight.
    /// Only the name is wanted — the file need not exist — and the property that carries it is
    /// deprecated in favour of an asynchronous StoreKit call that can wait on the network, which a
    /// report written offline cannot. Read by key, behind a check that the property is still there.
    private static func receiptName(in bundle: Bundle) -> String? {
        let key = "appStoreReceiptURL"
        guard bundle.responds(to: NSSelectorFromString(key)) else { return nil }
        return (bundle.value(forKey: key) as? URL)?.lastPathComponent
    }
}
