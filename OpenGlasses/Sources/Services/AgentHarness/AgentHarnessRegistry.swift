import Foundation

/// Holds the agent harnesses the app knows about and resolves which one is *active* (Plan N).
/// Mirrors how the LLM layer lists configured providers: only configured harnesses are offered, and
/// the user's chosen default wins when it's usable, else the first configured one is the fallback.
@MainActor
final class AgentHarnessRegistry {
    private(set) var harnesses: [AgentHarness]

    init(_ harnesses: [AgentHarness]) {
        self.harnesses = harnesses
    }

    /// Harnesses with credentials/endpoint present.
    var configured: [AgentHarness] { harnesses.filter { $0.isConfigured } }

    func harness(for kind: AgentHarnessKind) -> AgentHarness? {
        harnesses.first { $0.kind == kind }
    }

    /// The harness to dispatch to: the user's configured default, else the first configured one,
    /// else `nil` (nothing set up). `defaultKind` is injected so the resolution is testable without
    /// touching `Config`.
    func active(defaultKind: AgentHarnessKind) -> AgentHarness? {
        if let preferred = harness(for: defaultKind), preferred.isConfigured {
            return preferred
        }
        return configured.first
    }

    /// Convenience resolving the default from `Config`.
    var active: AgentHarness? { active(defaultKind: Config.defaultAgentHarness) }
}
