import Foundation

// MARK: - Dispatch seam

/// Which side of the app a resolved call is about to be dispatched on.
///
/// The seam is not cosmetic: a native tool's behaviour is written in this repository and reviewed
/// here, while an MCP server's, a gateway's, or a user-authored HTTP tool's is authored elsewhere
/// and can change between one launch and the next. The authorization floor treats those two
/// populations differently, and the seam is also half of what an approval is bound to — an approval
/// for one server must not be spendable on another.
enum ToolDispatchSeam: Sendable, Equatable {
    /// A tool registered in `NativeToolRegistry` whose implementation ships in the app.
    case native
    /// A tool discovered on a configured MCP server, identified by that server's id.
    case mcpServer(id: String)
    /// The OpenClaw gateway's `execute` pseudo-tool.
    case gateway
    /// A user-authored HTTP tool (`CustomToolWrapper`), identified by its own id.
    case custom(id: String)

    /// The stable identity an approval binds to. Namespaced so an id from one seam can never
    /// collide with an id from another.
    var identity: String {
        switch self {
        case .native:              return "native"
        case .mcpServer(let id):   return "mcp:\(id)"
        case .gateway:             return "gateway"
        case .custom(let id):      return "custom:\(id)"
        }
    }

    /// Whether the tool's behaviour is authored outside this repository.
    var isExternal: Bool {
        if case .native = self { return false }
        return true
    }
}

// MARK: - Effect class

/// What a tool call does that a person would want to have been asked about.
///
/// This is the *authorization* axis, and it is deliberately not the same axis as
/// [[ToolExecutionSemantics]]'s `effect`, which exists to decide what a lost race against the
/// timeout means. That one puts the torch and a door lock in the same bucket because both leave
/// something behind; this one has to tell them apart, because only one of them is worth stopping a
/// turn to ask about.
///
/// Ordered from least to most consequential so an unreviewed definition can be given the worst case
/// without naming a specific harm.
enum ToolEffectClass: String, Sendable, Equatable, CaseIterable, Codable, Comparable {
    /// Reads only. Nothing is written, sent, actuated or disclosed.
    case readOnly
    /// Writes state the wearer owns and can see — a note, a timer, a saved location, the torch,
    /// a recording on this device.
    case write
    /// Sends a communication to another person or another person's system.
    case messaging
    /// Actuates something in the physical world that the wearer cannot trivially undo — a lock,
    /// a door, an alarm system.
    case physicalActuation
    /// Discloses data about the wearer or a third party to a recipient outside the device.
    case sensitiveDisclosure
    /// Moves money or creates a financial obligation. No native tool is in this class today; it
    /// exists so one cannot be added without a row.
    case financial
    /// The definition did not establish what running it does. Held to the strictest rule any class
    /// carries — the default-deny position for anything unreviewed.
    case unknown

    private var rank: Int {
        switch self {
        case .readOnly:            return 0
        case .write:               return 1
        case .messaging:           return 2
        case .physicalActuation:   return 3
        case .sensitiveDisclosure: return 4
        case .financial:           return 5
        case .unknown:             return 6
        }
    }

    static func < (lhs: ToolEffectClass, rhs: ToolEffectClass) -> Bool { lhs.rank < rhs.rank }

    /// What an unreviewed definition is treated as.
    static let mostRestrictive: ToolEffectClass = .unknown

    /// Whether a call of this class needs a person to have authorized *this* call. Everything above
    /// a read does; the seam decides how that authorization is obtained (see
    /// ``requiresBoundApproval(on:)``).
    var requiresExplicitAuthorization: Bool { self != .readOnly }

    /// Whether a call of this class, arriving on this seam, may only run against a live approval
    /// grant bound to it.
    ///
    /// Two populations, one rule each:
    ///
    /// * **External seams** — an MCP server, the gateway, a user-authored HTTP tool. Their effects
    ///   are not reviewed here and can change between launches, so anything above a read is held.
    ///   Nothing on an external seam is ever classified `readOnly` from server-authored data (see
    ///   ``ToolEffectClassifier/externalClass(name:description:annotations:)``), so in practice
    ///   every external call above a read is bound.
    /// * **Native** — the implementation is in this repository and the wearer's own surfaces drive
    ///   it, so a `write` to the wearer's own device or stores is authorized by their asking for it.
    ///   The classes that reach another person, the physical world, sensitive data, or money are
    ///   not: those are bound whatever the arrival path and whatever agent mode says.
    func requiresBoundApproval(on seam: ToolDispatchSeam) -> Bool {
        switch self {
        case .readOnly:
            return false
        case .write:
            return seam.isExternal
        case .messaging, .physicalActuation, .sensitiveDisclosure, .financial, .unknown:
            return true
        }
    }
}

// MARK: - Classification

/// Assigns an effect class to a resolved call, on either seam.
///
/// Native classification is a table plus two argument-aware rows; external classification is
/// deliberately unable to reach `readOnly`, because everything it could read that from was written
/// by the server being classified.
enum ToolEffectClassifier {

    // MARK: Native

    /// Tools that put a communication in front of another person, or send one outright.
    ///
    /// Several of these hand off to a system compose sheet, so the wearer taps send themselves.
    /// That tap is a good last line but a poor first one: by the time it is shown, an injected
    /// instruction has already chosen the recipient and written the body. The bound approval is
    /// raised before any of that reaches the compose sheet.
    static let messagingTools: Set<String> = [
        "send_message", "send_via", "phone_call", "asian_messaging", "chinese_app",
        "escalate_to_expert", "deliver_report", "parts_request",
    ]

    /// Tools whose whole purpose is to put data about a person somewhere outside the device.
    static let sensitiveDisclosureTools: Set<String> = ["medical_export"]

    /// Tools that move money. Empty today, and the exhaustiveness test keeps it honest.
    static let financialTools: Set<String> = []

    /// Tools whose effect is whatever a third party or a user-authored script decided it is. Not a
    /// judgement about how dangerous they are — a statement that this app cannot say.
    static let arbitraryCapabilityTools: Set<String> = ["run_shortcut", "execute"]

    /// The class of one native call.
    ///
    /// Argument-aware where the tool genuinely is: `smart_home turn the lamp on` and
    /// `code_agent status` are not the same action as `smart_home unlock` and `code_agent start`,
    /// and classifying them together would put a prompt in front of routine calls — which trains a
    /// wearer to approve reflexively and weakens the prompt that matters.
    static func nativeClass(name: String, args: [String: Any],
                            semantics: ToolExecutionSemantics) -> ToolEffectClass {
        if arbitraryCapabilityTools.contains(name) { return .unknown }
        if financialTools.contains(name) { return .financial }
        if sensitiveDisclosureTools.contains(name) { return .sensitiveDisclosure }
        if messagingTools.contains(name) { return .messaging }

        // A run of a coding agent is an arbitrary task on someone else's machine; its other actions
        // read or narrow what is already running.
        if name == "code_agent" {
            return PromptInjectionPolicy.isDispatchingAgentRun(args) ? .unknown : .write
        }

        // The security-relevant half of the actuation tools, decided by the same floor the router
        // has always consulted rather than by a second hand-kept list.
        if HighImpactToolPolicy.mayRequireConfirmation(tool: name),
           case .requiresConfirmation = HighImpactToolPolicy.evaluate(tool: name, args: args) {
            return .physicalActuation
        }

        return semantics.effect == .readOnly ? .readOnly : .write
    }

    // MARK: External

    /// Words in a tool's own name or description that can only *raise* its class.
    private static let raisingHints: [(ToolEffectClass, [String])] = [
        (.financial, ["payment", "invoice", "charge", "refund", "transfer", "purchase", "checkout",
                      "billing", "wallet", "wire "]),
        (.sensitiveDisclosure, ["patient", "medical", "diagnosis", "prescription", "credential",
                                "secret", "password", "export", "upload", "share with"]),
        (.physicalActuation, ["unlock", "door", "garage", "alarm", "disarm", "actuate", "thermostat",
                              "valve", "relay", "vehicle"]),
        (.messaging, ["send", "email", "message", "sms", "notify", "post ", "publish", "tweet",
                      "slack", "channel"]),
    ]

    /// The class of a tool defined by something outside this repository.
    ///
    /// **`readOnly` is not reachable here, by design.** Every input to this function — the name, the
    /// description, the annotations — is authored by the party being classified, so a hostile server
    /// could assert `readOnlyHint: true` and buy itself an unbound call. A definition that says
    /// nothing recognisable is `unknown`, which is the strictest class; a definition that describes
    /// something worse is raised to that. The hints can only move the class up.
    static func externalClass(name: String, description: String,
                              annotations: [String: Any] = [:]) -> ToolEffectClass {
        // `destructiveHint` is the one annotation worth reading: a server volunteering that its
        // tool is destructive is telling the truth against its own interest. A *missing* or false
        // hint proves nothing, so it never lowers anything.
        let declaredDestructive = (annotations["destructiveHint"] as? Bool) == true
        var result: ToolEffectClass = declaredDestructive ? .physicalActuation : .mostRestrictive

        let haystack = (name + " " + description).lowercased()
        for (candidate, words) in raisingHints where words.contains(where: haystack.contains) {
            result = max(result, candidate)
        }
        return result
    }

    // MARK: Copy

    /// The line shown when a call is held for a bound approval. Reuses the action summary the
    /// confirmation surface already speaks, so a wearer sees one voice, not two.
    static func approvalSummary(tool: String, args: [String: Any],
                                effectClass: ToolEffectClass, seam: ToolDispatchSeam) -> String {
        let base = PromptInjectionPolicy.actionSummary(toolName: tool, args: args)
        guard seam.isExternal else { return base }
        return base + " — using an external tool this app hasn't reviewed"
    }
}
