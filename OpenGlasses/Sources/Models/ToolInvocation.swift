import Foundation

// MARK: - Arguments

/// One tool argument, restricted to the JSON shapes a tool call can actually carry.
///
/// The point is `Sendable` by construction. A composed call is built by one object (a skill-pack
/// wrapper), authorized by another (the router), and executed inside a task the router spawns for
/// the timeout race — `[String: Any]` cannot cross those boundaries safely, and annotating it
/// `@unchecked` would only hide that.
enum ToolArgumentValue: Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    indirect case array([ToolArgumentValue])
    indirect case object([String: ToolArgumentValue])

    /// Classify an arbitrary argument value.
    ///
    /// `NSNumber` is matched before `Bool`/`Int`/`Double` because a bridged Swift `Bool` *is* an
    /// `NSNumber` and `as? Int` would happily claim it; the CoreFoundation type id is the only
    /// reliable discriminator. Anything outside the JSON shapes (no provider or internal caller
    /// produces one today) degrades to its string form rather than vanishing.
    init(_ value: Any) {
        switch value {
        case let existing as ToolArgumentValue:
            self = existing
        case let string as String:
            self = .string(string)
        case is NSNull:
            self = .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if let type = String(cString: number.objCType).first, type == "d" || type == "f" {
                self = .double(number.doubleValue)
            } else {
                self = .int(number.intValue)
            }
        case let array as [Any]:
            self = .array(array.map(ToolArgumentValue.init))
        case let object as [String: Any]:
            self = .object(object.mapValues(ToolArgumentValue.init))
        default:
            self = .string(String(describing: value))
        }
    }

    /// The value a `NativeTool` sees in its `args` dictionary.
    ///
    /// Numbers and booleans come back as `NSNumber` so that a tool's `as? Int` / `as? Double` /
    /// `as? Bool` type-checks behave exactly as they do for provider-parsed JSON, which is already
    /// `NSNumber`-backed. A call assembled from Swift literals therefore becomes *more* permissive,
    /// never less.
    var anyValue: Any {
        switch self {
        case .string(let value): return value
        case .int(let value): return NSNumber(value: value)
        case .double(let value): return NSNumber(value: value)
        case .bool(let value): return NSNumber(value: value)
        case .null: return NSNull()
        case .array(let values): return values.map(\.anyValue)
        case .object(let values): return values.mapValues(\.anyValue)
        }
    }
}

/// A tool call's arguments — a `Sendable` dictionary with lossless conversion to and from the
/// `[String: Any]` shape the `NativeTool` protocol and the provider wires speak.
struct ToolArguments: Sendable, Equatable, ExpressibleByDictionaryLiteral {
    private(set) var values: [String: ToolArgumentValue]

    init(_ raw: [String: Any] = [:]) {
        values = raw.mapValues(ToolArgumentValue.init)
    }

    init(values: [String: ToolArgumentValue]) {
        self.values = values
    }

    init(dictionaryLiteral elements: (String, Any)...) {
        values = Dictionary(uniqueKeysWithValues: elements.map { ($0.0, ToolArgumentValue($0.1)) })
    }

    var rawValues: [String: Any] { values.mapValues(\.anyValue) }
    var isEmpty: Bool { values.isEmpty }

    subscript(key: String) -> ToolArgumentValue? { values[key] }

    mutating func set(_ key: String, to value: Any) {
        values[key] = ToolArgumentValue(value)
    }
}

// MARK: - Provenance

/// Where a tool call entered the app. Provenance is additive: a child call keeps its caller's
/// identity in `ToolInvocationContext.parent` rather than replacing it.
enum ToolInvocationOrigin: String, Sendable, Equatable {
    /// An LLM tool call inside a turn (direct mode, a live session, or an agent plan step).
    case model
    /// A person acting through the app — a tapped control or a deterministically classified
    /// utterance that skips the model.
    case user
    /// Composed by an installed skill pack's `.tool` binding.
    case skillPack
    /// Composed by a user-authored Siri Action's `.tool` binding.
    case siriAction
    /// App-initiated plumbing (context pre-fetch, remote-invoke plumbing) with no composition.
    case appInternal = "internal"

    /// User-authored composition: a binding a person saved once and a machine replays later. These
    /// are the origins the composition floor governs — the person isn't present to be asked.
    var isComposition: Bool {
        self == .skillPack || self == .siriAction
    }
}

/// The call that composed a child call.
struct ToolCallParent: Sendable, Equatable {
    let invocationID: String
    let toolName: String
    /// The composition that bound the child — a skill-pack id, or a Siri Action id. Nil when the
    /// parent composed the child itself with no third-party template involved.
    let composerID: String?
}

/// Everything the authorization authority needs to know about *how* a call was reached.
struct ToolInvocationContext: Sendable, Equatable {
    /// A composition deeper than this is refused. Nothing legitimate today goes past one level;
    /// the ceiling exists so aliases and procedures can't grow an unbounded chain later.
    static let maxDepth = 4

    let invocationID: String
    let rootInvocationID: String
    let origin: ToolInvocationOrigin
    let parent: ToolCallParent?
    let depth: Int
    /// Tool names from the root down to and including the parent. Cycle detection needs the whole
    /// chain and `parent` only reaches one level up.
    let ancestry: [String]

    static func root(origin: ToolInvocationOrigin,
                     invocationID: String = UUID().uuidString) -> ToolInvocationContext {
        ToolInvocationContext(invocationID: invocationID, rootInvocationID: invocationID,
                              origin: origin, parent: nil, depth: 0, ancestry: [])
    }

    /// True when dispatching `target` would re-enter a call already on the stack.
    func wouldCycle(_ target: String) -> Bool {
        ancestry.contains(target)
    }
}

/// A tool call resolved to its real target and final arguments — what the authority decides on and
/// what actually executes. There is no shape in which a wrapper name or a pre-substitution template
/// reaches a safety check.
struct ResolvedToolCall: Sendable {
    let name: String
    let arguments: ToolArguments
    let context: ToolInvocationContext

    static func root(name: String, arguments: ToolArguments = ToolArguments(),
                     origin: ToolInvocationOrigin,
                     invocationID: String = UUID().uuidString) -> ResolvedToolCall {
        ResolvedToolCall(name: name, arguments: arguments,
                         context: .root(origin: origin, invocationID: invocationID))
    }

    /// A call this one composes. The child keeps the root invocation id, names this call as its
    /// parent, and carries the composing pack/action id — no layer may drop what came before it.
    func child(name: String, arguments: ToolArguments, composerID: String?,
               origin: ToolInvocationOrigin = .skillPack,
               invocationID: String = UUID().uuidString) -> ResolvedToolCall {
        ResolvedToolCall(
            name: name,
            arguments: arguments,
            context: ToolInvocationContext(
                invocationID: invocationID,
                rootInvocationID: context.rootInvocationID,
                origin: origin,
                parent: ToolCallParent(invocationID: context.invocationID, toolName: self.name,
                                       composerID: composerID),
                depth: context.depth + 1,
                ancestry: context.ancestry + [self.name]))
    }
}

/// The call currently executing, so a tool that composes another one can name its own invocation as
/// the parent. A task-local rather than a parameter because `NativeTool.execute(args:)` is the
/// registry-wide signature and only the composing wrappers need this.
enum ToolInvocationScope {
    @TaskLocal static var current: ResolvedToolCall?
}
