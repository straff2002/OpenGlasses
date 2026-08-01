import Foundation

/// Plan BZ — the live edge of the notification digest: maintains the item set fed by the
/// first-party sources (calendar/proactive, geofence, agent queue), composes on demand, runs
/// the LLM rewrite with the deterministic fallback as the guaranteed floor, and drives the
/// HUD glance / spoken delivery. Persistence rides `JSONStore` semantics (BB): a salvaged or
/// corrupt blob is backed up before anything overwrites it, and an unreadable one is never
/// written over.
@MainActor
final class NotificationDigestService: ObservableObject {

    @Published private(set) var items: [DigestItem] = []
    /// The digest currently (or last) shown — dismissal acknowledges these items.
    @Published private(set) var lastPresented: Digest?

    /// Wired by AppState.
    weak var hudRouter: HUDRouter?
    weak var presence: PresenceMonitor?
    var speak: ((String) -> Void)?
    /// One-shot structured LLM call (`LLMService.completeStructured`) — never the
    /// conversation path, so a rewrite can't pollute chat history.
    var rewrite: ((_ prompt: String, _ schema: [String: Any]) async -> [String: Any]?)?
    /// P3: dismissal acknowledges the agent notifications the digest showed.
    var acknowledgeAgentItems: ((Set<String>) -> Void)?
    var isOffline: () -> Bool = { false }
    var powerPosture: () -> PowerPosture = { PowerPolicyService.shared.posture }

    private let storageURL: URL
    private var allowsSaving = true
    /// Keep the store bounded — retired items are pruned on every save.
    private let maxStoredItems = 50

    init(storageURL: URL? = nil) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.storageURL = storageURL ?? docs.appendingPathComponent("notification_digest.json")
        load()
    }

    // MARK: - Ingest (called from AppState source wiring)

    func ingest(source: DigestSource, title: String, body: String = "",
                priority: NotificationPriority, threadKey: String? = nil,
                eventDate: Date? = nil, awaitingReply: Bool = false) {
        guard Config.digestEnabled else { return }
        let item = DigestItem(source: source, title: title, rawBody: body, createdAt: Date(),
                              priority: priority, threadKey: threadKey, eventDate: eventDate,
                              awaitingReply: awaitingReply)
        items.append(item)
        prune()
        save()
    }

    /// Whether a glance would show anything right now (gates the launcher item).
    var hasContent: Bool {
        !DigestComposer.compose(items, now: Date(), topN: Config.digestMaxItems).isEmpty
    }

    /// Whether an urgent item is pending (gates auto-surface on connect).
    var hasUrgentContent: Bool {
        let now = Date()
        return DigestComposer.compose(items, now: now, topN: Config.digestMaxItems)
            .items.contains { DigestRanker.tier(of: $0, now: now) == .urgent }
    }

    // MARK: - Presentation

    /// Compose and surface the digest per the configured delivery (visual glance / spoken /
    /// both). Marks the shown items seen. Speaks "nothing new" only on explicit request.
    func presentGlance(explicit: Bool = true) async {
        guard Config.digestEnabled else { return }
        let now = Date()
        let digest = DigestComposer.compose(items, now: now, topN: Config.digestMaxItems)
        guard !digest.isEmpty else {
            if explicit { speak?("Nothing new.") }
            return
        }

        let lines = await composedLines(for: digest, now: now)
        lastPresented = digest

        let delivery = Config.digestDelivery
        if delivery != .spoken, let router = hudRouter {
            let screen = Self.glanceScreen(lines: lines, overflowCount: digest.overflowCount) { [weak self] in
                self?.dismissGlance()
            }
            router.openLauncher(screen)
        }
        if delivery != .visual || hudRouter == nil {
            if let spoken = DigestLineBuilder.spokenDigest(lines: lines, overflowCount: digest.overflowCount) {
                speak?(spoken)
            }
        }

        markSeen(digest)
    }

    /// Dismiss the glance: close the screen and acknowledge what it showed (P3 — agent items
    /// are marked delivered at the source so the reconnect path doesn't re-speak them).
    func dismissGlance() {
        if hudRouter?.isPresentingMenu == true { hudRouter?.dismiss() }
        if let digest = lastPresented {
            let agentIds = Set(digest.items.filter { $0.source == .agent }.compactMap(\.threadKey))
            if !agentIds.isEmpty { acknowledgeAgentItems?(agentIds) }
            retire(digest)
        }
        lastPresented = nil
    }

    /// Auto-surface on glasses (re)connect: only with an urgent item pending, only when the
    /// user is actually there (Plan W), and never under power reserve (Plan BV).
    func autoSurfaceOnConnect() async {
        guard Config.digestEnabled, Config.digestAutoSurfaceOnConnect else { return }
        guard hasUrgentContent else { return }
        if let presence, presence.mode == .away { return }
        guard powerPosture() != .reserve else { return }
        await presentGlance(explicit: false)
    }

    /// Clear everything (settings action).
    func clearAll() {
        items.removeAll()
        lastPresented = nil
        save()
    }

    // MARK: - Rewrite

    /// Pure gate, unit-tested: the LLM rewrite is skipped offline and under power reserve —
    /// fallback lines are the floor, the digest itself is never suppressed.
    nonisolated static func shouldRewrite(posture: PowerPosture, offline: Bool) -> Bool {
        !offline && posture != .reserve
    }

    private func composedLines(for digest: Digest, now: Date) async -> [String] {
        guard Self.shouldRewrite(posture: powerPosture(), offline: isOffline()),
              let rewrite else {
            return DigestLineBuilder.lines(for: digest, rewritten: nil, now: now)
        }
        let response = await rewrite(DigestLineBuilder.rewritePrompt(for: digest, now: now),
                                     DigestLineBuilder.rewriteSchema())
        let rewritten = response?["lines"] as? [String]
        return DigestLineBuilder.lines(for: digest, rewritten: rewritten, now: now)
    }

    // MARK: - Glance screen (pure, tested)

    static func glanceScreen(lines: [String], overflowCount: Int,
                             onDismiss: @escaping () -> Void) -> HUDScreen {
        var hudLines = lines.map { HUDLine($0, emphasis: .primary) }
        if overflowCount > 0 {
            hudLines.append(HUDLine("+\(overflowCount) more", emphasis: .meta))
        }
        return HUDScreen(title: "What's new", lines: hudLines, items: [
            HUDItem(id: "dismiss", label: "Dismiss", style: .primary) { onDismiss() },
        ])
    }

    // MARK: - Internals

    private func markSeen(_ digest: Digest) {
        let shown = Set(digest.items.map(\.id))
        for index in items.indices where shown.contains(items[index].id) {
            items[index].seenCount += 1
        }
        save()
    }

    /// Force-retire the dismissed items (seen cap) so they never resurface.
    private func retire(_ digest: Digest) {
        let shown = Set(digest.items.map(\.id))
        for index in items.indices where shown.contains(items[index].id) {
            items[index].seenCount = max(items[index].seenCount, 99)
        }
        prune()
        save()
    }

    private func prune() {
        let now = Date()
        items.removeAll { DigestStaleness.isRetired($0, now: now, seenCap: 99) }
        if items.count > maxStoredItems {
            items.removeFirst(items.count - maxStoredItems)
        }
    }

    // MARK: - Persistence (BB semantics)

    private func load() {
        switch JSONStore.loadArray(DigestItem.self, at: storageURL, name: "notification_digest") {
        case .loaded(let stored), .recovered(let stored, _):
            items = stored
        case .absent:
            break
        case .corrupt:
            break   // backed up by JSONStore; start fresh, save on next explicit change
        case .unreadable:
            allowsSaving = false   // bytes may be fine (device locked) — never overwrite
        }
    }

    private func save() {
        guard allowsSaving else { return }
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: storageURL, options: .atomic)
    }
}
