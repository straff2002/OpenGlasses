import Foundation

/// Protocol for all built-in tools that run on-device without external APIs.
/// Main-actor isolated: tools are constructed, listed, and executed by the `@MainActor`
/// NativeToolRegistry / NativeToolRouter, so their requirements run on the main actor.
@MainActor
protocol NativeTool {
    var name: String { get }
    var description: String { get }
    var parametersSchema: [String: Any] { get }
    /// What running this tool does to the world, whether it can be stopped, and whether repeating
    /// it is safe — see [[ToolExecutionSemantics]]. The router needs this to say honestly what
    /// happened when it stops waiting.
    var executionSemantics: ToolExecutionSemantics { get }
    /// What this tool sends off the device that the model wrote, if anything (Plan LT §2). A tool
    /// that declares one is screened by `NativeToolRouter` like an MCP call, and its outbound text
    /// is checked for copied private spans. `nil` — the default — sends nothing model-written.
    var egressProfile: NativeEgressProfile? { get }
    /// Whether the wearer defined this tool rather than the app shipping it: a custom tool runs a
    /// Shortcut or a link the wearer chose, so what it hands back is outside text this app never
    /// wrote. `NativeToolRegistry.isKnownNativeTool(named:)` counts such a tool as not ours, so its
    /// output is framed as untrusted data like an MCP server's. `false` — the default — for every
    /// tool the app ships.
    var isUserDefined: Bool { get }
    func execute(args: [String: Any]) async throws -> String
}

extension NativeTool {
    /// A tool that declares nothing is assumed to be the worst case on every axis. Deliberate debt
    /// rather than a resting place: `ToolEffectClassificationTests` fails on any newly registered
    /// tool that relies on this without being listed as such.
    var executionSemantics: ToolExecutionSemantics { .conservativeDefault }
    /// Sends nothing the model wrote. `NativeEgressProfileGuardTests` holds every networked tool to
    /// a profile or a written-down exemption.
    var egressProfile: NativeEgressProfile? { nil }
    var isUserDefined: Bool { false }
}
