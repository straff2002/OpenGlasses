import Foundation
import CryptoKit

// MARK: - Canonical digests

/// A stable fingerprint of a tool call's arguments.
///
/// Stable is the whole point: an approval is bound to the arguments the wearer was shown, and the
/// call that later spends it must present the *same* arguments however the provider happened to
/// serialise them. Two calls that differ only in key order, in the JSON number type used for a
/// whole number, in leading/trailing space, or in a Unicode composition that renders identically
/// must agree; a call that differs in anything a person would read differently must not.
///
/// The digest carries no argument content off the device — it is a one-way hash, and it is the only
/// form in which arguments are allowed anywhere near a persisted record or a log line.
enum CanonicalArgumentDigest {

    /// 16 bytes of SHA-256 over the canonical form. Long enough that a second call cannot be made
    /// to collide with an approved one.
    static func digest(_ args: [String: Any]) -> String {
        let material = canonical(args)
        return SHA256.hash(data: Data(material.utf8)).prefix(16)
            .map { String(format: "%02x", $0) }.joined()
    }

    /// The canonical string. Exposed for tests, which need to be able to say *why* two calls agree.
    static func canonical(_ value: Any) -> String {
        switch value {
        case let dictionary as [String: Any]:
            // Objects are unordered by definition, so the canonical form imposes one.
            let body = dictionary.keys.sorted()
                .map { "\(canonicalText($0)):\(canonical(dictionary[$0] as Any))" }
                .joined(separator: ",")
            return "{\(body)}"
        case let array as [Any]:
            // Arrays are ordered by definition: reordering one changes what was approved.
            return "[\(array.map(canonical).joined(separator: ","))]"
        case let string as String:
            return "s:\(canonicalText(string))"
        case is NSNull:
            return "n"
        // NSNumber before Bool: a bridged Swift `Bool` and a JSON `true` are both NSNumber here,
        // and a dynamic cast of `NSNumber(1)` to `Bool` succeeds — so the CFBoolean check inside
        // `canonicalNumber` is what actually tells them apart.
        case let number as NSNumber:
            return canonicalNumber(number)
        case let bool as Bool:
            return "b:\(bool)"
        default:
            return "s:\(canonicalText(String(describing: value)))"
        }
    }

    /// Text normalisation: canonical composition, then trimmed, then internal whitespace runs
    /// collapsed to one space.
    ///
    /// Collapsing whitespace deliberately widens what one approval covers to the text a person
    /// would read as identical. It does not widen it across words: a body with a different word,
    /// a different recipient, or a different order is a different digest.
    static func canonicalText(_ text: String) -> String {
        let composed = text.precomposedStringWithCanonicalMapping
        let parts = composed.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        return parts.joined(separator: " ")
    }

    /// `NSNumber` loses the distinction a caller meant between `1` and `1.0`, and JSON does too, so
    /// a whole number canonicalises to its integer form whichever wire shape delivered it.
    private static func canonicalNumber(_ number: NSNumber) -> String {
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return "b:\(number.boolValue)" }
        let double = number.doubleValue
        if double.rounded() == double, abs(double) < 9.007199254740992e15 {
            return "i:\(Int64(double))"
        }
        return "d:\(double)"
    }
}

/// A fingerprint of a tool *definition* — the contract the wearer was implicitly approving when
/// they approved a call to it.
///
/// A server can change a tool's description or schema between one discovery and the next; an
/// approval obtained against the old contract must not be spendable against the new one, and a
/// server whose definitions moved after review has to be looked at again.
enum ToolDefinitionDigest {

    static func digest(name: String, description: String, schema: [String: Any]) -> String {
        let material = [
            CanonicalArgumentDigest.canonicalText(name),
            CanonicalArgumentDigest.canonicalText(description),
            CanonicalArgumentDigest.canonical(schema),
        ].joined(separator: "|")
        return SHA256.hash(data: Data(material.utf8)).prefix(16)
            .map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Binding

/// Everything one approval is *for*.
///
/// An approval that named only the tool would let a changed recipient, a changed body, a different
/// server's tool of the same name, or a later replay ride the wearer's earlier yes. Every field
/// here is one of those doors closed, and all of them are compared before a grant is spent.
struct ApprovalBinding: Sendable, Equatable, Hashable {
    /// `native`, `mcp:<server id>`, `gateway`, or `custom:<id>` — see [[ToolDispatchSeam]].
    let serverIdentity: String
    /// The resolved target, never a wrapper name.
    let toolName: String
    /// The definition the approval was obtained against.
    let definitionDigest: String
    /// The canonical digest of the final arguments.
    let argumentsDigest: String
    /// The approval session. An approval never survives the session it was given in.
    let sessionID: String

    init(serverIdentity: String, toolName: String, definitionDigest: String,
         argumentsDigest: String, sessionID: String) {
        self.serverIdentity = serverIdentity
        self.toolName = toolName
        self.definitionDigest = definitionDigest
        self.argumentsDigest = argumentsDigest
        self.sessionID = sessionID
    }

    init(seam: ToolDispatchSeam, toolName: String, definitionDigest: String,
         args: [String: Any], sessionID: String) {
        self.init(serverIdentity: seam.identity, toolName: toolName,
                  definitionDigest: definitionDigest,
                  argumentsDigest: CanonicalArgumentDigest.digest(args),
                  sessionID: sessionID)
    }
}

// MARK: - Grant

/// One person's yes to one call, valid once and briefly.
struct ApprovalGrant: Sendable, Equatable {
    /// Unguessable and single-use. What the call presents when it claims to have been approved.
    let nonce: String
    let binding: ApprovalBinding
    let issuedAt: Date
    /// How long the yes stays spendable. A confirmation the wearer answered and then walked away
    /// from is not an approval for whatever arrives ten minutes later.
    let ttl: TimeInterval

    static let defaultTTL: TimeInterval = 120

    func isExpired(at now: Date) -> Bool { now.timeIntervalSince(issuedAt) >= ttl }
}

/// Why a call could not spend a grant. Each case is a distinct thing that went wrong, because a
/// single "denied" would hide the difference between a first-ever call and an attempt to reuse
/// somebody else's yes.
enum ApprovalRefusalReason: String, Sendable, Equatable {
    /// No grant with that nonce was ever issued, or the call presented none at all.
    case noGrant
    /// The grant was already spent. A yes is worth exactly one call.
    case replayed
    /// The grant is past its time-to-live.
    case expired
    /// The call belongs to a different approval session than the grant.
    case sessionMismatch
    /// A different server (or the native seam vs. a server) than the one approved.
    case serverMismatch
    /// A different tool than the one approved.
    case toolMismatch
    /// The same tool, but its definition changed after the approval was given.
    case definitionChanged
    /// The same tool and definition, but different arguments.
    case argumentsChanged
}

enum ApprovalGrantVerdict: Sendable, Equatable {
    case consumed(ApprovalGrant)
    case refused(ApprovalRefusalReason)

    var refusal: ApprovalRefusalReason? {
        if case .refused(let reason) = self { return reason }
        return nil
    }
}

/// Issues and spends approval grants for one approval session.
///
/// Grants never leave the device and never leave this object: a call presents a nonce, and the
/// store is the only thing that knows what that nonce was for. Spending is destructive, so the
/// second presentation of a nonce is a `replayed` refusal rather than a second execution.
@MainActor
final class ApprovalGrantStore {
    /// The session every grant issued here is bound to. Rotating it invalidates every outstanding
    /// grant at once, which is what a new conversation, a re-launch, or a sign-out should do.
    private(set) var sessionID: String

    /// Live grants by nonce.
    private var live: [String: ApprovalGrant] = [:]
    /// Spent grants by nonce, so a replay can be *named* rather than merely failing to match.
    /// Bounded: this is a security ring, not a history.
    private var spent: [(nonce: String, grant: ApprovalGrant)] = []
    static let spentCapacity = 64

    init(sessionID: String = UUID().uuidString) {
        self.sessionID = sessionID
    }

    /// Abandon every outstanding grant and start a new approval session.
    func rotateSession(to newID: String = UUID().uuidString) {
        sessionID = newID
        live.removeAll()
        spent.removeAll()
    }

    /// A binding for this session — the shape a caller must present to spend a grant.
    func binding(seam: ToolDispatchSeam, toolName: String, definitionDigest: String,
                 args: [String: Any]) -> ApprovalBinding {
        ApprovalBinding(seam: seam, toolName: toolName, definitionDigest: definitionDigest,
                        args: args, sessionID: sessionID)
    }

    /// Record one person's yes to exactly this call.
    @discardableResult
    func issue(for binding: ApprovalBinding, at now: Date = Date(),
               ttl: TimeInterval = ApprovalGrant.defaultTTL) -> ApprovalGrant {
        let grant = ApprovalGrant(nonce: UUID().uuidString, binding: binding, issuedAt: now, ttl: ttl)
        live[grant.nonce] = grant
        return grant
    }

    /// Spend `nonce` against the call that is actually about to run.
    ///
    /// The comparison is field by field in a fixed order, so the refusal a caller gets names the
    /// first thing that differed rather than whichever check happened to run first.
    func redeem(nonce: String?, against binding: ApprovalBinding,
                at now: Date = Date()) -> ApprovalGrantVerdict {
        guard let nonce, let grant = live[nonce] else {
            if let nonce, spent.contains(where: { $0.nonce == nonce }) {
                return .refused(.replayed)
            }
            return .refused(.noGrant)
        }
        if grant.isExpired(at: now) {
            live[nonce] = nil
            return .refused(.expired)
        }
        let approved = grant.binding
        if approved.sessionID != binding.sessionID { return .refused(.sessionMismatch) }
        if approved.serverIdentity != binding.serverIdentity { return .refused(.serverMismatch) }
        if approved.toolName != binding.toolName { return .refused(.toolMismatch) }
        if approved.definitionDigest != binding.definitionDigest { return .refused(.definitionChanged) }
        if approved.argumentsDigest != binding.argumentsDigest { return .refused(.argumentsChanged) }

        // Single use: the grant is gone before the call it authorised has even started.
        live[nonce] = nil
        remember(spent: grant)
        return .consumed(grant)
    }

    /// Outstanding grants, for diagnostics and tests.
    var liveGrantCount: Int { live.count }

    private func remember(spent grant: ApprovalGrant) {
        spent.insert((grant.nonce, grant), at: 0)
        if spent.count > Self.spentCapacity {
            spent.removeLast(spent.count - Self.spentCapacity)
        }
    }

    // MARK: Model-facing copy

    /// What the model is told when a call could not spend a grant. Never quotes the arguments —
    /// the whole point of the refusal is that they were not the approved ones.
    static func refusalMessage(_ reason: ApprovalRefusalReason, tool: String) -> String {
        switch reason {
        case .noGrant:
            return "'\(tool)' was not approved by the user, so it did not run. Do not retry; ask the user directly."
        case .replayed:
            return "The approval for '\(tool)' had already been used, so it did not run again. Do not retry; ask the user if they want it done again."
        case .expired:
            return "The approval for '\(tool)' had expired, so it did not run. Do not retry; ask the user again."
        case .sessionMismatch:
            return "The approval for '\(tool)' belonged to an earlier session, so it did not run. Do not retry; ask the user again."
        case .serverMismatch, .toolMismatch:
            return "The user approved a different action, so '\(tool)' did not run. Do not retry; ask the user about this action specifically."
        case .definitionChanged:
            return "'\(tool)' changed since the user approved it, so it did not run. Do not retry; tell the user it needs reviewing again."
        case .argumentsChanged:
            return "The details of '\(tool)' changed after the user approved it, so it did not run. Do not retry; ask the user to approve the new details."
        }
    }
}
