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
// - `Config.ggufModelsEnabled`: on, as the flag-on build has it (Plan MQ P2).
// - `LocalModelRepository`: only where an installation's files live, which a GGUF run passes in
//   (`QualificationRunner.ggufDirectory`); the downloader is the app's, and not here.
// - `LocalModelPresentation.formatBytes`: the GGUF runtime's diagnostics card's wording, never
//   shown here.
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
    /// GGUF on: this app stands in for the flag-on build (a GGUF run, Plan MQ P2).
    static var ggufModelsEnabled: Bool { true }
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
        case deleted, downloadCancelled, downloaded, generationCompleted, generationFailed, generationStarted,
             historyTrimmed, imageRefused, loaded, loadFailed, promptDecoded, reasoningProduced, tempsSwept,
             tokenShape, toolCall, toolFormat, toolsFitted, unloaded, visionDemoted
    }

    /// The app's parameter order (`PrivacyLog.localModel`), so every call site compiles unchanged.
    static func localModel(_ event: LocalModelEvent, model: PrivacyToken? = nil,
                           vision: Bool? = nil, count: Int? = nil, total: Int? = nil,
                           characters: Int? = nil, tokens: Int? = nil, shape: PrivacyToken? = nil,
                           megabytes: Int? = nil, cacheMegabytes: Int? = nil,
                           footprintMegabytes: Int? = nil, headroomMegabytes: Int? = nil,
                           kilobytes: Int? = nil,
                           tool: PrivacyToken? = nil, detail: PrivacyToken? = nil,
                           milliseconds: Int? = nil, firstTokenMilliseconds: Int? = nil,
                           percent: Int? = nil, state: PrivacyToken? = nil,
                           error: SafeErrorSummary? = nil) {}

    enum Store { case jsonBlob }
    enum StoreEvent { case backedUp, backupFailed, salvaged, blobUndecodable, readFailed }

    static func store(_ store: Store, _ event: StoreEvent, slot: PrivacyToken? = nil, count: Int? = nil,
                      total: Int? = nil, bytes: Int? = nil, detail: PrivacyToken? = nil,
                      error: SafeErrorSummary? = nil) {}
}

/// Where an installation's files live; a GGUF run passes its own directory, so this is never read.
enum LocalModelRepository {
    static func defaultDirectory(for installation: InstalledLocalModel, fileManager: FileManager = .default) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(installation.descriptor.id.storageComponent, isDirectory: true)
    }
}

/// Only the byte formatting `LocalRuntimeDiagnostics` words its card with, which this app never
/// shows (the record keeps the counts); the app's presentation layer is not compiled here.
enum LocalModelPresentation {
    static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
    }
}
