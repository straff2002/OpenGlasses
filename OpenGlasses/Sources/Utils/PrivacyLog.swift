import Foundation
import CryptoKit
import os

/// Structured, metadata-only logging for production builds.
///
/// A device log is readable by anything with the device in hand, survives into sysdiagnose
/// bundles, and is the one place in the app where content escapes every other control we built —
/// the vault encryption, the egress screen, the privacy filter. So the rule here is not "redact
/// carefully": there is **no production method that accepts an arbitrary `String` message**.
/// Callers pass a fixed event name, counts, durations, outcome enums, and identifiers they have
/// explicitly wrapped in `PrivateIdentifier` (which hashes them). A transcript, a tool argument,
/// a QR payload, a URL with a query, or a `localizedDescription` has no parameter to arrive in.
///
/// The classification this implements:
///
/// | Class | Treatment here |
/// |---|---|
/// | Public operation | event name, counts, durations, `Bool` outcomes — persisted |
/// | Private identifier | `PrivateIdentifier` — one-way fingerprint only |
/// | User content | no parameter accepts it |
/// | Secret | no parameter accepts it |
/// | Regulated/sensitive | counts and operation classes only |
///
/// Errors inherit the classification of the request that produced them, so error paths take a
/// `SafeErrorSummary` rather than an `Error`: see that type for why `localizedDescription` is
/// never read.
enum PrivacyLog {

    // MARK: - Categories

    /// Fixed subsystem categories. Adding one is a deliberate act — a category is how a reader
    /// (and a future diagnostics export) filters, so an open-ended set defeats the point.
    enum Category: String {
        /// Tool dispatch: which tool, how long, what verdict.
        case tools
        /// Live model sessions (Gemini Live, OpenAI Realtime): state, counts, timing.
        case realtime
        /// Camera-derived capture: QR, frames.
        case capture
        /// Home/automation control. Entities and commands are regulated — counts only.
        case home
        /// App lifecycle and inbound links.
        case lifecycle
        /// Sign-in and credential refresh. Never a token, never a callback URL.
        case auth
        /// Transport-level request failures, below the operation that asked for them.
        case network
        /// The agent gateway link: endpoint selection, socket lifecycle, pairing, protocol calls.
        case gateway
        /// Model Context Protocol — both the client we run and the local server we expose.
        case mcp
        /// Outbound media links: viewer broadcast, expert bridge, HUD mirror, their signalling.
        case stream
    }

    // MARK: - Sink

    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.openglasses.app"

    private static let loggers: [Category: Logger] = {
        var made: [Category: Logger] = [:]
        for category in [Category.tools, .realtime, .capture, .home, .lifecycle, .auth, .network,
                         .gateway, .mcp, .stream] {
            made[category] = Logger(subsystem: subsystem, category: category.rawValue)
        }
        return made
    }()

    /// The one place an event reaches the OS. Everything above it is pure and testable; the
    /// encoded line is marked `.public` because, by construction, nothing private got into it.
    @discardableResult
    static func emit(_ event: PrivacyEvent) -> PrivacyEvent {
        let line = PrivacyEventEncoder.encode(event)
        loggers[event.category]?.log("\(line, privacy: .public)")
        return event
    }

    // MARK: - Debug-only content escape hatch
    //
    // Deliberately gated behind BOTH `DEBUG` and a compilation condition that is defined in no
    // build configuration in this repo (`project.base.yml` / `project.tests.yml`). Turning it on
    // is a local, uncommitted edit; a test asserts the flag never appears in a checked-in spec.
    // The prefix is conspicuous so a line that escapes into a shared log is obvious on sight.
    #if DEBUG && ENABLE_CONTENT_LOGGING
    static func debugContent(_ category: Category, _ name: PrivacyEvent.Name,
                             _ content: @autoclosure () -> String) {
        loggers[category]?.debug(
            "⚠️ CONTENT-LOG (debug only) \(name.rawValue, privacy: .public): \(content(), privacy: .private)")
    }
    #endif

    // MARK: - Tools

    /// Outcome classes mirror `ToolExecutionOutcome`'s cases without their reason strings — the
    /// reason is the tool's own text, i.e. user content.
    enum ToolOutcome: String {
        case completed, rejected, failedBeforeExecution, outcomeUnknown
    }

    @discardableResult
    static func toolCallReceived(name: String, invocation: String) -> PrivacyEvent {
        return emit(.init(.tools, .toolCallReceived, [
            .init(.tool, .token(PrivacyToken(name))),
            .init(.invocation, .identifier(PrivateIdentifier(invocation))),
        ]))
    }

    @discardableResult
    static func toolCallRefused(name: String, invocation: String) -> PrivacyEvent {
        return emit(.init(.tools, .toolCallRefused, [
            .init(.tool, .token(PrivacyToken(name))),
            .init(.invocation, .identifier(PrivateIdentifier(invocation))),
        ]))
    }

    @discardableResult
    static func toolCallAcked(name: String, invocation: String) -> PrivacyEvent {
        return emit(.init(.tools, .toolCallAcked, [
            .init(.tool, .token(PrivacyToken(name))),
            .init(.invocation, .identifier(PrivateIdentifier(invocation))),
        ]))
    }

    @discardableResult
    static func toolCallCancelled(invocation: String) -> PrivacyEvent {
        return emit(.init(.tools, .toolCallCancelled, [
            .init(.invocation, .identifier(PrivateIdentifier(invocation))),
        ]))
    }

    @discardableResult
    static func toolCallCompleted(name: String, invocation: String,
                                  outcome: ToolOutcome, durationMs: Int) -> PrivacyEvent {
        return emit(.init(.tools, .toolCallCompleted, [
            .init(.tool, .token(PrivacyToken(name))),
            .init(.invocation, .identifier(PrivateIdentifier(invocation))),
            .init(.outcome, .token(PrivacyToken(outcome.rawValue))),
            .init(.duration, .milliseconds(durationMs)),
        ]))
    }

    // MARK: - Realtime sessions

    enum RealtimeProvider: String { case openai, gemini }

    /// State transitions and protocol milestones. No case carries model or user text.
    enum RealtimeSessionEvent: String {
        case sessionCreated, sessionConfigured, sessionUpdateSent
        case userInterrupted, intentionalDisconnect, reconnected
        case modelSubstituted, unhandledEvent
    }

    enum UtteranceDirection: String { case input, output }
    enum RealtimeMediaKind: String { case streamedFrame, sharpFrame }
    enum RealtimeSendKind: String { case text, image, frame }
    enum RealtimeSkipReason: String { case notReady, encodingFailed }
    enum RealtimeErrorPhase: String { case send, receive, fatal, recoverable }

    @discardableResult
    static func realtimeSession(_ provider: RealtimeProvider, _ event: RealtimeSessionEvent,
                                detail: PrivacyToken? = nil) -> PrivacyEvent {
        var fields: [PrivacyEvent.Field] = [
            .init(.provider, .token(PrivacyToken(provider.rawValue))),
            .init(.event, .token(PrivacyToken(event.rawValue))),
        ]
        if let detail { fields.append(.init(.detail, .token(detail))) }
        return emit(.init(.realtime, .realtimeSession, fields))
    }

    /// One utterance crossed the wire. The text itself never does — only how much of it there was,
    /// which is what a latency or truncation investigation actually needs.
    @discardableResult
    static func realtimeUtterance(_ provider: RealtimeProvider,
                                  direction: UtteranceDirection, characters: Int) -> PrivacyEvent {
        return emit(.init(.realtime, .realtimeUtterance, [
            .init(.provider, .token(PrivacyToken(provider.rawValue))),
            .init(.direction, .token(PrivacyToken(direction.rawValue))),
            .init(.characters, .count(characters)),
        ]))
    }

    @discardableResult
    static func realtimeMedia(_ provider: RealtimeProvider, kind: RealtimeMediaKind,
                              kilobytes: Int, sequence: Int? = nil) -> PrivacyEvent {
        var fields: [PrivacyEvent.Field] = [
            .init(.provider, .token(PrivacyToken(provider.rawValue))),
            .init(.kind, .token(PrivacyToken(kind.rawValue))),
            .init(.kilobytes, .count(kilobytes)),
        ]
        if let sequence { fields.append(.init(.sequence, .count(sequence))) }
        return emit(.init(.realtime, .realtimeMedia, fields))
    }

    @discardableResult
    static func realtimeSendSkipped(_ provider: RealtimeProvider, kind: RealtimeSendKind,
                                    reason: RealtimeSkipReason, state: PrivacyToken? = nil) -> PrivacyEvent {
        var fields: [PrivacyEvent.Field] = [
            .init(.provider, .token(PrivacyToken(provider.rawValue))),
            .init(.kind, .token(PrivacyToken(kind.rawValue))),
            .init(.reason, .token(PrivacyToken(reason.rawValue))),
        ]
        if let state { fields.append(.init(.state, .token(state))) }
        return emit(.init(.realtime, .realtimeSendSkipped, fields))
    }

    @discardableResult
    static func realtimeTruncated(_ provider: RealtimeProvider, item: String, playedMs: Int) -> PrivacyEvent {
        return emit(.init(.realtime, .realtimeTruncated, [
            .init(.provider, .token(PrivacyToken(provider.rawValue))),
            .init(.item, .identifier(PrivateIdentifier(item))),
            .init(.duration, .milliseconds(playedMs)),
        ]))
    }

    @discardableResult
    static func realtimeReconnectScheduled(_ provider: RealtimeProvider,
                                           attempt: Int, of maxAttempts: Int, delaySeconds: Double) -> PrivacyEvent {
        return emit(.init(.realtime, .realtimeReconnectScheduled, [
            .init(.provider, .token(PrivacyToken(provider.rawValue))),
            .init(.attempt, .count(attempt)),
            .init(.ofAttempts, .count(maxAttempts)),
            .init(.delay, .seconds(delaySeconds)),
        ]))
    }

    /// The reconnect reason is deliberately absent: every caller derives it from an error's
    /// `localizedDescription`, which is user-content class.
    @discardableResult
    static func realtimeReconnectExhausted(_ provider: RealtimeProvider, attempts: Int) -> PrivacyEvent {
        return emit(.init(.realtime, .realtimeReconnectExhausted, [
            .init(.provider, .token(PrivacyToken(provider.rawValue))),
            .init(.attempt, .count(attempts)),
        ]))
    }

    @discardableResult
    static func realtimeGoAway(_ provider: RealtimeProvider, secondsRemaining: Int) -> PrivacyEvent {
        return emit(.init(.realtime, .realtimeGoAway, [
            .init(.provider, .token(PrivacyToken(provider.rawValue))),
            .init(.remaining, .count(secondsRemaining)),
        ]))
    }

    @discardableResult
    static func realtimeToolCall(_ provider: RealtimeProvider, functions: Int) -> PrivacyEvent {
        return emit(.init(.realtime, .realtimeToolCall, [
            .init(.provider, .token(PrivacyToken(provider.rawValue))),
            .init(.count, .count(functions)),
        ]))
    }

    /// Call ids are private identifiers and there can be many, so the count is what is kept.
    @discardableResult
    static func realtimeToolCancellation(_ provider: RealtimeProvider, calls: Int) -> PrivacyEvent {
        return emit(.init(.realtime, .realtimeToolCancellation, [
            .init(.provider, .token(PrivacyToken(provider.rawValue))),
            .init(.count, .count(calls)),
        ]))
    }

    @discardableResult
    static func realtimeLatency(_ provider: RealtimeProvider, milliseconds: Int) -> PrivacyEvent {
        return emit(.init(.realtime, .realtimeLatency, [
            .init(.provider, .token(PrivacyToken(provider.rawValue))),
            .init(.duration, .milliseconds(milliseconds)),
        ]))
    }

    @discardableResult
    static func realtimeError(_ provider: RealtimeProvider, phase: RealtimeErrorPhase,
                              _ summary: SafeErrorSummary) -> PrivacyEvent {
        return emit(.init(.realtime, .realtimeError, [
            .init(.provider, .token(PrivacyToken(provider.rawValue))),
            .init(.phase, .token(PrivacyToken(phase.rawValue))),
            .init(.error, .summary(summary)),
        ]))
    }

    // MARK: - Capture

    /// What kind of thing the code held, never the thing itself.
    enum QRPayloadClass: String { case url, json, text }

    @discardableResult
    static func qrScanned(payload: QRPayloadClass, bytes: Int) -> PrivacyEvent {
        return emit(.init(.capture, .qrScanned, [
            .init(.payload, .token(PrivacyToken(payload.rawValue))),
            .init(.bytes, .count(bytes)),
        ]))
    }

    @discardableResult
    static func qrFetchBlocked(_ summary: SafeErrorSummary) -> PrivacyEvent {
        return emit(.init(.capture, .qrFetchBlocked, [
            .init(.error, .summary(summary)),
        ]))
    }

    /// The host is a private identifier (it names where the wearer was), so it is fingerprinted:
    /// enough to see two fetches went to the same place, not enough to say where.
    @discardableResult
    static func qrFetchLoaded(host: String?, characters: Int) -> PrivacyEvent {
        var fields: [PrivacyEvent.Field] = [.init(.characters, .count(characters))]
        if let host, !host.isEmpty {
            fields.insert(.init(.host, .identifier(PrivateIdentifier(host))), at: 0)
        }
        return emit(.init(.capture, .qrFetchLoaded, fields))
    }

    // MARK: - Home

    /// Operation classes, not commands. An entity id names a room and a device in someone's
    /// house; hashing it would not anonymise a dictionary that small, so it is simply omitted.
    enum HomeOperation: String {
        case converse, callService, getState, listEntities, runAutomation, toggle
    }

    enum HomeEntityMatch: String { case exact, fuzzy, unresolved }

    @discardableResult
    static func homeOperation(_ operation: HomeOperation, success: Bool,
                              replyCharacters: Int? = nil) -> PrivacyEvent {
        var fields: [PrivacyEvent.Field] = [
            .init(.operation, .token(PrivacyToken(operation.rawValue))),
            .init(.success, .flag(success)),
        ]
        if let replyCharacters { fields.append(.init(.characters, .count(replyCharacters))) }
        return emit(.init(.home, .homeOperation, fields))
    }

    @discardableResult
    static func homeEntityResolved(_ match: HomeEntityMatch) -> PrivacyEvent {
        return emit(.init(.home, .homeEntityResolved, [
            .init(.match, .token(PrivacyToken(match.rawValue))),
        ]))
    }

    /// The direct call failed and the natural-language fallback is being tried. The command text
    /// is the fallback's whole payload and is never logged.
    @discardableResult
    static func homeFallback(_ operation: HomeOperation) -> PrivacyEvent {
        return emit(.init(.home, .homeFallback, [
            .init(.operation, .token(PrivacyToken(operation.rawValue))),
        ]))
    }

    // MARK: - Lifecycle / inbound links

    /// Which door was knocked on. Never the URL: a callback URL carries auth codes in its query,
    /// and a universal link carries the host the wearer came from.
    enum DeepLinkRoute: String {
        case shortcutCallback, skillPack, persona, connect, capture, listen, quickAction
        case wearablesCallback, other
    }

    enum DeepLinkVerdict: String {
        case received, accepted, untrusted, malformed, sdkUnavailable, handled, failed
    }

    @discardableResult
    static func deepLink(route: DeepLinkRoute, source: PrivacyToken, verdict: DeepLinkVerdict,
                         action: PrivacyToken? = nil, error: SafeErrorSummary? = nil) -> PrivacyEvent {
        var fields: [PrivacyEvent.Field] = [
            .init(.route, .token(PrivacyToken(route.rawValue))),
            .init(.source, .token(source)),
            .init(.verdict, .token(PrivacyToken(verdict.rawValue))),
        ]
        if let action { fields.append(.init(.action, .token(action))) }
        if let error { fields.append(.init(.error, .summary(error))) }
        return emit(.init(.lifecycle, .deepLink, fields))
    }

    // MARK: - Auth

    enum AuthProvider: String { case claude, chatgpt, google }
    enum AuthOperation: String { case tokenRefresh }

    @discardableResult
    static func authFailed(_ provider: AuthProvider, _ operation: AuthOperation,
                           _ summary: SafeErrorSummary) -> PrivacyEvent {
        return emit(.init(.auth, .authFailed, [
            .init(.provider, .token(PrivacyToken(provider.rawValue))),
            .init(.operation, .token(PrivacyToken(operation.rawValue))),
            .init(.error, .summary(summary)),
        ]))
    }

    /// Which keychain access failed, and with which `OSStatus`.
    ///
    /// The key *name* is deliberately absent. It is drawn from a small fixed dictionary of
    /// provider names, so hashing it would not anonymise anything (the plan says as much), and
    /// naming it in a log would say which credentials this wearer holds. The operation plus the
    /// status is what a keychain fault is actually diagnosed from.
    enum KeychainOperation: String { case read, write }

    @discardableResult
    static func keychainFailed(_ operation: KeychainOperation, status: Int) -> PrivacyEvent {
        return emit(.init(.auth, .keychainFailed, [
            .init(.operation, .token(PrivacyToken(operation.rawValue))),
            .init(.status, .count(status)),
        ]))
    }

    /// A one-time move of stored configuration. Never what moved — only that it did.
    enum ConfigMigration: String { case providerSecrets, gatewayConfig }
    enum MigrationOutcome: String { case completed, deferred }

    @discardableResult
    static func configMigration(_ migration: ConfigMigration, _ outcome: MigrationOutcome) -> PrivacyEvent {
        return emit(.init(.auth, .configMigration, [
            .init(.migration, .token(PrivacyToken(migration.rawValue))),
            .init(.outcome, .token(PrivacyToken(outcome.rawValue))),
        ]))
    }

    // MARK: - Gateway
    //
    // Everything about the gateway link is either a state transition or an identifier. The
    // endpoint itself never appears: a LAN URL names the wearer's home network and a tunnel URL
    // names their host, and both are routinely presented alongside a bearer token. `LogRedaction`
    // used to stand in for this — it masks two token shapes and nothing else, which is why the
    // four sites that called it are migrated here rather than kept.

    /// Which leg of the link is in use. Not *which* host — only LAN versus remote.
    enum GatewayTransport: String { case lan, tunnel, unknown }

    enum GatewayConnectionEvent: String {
        case notConfigured, inactive
        case endpointResolved, endpointUnreachable, endpointCacheDropped, endpointMalformed, failover
        case connecting, connected, disconnected, reconnectScheduled
        case challengeReceived, handshakeSent, authRejected
        case sessionRotated, sessionCompacted
        case devicePaired, pairingPending
        case deviceEventSent
    }

    /// `peer` is which gateway — a private identifier, so it is fingerprinted: enough to tell two
    /// gateways apart across a failover, not enough to name either or say where it lives.
    @discardableResult
    static func gatewayConnection(_ event: GatewayConnectionEvent,
                                  transport: GatewayTransport? = nil,
                                  peer: PrivateIdentifier? = nil,
                                  count: Int? = nil,
                                  detail: PrivacyToken? = nil) -> PrivacyEvent {
        var fields: [PrivacyEvent.Field] = [.init(.event, .token(PrivacyToken(event.rawValue)))]
        if let transport { fields.append(.init(.transport, .token(PrivacyToken(transport.rawValue)))) }
        if let peer { fields.append(.init(.peer, .identifier(peer))) }
        if let count { fields.append(.init(.count, .count(count))) }
        if let detail { fields.append(.init(.detail, .token(detail))) }
        return emit(.init(.gateway, .gatewayConnection, fields))
    }

    @discardableResult
    static func gatewayReconnectScheduled(delaySeconds: Double) -> PrivacyEvent {
        return emit(.init(.gateway, .gatewayConnection, [
            .init(.event, .token(PrivacyToken(GatewayConnectionEvent.reconnectScheduled.rawValue))),
            .init(.delay, .seconds(delaySeconds)),
        ]))
    }

    /// The health probe's verdict. The probe's response body was previously logged whole; a
    /// gateway body carries session titles and agent output, so only the status survives.
    @discardableResult
    static func gatewayHealth(_ transport: GatewayTransport, reachable: Bool,
                              status: Int? = nil) -> PrivacyEvent {
        var fields: [PrivacyEvent.Field] = [
            .init(.transport, .token(PrivacyToken(transport.rawValue))),
            .init(.success, .flag(reachable)),
        ]
        if let status { fields.append(.init(.status, .count(status))) }
        return emit(.init(.gateway, .gatewayHealth, fields))
    }

    enum GatewayOutcome: String { case succeeded, rejected, unsupported, failed }

    /// A protocol call: `sessions.send`, `cron.create`, `tools.available`. The method name is a
    /// fixed vocabulary defined by the protocol, so it is public operation class. Its params and
    /// its result are the task text and the agent's answer, so neither has a parameter here —
    /// `characters` is how much came back, which is what a truncation report needs.
    @discardableResult
    static func gatewayOperation(_ method: String, outcome: GatewayOutcome,
                                 count: Int? = nil, characters: Int? = nil) -> PrivacyEvent {
        var fields: [PrivacyEvent.Field] = [
            .init(.method, .token(PrivacyToken(method))),
            .init(.outcome, .token(PrivacyToken(outcome.rawValue))),
        ]
        if let count { fields.append(.init(.count, .count(count))) }
        if let characters { fields.append(.init(.characters, .count(characters))) }
        return emit(.init(.gateway, .gatewayOperation, fields))
    }

    /// An unsolicited push from the gateway. The preview text *is* the notification — it is read
    /// aloud to the wearer — so its length is the only thing recorded.
    enum GatewayNotificationKind: String { case heartbeat, cronResult }

    @discardableResult
    static func gatewayNotification(_ kind: GatewayNotificationKind, characters: Int) -> PrivacyEvent {
        return emit(.init(.gateway, .gatewayNotification, [
            .init(.kind, .token(PrivacyToken(kind.rawValue))),
            .init(.characters, .count(characters)),
        ]))
    }

    enum GatewayPhase: String { case health, handshake, receive, send, request }

    @discardableResult
    static func gatewayFailed(_ phase: GatewayPhase, _ summary: SafeErrorSummary) -> PrivacyEvent {
        return emit(.init(.gateway, .gatewayFailed, [
            .init(.phase, .token(PrivacyToken(phase.rawValue))),
            .init(.error, .summary(summary)),
        ]))
    }

    // MARK: - MCP

    /// Server labels are user-chosen and often name an employer or a household, so they are
    /// fingerprinted. Tool names are the protocol's public vocabulary and are kept as tokens.
    @discardableResult
    static func mcpDiscovery(tools: Int, servers: Int) -> PrivacyEvent {
        return emit(.init(.mcp, .mcpDiscovery, [
            .init(.count, .count(tools)),
            .init(.servers, .count(servers)),
        ]))
    }

    /// A discovery-time trust verdict. The scanner's `reason` is free-form prose built from an
    /// attacker-authored tool description, so the verdict is kept and the reason is not.
    enum MCPToolVerdict: String { case blocked, quarantined }

    @discardableResult
    static func mcpToolScreened(_ verdict: MCPToolVerdict, tool: String,
                                server: PrivateIdentifier) -> PrivacyEvent {
        return emit(.init(.mcp, .mcpToolScreened, [
            .init(.verdict, .token(PrivacyToken(verdict.rawValue))),
            .init(.tool, .token(PrivacyToken(tool))),
            .init(.server, .identifier(server)),
        ]))
    }

    /// An outbound egress-screen decision. The pattern names that fired describe the *content*
    /// that was about to leave, so the count goes to the log and the names stay in the trust UI.
    enum MCPEgressAction: String { case allowed, redacted, blocked }

    @discardableResult
    static func mcpEgress(_ action: MCPEgressAction, tool: String, server: PrivateIdentifier,
                          hits: Int) -> PrivacyEvent {
        return emit(.init(.mcp, .mcpEgress, [
            .init(.action, .token(PrivacyToken(action.rawValue))),
            .init(.tool, .token(PrivacyToken(tool))),
            .init(.server, .identifier(server)),
            .init(.count, .count(hits)),
        ]))
    }

    enum MCPPhase: String { case discovery, transport, sessionInit }

    @discardableResult
    static func mcpFailed(_ phase: MCPPhase, server: PrivateIdentifier,
                          _ summary: SafeErrorSummary? = nil) -> PrivacyEvent {
        var fields: [PrivacyEvent.Field] = [
            .init(.phase, .token(PrivacyToken(phase.rawValue))),
            .init(.server, .identifier(server)),
        ]
        if let summary { fields.append(.init(.error, .summary(summary))) }
        return emit(.init(.mcp, .mcpFailed, fields))
    }

    /// The local server we expose on the LAN.
    enum MCPServerEvent: String {
        case listening, stopped, startFailed, requestRejected, forwardUnsupported
    }

    /// The request path is classified rather than quoted: it arrives from the network, so an
    /// unknown path is attacker-supplied text.
    enum MCPRoute: String { case seeGlasses, glassesStatus, sendToGlasses, unknown }

    @discardableResult
    static func mcpServer(_ event: MCPServerEvent, port: Int? = nil, route: MCPRoute? = nil,
                          error: SafeErrorSummary? = nil) -> PrivacyEvent {
        var fields: [PrivacyEvent.Field] = [.init(.event, .token(PrivacyToken(event.rawValue)))]
        if let port { fields.append(.init(.port, .count(port))) }
        if let route { fields.append(.init(.route, .token(PrivacyToken(route.rawValue)))) }
        if let error { fields.append(.init(.error, .summary(error))) }
        return emit(.init(.mcp, .mcpServer, fields))
    }

    // MARK: - Streams

    /// Which outbound link. A room URL is a bearer capability — anyone holding it watches the
    /// wearer's camera — so no method here accepts one.
    enum StreamChannel: String { case viewerBroadcast, expertBridge, hudMirror, signaling }

    enum StreamEvent: String {
        case started, stopped, listening, startFailed
        case viewerJoined, viewerLeft
        case expertPaged, expertBridgeUnavailable
        case negotiationFailed, sendFailed, receiveFailed
    }

    @discardableResult
    static func stream(_ channel: StreamChannel, _ event: StreamEvent,
                       detail: PrivacyToken? = nil, count: Int? = nil,
                       session: PrivateIdentifier? = nil,
                       error: SafeErrorSummary? = nil) -> PrivacyEvent {
        var fields: [PrivacyEvent.Field] = [
            .init(.channel, .token(PrivacyToken(channel.rawValue))),
            .init(.event, .token(PrivacyToken(event.rawValue))),
        ]
        if let detail { fields.append(.init(.detail, .token(detail))) }
        if let count { fields.append(.init(.count, .count(count))) }
        if let session { fields.append(.init(.session, .identifier(session))) }
        if let error { fields.append(.init(.error, .summary(error))) }
        return emit(.init(.stream, .stream, fields))
    }

    // MARK: - Network

    enum NetworkSubsystem: String { case homeAssistant, contextFetch, modelCatalog }

    @discardableResult
    static func requestFailed(_ subsystem: NetworkSubsystem, _ summary: SafeErrorSummary) -> PrivacyEvent {
        return emit(.init(.network, .requestFailed, [
            .init(.subsystem, .token(PrivacyToken(subsystem.rawValue))),
            .init(.error, .summary(summary)),
        ]))
    }
}

// MARK: - Bounded value types

/// A short word from a bounded vocabulary — an event type, a tool name, a state, an error case.
///
/// Anything outside `[A-Za-z0-9._-]`, empty, or longer than 48 characters is **dropped** rather
/// than truncated, and becomes `unnamed`. Dropping is the point: a transcript, a URL with a query,
/// a JSON argument blob, or a sentence-shaped error message all contain characters outside the
/// set, so they cannot arrive here in a shortened form either.
///
/// **Stated limit:** this is a shape filter, not a secret detector. A value that happens to be
/// short and identifier-shaped survives it. No call site may construct a token from a credential,
/// and `Scripts/check-privacy-logging.sh` flags log calls that interpolate identifiers named like
/// `token`/`key`/`cookie` precisely because the type cannot tell.
struct PrivacyToken: Equatable, CustomStringConvertible {
    static let placeholder = "unnamed"
    static let maxLength = 48

    let description: String

    init(_ raw: String) {
        let allowed = !raw.isEmpty
            && raw.count <= Self.maxLength
            && raw.allSatisfy { char in
                char.isASCII && (char.isLetter || char.isNumber || char == "_" || char == "." || char == "-")
            }
        description = allowed ? raw : Self.placeholder
    }

    /// The case name of an enum value, with any associated payload left behind.
    ///
    /// `Mirror` gives the case label for a payload case (`disallowedScheme`) without the payload.
    /// A payload-free case has no children, and there `String(describing:)` is the case name —
    /// **but only if the type has not customised it**. `URLFetchGuard.Rejection` is exactly that
    /// trap: it is `CustomStringConvertible`, and its description names the host it refused. So a
    /// customised type yields `nil` here and the caller falls back to the type name; a guess would
    /// be the leak this whole file exists to prevent. Anything that is not an enum yields `nil`
    /// too, and every result still passes through the vocabulary filter above.
    static func caseName(of value: Any) -> PrivacyToken? {
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .enum else { return nil }
        if let label = mirror.children.first?.label { return PrivacyToken(label) }
        guard mirror.children.isEmpty else { return nil }
        guard !(value is CustomStringConvertible), !(value is CustomDebugStringConvertible) else {
            return nil
        }
        return PrivacyToken(String(describing: value))
    }
}

/// A value that may appear in a log only as a one-way fingerprint: a call id, an item id, a host.
///
/// Short enough to read, long enough to correlate two records within a session, and not reversible
/// into the value. Wrapping is explicit at the call site so "this is an identifier" is a decision
/// someone made, not something a formatter guessed.
struct PrivateIdentifier: Equatable, CustomStringConvertible {
    let description: String

    init(_ raw: String) {
        description = SHA256.hash(data: Data(raw.utf8)).prefix(8)
            .map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Event shape

/// One structured record. Pure data — building one has no side effect, which is what lets the
/// encoder be tested without a log sink.
struct PrivacyEvent: Equatable {

    /// The closed set of events this app emits. A new event is a new case, reviewable as a diff.
    enum Name: String, CaseIterable {
        case toolCallReceived, toolCallRefused, toolCallAcked, toolCallCancelled, toolCallCompleted
        case realtimeSession, realtimeUtterance, realtimeMedia, realtimeSendSkipped
        case realtimeTruncated, realtimeReconnectScheduled, realtimeReconnectExhausted
        case realtimeGoAway, realtimeToolCall, realtimeToolCancellation, realtimeLatency
        case realtimeError
        case qrScanned, qrFetchBlocked, qrFetchLoaded
        case homeOperation, homeEntityResolved, homeFallback
        case deepLink
        case authFailed, keychainFailed, configMigration
        case requestFailed
        case gatewayConnection, gatewayHealth, gatewayOperation, gatewayNotification, gatewayFailed
        case mcpDiscovery, mcpToolScreened, mcpEgress, mcpFailed, mcpServer
        case stream
    }

    /// Field keys are closed too, so a reader can rely on the shape of a category's lines.
    enum Key: String {
        case tool, invocation, outcome, duration
        case provider, event, detail, direction, characters, kind, kilobytes, sequence
        case reason, state, item, attempt, ofAttempts, delay, remaining, count, phase
        case payload, bytes, host
        case operation, success, match
        case route, source, verdict, action
        case subsystem, error
        case status, migration
        case transport, peer, method
        case server, servers, port
        case channel, session
    }

    /// The only shapes a field value can take. There is no `case text(String)` — that absence is
    /// the whole design.
    enum Value: Equatable {
        case count(Int)
        case milliseconds(Int)
        case seconds(Double)
        case flag(Bool)
        case token(PrivacyToken)
        case identifier(PrivateIdentifier)
        case summary(SafeErrorSummary)
    }

    struct Field: Equatable {
        let key: Key
        let value: Value

        init(_ key: Key, _ value: Value) {
            self.key = key
            self.value = value
        }
    }

    let category: PrivacyLog.Category
    let name: Name
    let fields: [Field]

    init(_ category: PrivacyLog.Category, _ name: Name, _ fields: [Field]) {
        self.category = category
        self.name = name
        self.fields = fields
    }
}

// MARK: - Encoder

/// Turns an event into the exact line the `os.Logger` sink emits. Pure, so the privacy property
/// — that no supplied content reaches the output — is a unit test rather than a promise.
enum PrivacyEventEncoder {
    static func encode(_ event: PrivacyEvent) -> String {
        var line = "[\(event.category.rawValue)] \(event.name.rawValue)"
        for field in event.fields {
            line += " \(field.key.rawValue)=\(render(field.value))"
        }
        return line
    }

    static func render(_ value: PrivacyEvent.Value) -> String {
        switch value {
        case .count(let n): return String(n)
        case .milliseconds(let ms): return "\(ms)ms"
        case .seconds(let s): return String(format: "%.1fs", s)
        case .flag(let flag): return flag ? "true" : "false"
        case .token(let token): return token.description
        case .identifier(let identifier): return "#\(identifier.description)"
        case .summary(let summary): return summary.description
        }
    }
}
