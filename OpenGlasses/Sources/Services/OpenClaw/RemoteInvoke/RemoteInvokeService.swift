import Foundation

/// Thrown by executor closures when the app services they capture have gone away.
enum RemoteInvokeError: LocalizedError {
    case unavailable
    var errorDescription: String? { "Device services unavailable" }
}

/// One audited remote-invoke exchange (Plan BH). Persisted as a small ring so the user can
/// inspect exactly what a gateway agent asked for and what happened.
struct RemoteInvokeAuditEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    /// Who issued the command — "gateway" / "peer:<id>" (Plan BN P2). Attributes each row so a
    /// specific caller's activity is traceable.
    let origin: String
    let action: String
    let disposition: String   // "allowed" / "denied: …" / "unsupported" / "malformed" / "failed: …" / "declined"

    init(id: UUID = UUID(), timestamp: Date = Date(), origin: String = RemoteCommandOrigin.gateway.label,
         action: String, disposition: String) {
        self.id = id
        self.timestamp = timestamp
        self.origin = origin
        self.action = action
        self.disposition = disposition
    }

    // Backward-compatible decode: entries persisted before BN P2 have no `origin` — default them
    // to the gateway (the only caller that existed then) so the saved log still loads.
    enum CodingKeys: String, CodingKey { case id, timestamp, origin, action, disposition }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        origin = try c.decodeIfPresent(String.self, forKey: .origin) ?? RemoteCommandOrigin.gateway.label
        action = try c.decode(String.self, forKey: .action)
        disposition = try c.decode(String.self, forKey: .disposition)
    }
}

/// The remote-invoke pipeline (Plan BH): inbound gateway request frame → parse → policy →
/// (execute) → reply envelope, with every exchange audited. This is the only place the pieces
/// meet; each piece stays pure and independently tested.
///
/// Deny-by-default: with Agent Mode off the policy denies every command *before* the executor
/// is ever consulted — no code path reaches a device service, and the deny reply carries a
/// structured reason so the server-side agent can explain itself instead of retrying.
@MainActor
final class RemoteInvokeService: ObservableObject {

    /// Live config read on every frame (a toggle flipped in Settings applies immediately).
    struct Environment {
        var agentModeEnabled: @MainActor () -> Bool
        var toggles: @MainActor () -> RemoteCommandPolicy.Toggles
        var now: () -> Date
    }

    @Published private(set) var auditLog: [RemoteInvokeAuditEntry]

    private let environment: Environment
    private let executor: RemoteCommandExecutor
    private var rateState: RemoteInvokeRateState

    private static let auditKey = "remoteInvokeAuditLog"
    private static let auditLimit = 100

    init(environment: Environment, executor: RemoteCommandExecutor) {
        self.environment = environment
        self.executor = executor
        self.rateState = RemoteInvokeRateState(now: environment.now())
        self.auditLog = Self.loadAudit()
    }

    /// Handle one decoded inbound frame. Returns the reply to send, or `nil` when the frame is
    /// not a request at all (events/responses are the caller's business). `origin` attributes the
    /// caller (Plan BN P2) — the gateway socket passes the default; an MCP peer (BL P4) passes
    /// `.mcpPeer(id:)` so it gets its own rate budget and audit rows.
    func handleFrame(_ json: [String: Any], origin: RemoteCommandOrigin = .gateway) async -> [String: Any]? {
        guard let request = RemoteCommandParser.parse(json) else { return nil }

        switch request.outcome {
        case .malformed(let reason):
            audit(origin: origin, action: "malformed", disposition: "malformed: \(reason)")
            return RemoteInvokeReply.malformed(id: request.id, reason: reason)

        case .unsupported(let action):
            audit(origin: origin, action: action, disposition: "unsupported")
            return RemoteInvokeReply.unsupported(id: request.id, action: action)

        case .command(let command):
            let decision = RemoteCommandPolicy.decide(
                command: command,
                origin: origin,
                agentModeEnabled: environment.agentModeEnabled(),
                toggles: environment.toggles(),
                rateState: &rateState,
                now: environment.now()
            )
            switch decision {
            case .deny(let reason):
                audit(origin: origin, action: command.canonicalAction, disposition: "denied: \(reason.code)")
                return RemoteInvokeReply.denied(id: request.id, reason: reason)

            case .allow:
                switch await executor.execute(command, origin: origin) {
                case .success(let payload):
                    audit(origin: origin, action: command.canonicalAction, disposition: "allowed")
                    return RemoteInvokeReply.success(id: request.id, payload: payload)
                case .declined:
                    audit(origin: origin, action: command.canonicalAction, disposition: "declined")
                    return RemoteInvokeReply.failure(id: request.id, message: "User declined the request")
                case .failed(let message):
                    audit(origin: origin, action: command.canonicalAction, disposition: "failed: \(message)")
                    return RemoteInvokeReply.failure(id: request.id, message: message)
                }
            }
        }
    }

    func clearAudit() {
        auditLog = []
        UserDefaults.standard.removeObject(forKey: Self.auditKey)
    }

    // MARK: - Private

    private func audit(origin: RemoteCommandOrigin, action: String, disposition: String) {
        auditLog.insert(RemoteInvokeAuditEntry(origin: origin.label, action: action, disposition: disposition), at: 0)
        if auditLog.count > Self.auditLimit { auditLog = Array(auditLog.prefix(Self.auditLimit)) }
        if let data = try? JSONEncoder().encode(auditLog) {
            UserDefaults.standard.set(data, forKey: Self.auditKey)
        }
    }

    private static func loadAudit() -> [RemoteInvokeAuditEntry] {
        guard let data = UserDefaults.standard.data(forKey: auditKey),
              let entries = try? JSONDecoder().decode([RemoteInvokeAuditEntry].self, from: data) else { return [] }
        return entries
    }
}
