import Foundation

/// The digest of a tool definition as it stood when it was last accepted, per server.
///
/// A discovery-time scan ([[ToolDefinitionScanner]]) judges the definition in front of it. It
/// cannot, on its own, notice that a server which passed review last week is now advertising a
/// different contract under the same names — which is exactly the shape a compromise takes: pass
/// review, then change. This store is the memory that makes that noticeable.
///
/// Content-free by construction: only one-way digests are written, never a name's description or
/// schema. The file is protected at rest and excluded from backup, because knowing which servers a
/// person has configured is itself something they did not ask to have copied off the device.
struct ToolDefinitionReview: Codable, Equatable {
    let digest: String
    let reviewedAt: Date
}

@MainActor
final class ToolDefinitionDigestStore {
    static let shared = ToolDefinitionDigestStore()

    nonisolated static let fileProtection = FileProtectionType.completeUntilFirstUserAuthentication

    private let directory: URL
    private let fileURL: URL
    /// `serverIdentity → toolName → review`.
    private var reviews: [String: [String: ToolDefinitionReview]] = [:]
    /// Whether the last write applied the protection attribute without error. The simulator accepts
    /// the attribute and then reports none back, so this — not a read-back — is what a headless
    /// test can check.
    private(set) var protectionApplied = false
    /// False after an unreadable or corrupt store. A store that cannot be read must not be treated
    /// as an empty one: that would silently re-accept every definition it had forgotten.
    private(set) var storageAvailable = true

    init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory()
        self.fileURL = self.directory.appendingPathComponent("tool-definition-digests.json")
        storageAvailable = load()
    }

    /// The store's location, for the protection assertion in tests and for diagnostics.
    var storeURL: URL { fileURL }

    // MARK: Queries

    /// What was accepted for this tool the last time it was reviewed, if anything.
    func review(server: String, tool: String) -> ToolDefinitionReview? {
        reviews[server]?[tool]
    }

    /// Every server this store remembers, for diagnostics.
    var knownServerIdentities: [String] { reviews.keys.sorted() }

    // MARK: Mutations

    /// Accept `digest` as the reviewed definition of `tool` on `server`.
    ///
    /// Called on a first sighting (nothing has changed if nothing was known) and when a person
    /// re-reviews a definition that changed. Never called for a definition the scanner blocked.
    @discardableResult
    func recordReviewed(server: String, tool: String, digest: String,
                        at now: Date = Date()) -> Bool {
        guard storageAvailable else { return false }
        reviews[server, default: [:]][tool] = ToolDefinitionReview(digest: digest, reviewedAt: now)
        return persist()
    }

    /// Forget everything about a server — used when its configuration is deleted, so a later server
    /// reusing the same id starts from a first sighting rather than inheriting a stranger's review.
    @discardableResult
    func forget(server: String) -> Bool {
        guard storageAvailable, reviews[server] != nil else { return storageAvailable }
        reviews[server] = nil
        return persist()
    }

    /// Drop entries for servers that are no longer configured.
    @discardableResult
    func prune(keeping serverIdentities: Set<String>) -> Bool {
        guard storageAvailable else { return false }
        let removals = reviews.keys.filter { !serverIdentities.contains($0) }
        guard !removals.isEmpty else { return true }
        for identity in removals { reviews[identity] = nil }
        return persist()
    }

    // MARK: Storage

    private static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("ToolTrust", isDirectory: true)
    }

    private func load() -> Bool {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return true }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            reviews = try decoder.decode([String: [String: ToolDefinitionReview]].self, from: data)
            return true
        } catch {
            // Do not overwrite an unreadable store with an empty one. Every tool it covered is
            // treated as changed until it can be read, which quarantines rather than admits.
            PrivacyLog.store(.toolDefinitionDigests, .loadFailed, error: SafeErrorSummary(error))
            return false
        }
    }

    @discardableResult
    private func persist() -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.protectionKey: Self.fileProtection])
            try encoder.encode(reviews).write(to: fileURL, options: .atomic)
            // An atomic write replaces the inode, so the attribute is re-applied every time.
            try FileManager.default.setAttributes([.protectionKey: Self.fileProtection],
                                                  ofItemAtPath: fileURL.path)
            protectionApplied = true
            var url = fileURL
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
            PrivacyLog.store(.toolDefinitionDigests, .saved)
            return true
        } catch {
            PrivacyLog.store(.toolDefinitionDigests, .saveFailed, error: SafeErrorSummary(error))
            return false
        }
    }
}

// MARK: - Re-review policy

/// What a definition's digest, compared with the one last accepted, does to its trust verdict.
///
/// Pure so the decision can be asserted without a filesystem, a server, or a network.
enum ToolDefinitionReviewPolicy {

    enum Outcome: Equatable {
        /// Nothing was known about this definition; the scanner's verdict stands and the digest
        /// should be recorded as the reviewed one.
        case firstSighting(ToolTrust)
        /// The digest matches what was accepted; the scanner's verdict stands unchanged.
        case unchanged(ToolTrust)
        /// The definition changed after it was accepted. Held until a person looks again.
        case changed(ToolTrust)

        var trust: ToolTrust {
            switch self {
            case .firstSighting(let trust), .unchanged(let trust), .changed(let trust):
                return trust
            }
        }

        /// Whether the caller should write `digest` back as the reviewed one.
        var shouldRecord: Bool {
            if case .firstSighting = self { return true }
            return false
        }
    }

    /// The reason a changed definition carries. Deliberately says nothing about *what* changed:
    /// the difference is between two attacker-authored documents, and quoting either is how a
    /// poisoned description reaches a screen.
    static let changedReason = "definition changed since it was last reviewed"

    /// Combine a discovery-time scan with what was last accepted.
    ///
    /// A `blocked` verdict is final — a definition that cannot be offered at all is not made more
    /// or less offerable by having been seen before. Everything else is held when the digest moved.
    static func evaluate(scanned: ToolTrust, previous: ToolDefinitionReview?,
                         current digest: String) -> Outcome {
        if case .blocked = scanned { return .unchanged(scanned) }
        guard let previous else { return .firstSighting(scanned) }
        guard previous.digest != digest else { return .unchanged(scanned) }
        return .changed(.quarantined(changedReason))
    }
}

// MARK: - What the model is allowed to read

/// What a discovered MCP tool's declaration says to the model.
///
/// A quarantined verdict means the app objected to the *definition itself* — a name that resembles
/// a native high-impact tool, a description carrying hidden instructions, a contract that moved
/// after review. Continuing to hand that description to the model is handing over the exact bytes
/// the scanner objected to: the model reads the poisoned line and the quarantine has achieved
/// nothing but a badge in a settings screen. So the description is replaced with one this app
/// wrote, and the tool stays reachable only under its qualified name, where the effect-class floor
/// holds every call to it for a bound approval.
enum MCPToolDeclarationPolicy {

    /// The app-authored stand-in for a withheld description.
    static func withheldDescription(serverLabel: String) -> String {
        "[\(serverLabel)] This tool's own description was withheld because it did not pass review. "
            + "Do not guess what it does; if the user asks for it, say it needs reviewing in "
            + "settings first."
    }

    static func description(for tool: MCPTool) -> String {
        guard case .quarantined = tool.trust else {
            return "[\(tool.serverLabel)] \(tool.description)"
        }
        return withheldDescription(serverLabel: tool.serverLabel)
    }
}
