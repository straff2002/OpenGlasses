import Foundation

/// Where one journaled operation stands.
///
/// `unknown` is the state this whole mechanism exists to keep: an operation that began and whose
/// result nobody can vouch for. It is never quietly rewritten to `failed` — not by a timeout, and
/// not by the app being killed mid-flight.
enum OperationState: String, Codable, Sendable, Equatable {
    /// Dispatched, still in flight in this process.
    case started
    /// Authoritative success.
    case completed
    /// Authoritative failure with no side effect.
    case failed
    /// Began and may still land. Only an authoritative completion or a reconciliation answer
    /// moves it out of this state.
    case unknown

    init(_ outcome: ToolExecutionOutcome) {
        switch outcome {
        case .completed: self = .completed
        // A rejection never reaches the journal (nothing is admitted until policy has allowed the
        // call), so it can only arrive here as a late relay from a composed child.
        case .rejected, .failedBeforeExecution: self = .failed
        case .outcomeUnknown: self = .unknown
        }
    }

    var isTerminal: Bool { self == .completed || self == .failed }
    /// Whether repeating the operation could duplicate an effect that already landed.
    var isUnresolved: Bool { self == .started || self == .unknown }
}

/// One row of the operation journal.
///
/// Deliberately content-free. The operation and idempotency ids are opaque, the provenance is
/// fingerprinted the way `ToolAuthorizationEvent` fingerprints it, and the tool name — from a fixed,
/// app-defined vocabulary — is the only human-readable field. No argument, result, template, or
/// message is stored, in memory-encoded form or on disk.
struct OperationRecord: Codable, Sendable, Equatable {
    let operationID: String
    let idempotencyKey: String
    let toolName: String
    let effect: ToolEffect
    let origin: ToolInvocationOrigin
    let depth: Int
    let rootFingerprint: String
    let parentFingerprint: String?
    let composerFingerprint: String?
    let startedAt: Date
    var updatedAt: Date
    var state: OperationState
    /// True when this row was carried over from a previous process that died mid-operation.
    var recoveredFromRestart: Bool = false
    /// True when the authoritative answer arrived after the caller had already been told the
    /// outcome was unknown — the turn has moved on, so this resolution belongs to operation status
    /// and diagnostics rather than to the conversation.
    var resolvedLate: Bool = false

    var isUnresolved: Bool { state.isUnresolved }
}

// `ToolEffect` and `ToolInvocationOrigin` are plain string enums; the journal is the only thing
// that needs them on disk, so their `Codable` conformance is declared here rather than widening
// the model types themselves.
extension ToolEffect: Codable {}
extension ToolInvocationOrigin: Codable {}
