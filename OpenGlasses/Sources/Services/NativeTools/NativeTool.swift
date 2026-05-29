import Foundation

/// Protocol for all built-in tools that run on-device without external APIs.
/// Main-actor isolated: tools are constructed, listed, and executed by the `@MainActor`
/// NativeToolRegistry / NativeToolRouter, so their requirements run on the main actor.
@MainActor
protocol NativeTool {
    var name: String { get }
    var description: String { get }
    var parametersSchema: [String: Any] { get }
    func execute(args: [String: Any]) async throws -> String
}
