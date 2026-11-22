import Foundation

// The production local runtime compiles here unchanged (project.yml lists it by path). Only the
// app-wide types it touches outside the turn are adapted, and none of them changes what a model is
// sent or how its reply is read:
//
// - `LLMService`: the type only. Its local-turn wording lives in `LLMService+LocalTurnText.swift`,
//   which is compiled here as it ships.
// - `AttemptToolLedger`: the type only. The canonical-arguments rule the loop's repeat detection
//   uses lives in `AttemptToolLedger+CanonicalArguments.swift`, compiled here as it ships.
// - `PromptInjectionPolicy`: the type only. How a tool result is framed for a model lives in
//   `PromptInjectionPolicy+ToolOutput.swift`, compiled here as it ships.
// - `PrivacyLog`, `PrivacyToken`, `SafeErrorSummary`: the app's telemetry, as the manual-library
//   benchmark adapts it. Every event is dropped here; the record this app writes is its log.
// - `TurnRecorder`: the per-turn diagnostics timeline the support report reads. This app keeps its
//   own measurements from `LocalGenerationStats` instead.
// - `Config.compactVisionTurnPrompt`: read only on a photo turn, which this app never sends.
// - `Config.assistantName`: the name the fixture's prompts were built with
//   (`Fixture/qualification-fixture.json`), so the output policy drops the same speaker label.
//
// No question, passage, tool argument or answer is logged.

final class LLMService {}

struct AttemptToolLedger {}

enum PromptInjectionPolicy {}

enum TurnTimeline {
    enum Stage { case firstToken }
}

enum TurnRecorder {
    static func mark(_ stage: TurnTimeline.Stage, at time: Date? = nil) {}
    static func markFirstToken() {}
    static func addGeneration(tokens: Int, seconds: TimeInterval) {}
}

enum Config {
    static func compactVisionTurnPrompt(from systemPrompt: String) -> String { systemPrompt }
    /// Set from the fixture at launch.
    nonisolated(unsafe) static var assistantName = "Avenkin"
}

struct PrivacyToken {
    init(_ raw: String) {}
}

struct SafeErrorSummary: CustomStringConvertible {
    /// The error's type name only, never its message (which can carry a path or a host).
    let description: String
    init(_ error: Error) { description = String(describing: type(of: error)) }
}

enum PrivacyLog {
    enum LocalModelEvent {
        case deleted, downloadCancelled, downloaded, generationCompleted, generationStarted, historyTrimmed,
             imageRefused, loaded, reasoningProduced, tempsSwept, tokenShape, toolFormat, unloaded, visionDemoted
    }

    static func localModel(_ event: LocalModelEvent, model: PrivacyToken? = nil, count: Int? = nil, total: Int? = nil,
                           tokens: Int? = nil, characters: Int? = nil, megabytes: Int? = nil,
                           cacheMegabytes: Int? = nil, footprintMegabytes: Int? = nil, headroomMegabytes: Int? = nil,
                           kilobytes: Int? = nil, vision: Bool? = nil, shape: PrivacyToken? = nil,
                           detail: PrivacyToken? = nil, error: SafeErrorSummary? = nil) {}

    enum Store { case jsonBlob }
    enum StoreEvent { case backedUp, backupFailed, salvaged, blobUndecodable, readFailed }

    static func store(_ store: Store, _ event: StoreEvent, slot: PrivacyToken? = nil, count: Int? = nil,
                      total: Int? = nil, bytes: Int? = nil, detail: PrivacyToken? = nil,
                      error: SafeErrorSummary? = nil) {}
}
