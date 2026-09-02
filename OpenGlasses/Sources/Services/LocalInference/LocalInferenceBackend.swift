import Foundation

/// The one thing every on-device runtime must be able to do (Plan DZ, "Backend protocol").
///
/// The protocol is deliberately narrow. Downloading, catalog metadata, conversation storage, tool
/// execution and published UI state are **not** here: those belong to `LocalModelRepository`,
/// `LocalModelCatalog`, `LLMService` and `LocalLLMService` respectively, and a backend that reached
/// into any of them would be a second place where local-model policy lives.
///
/// ### Output contract
/// `generate` returns a stream whose **concatenation is the authoritative assistant text** — what
/// the tool parser reads and what is stored as the reply. Incremental UI preview is a separate
/// channel (`LocalGenerationRequest.previewSink`), because the two are not the same text on every
/// runtime: the MLX reasoning path filters `<think>` out of the preview as it streams and strips it
/// from the returned text afterwards, by different code. A single-channel protocol would have
/// forced one of those two behaviours to change.
///
/// A backend may therefore yield one element (MLX, which produces its answer as a whole) or many
/// (a token-streaming runtime). Consumers must concatenate, never assume a count.
protocol LocalInferenceBackend: AnyObject, Sendable {
    var runtime: LocalModelRuntime { get }

    /// Bring a model up. Must be idempotent for an already-resident identical model.
    func load(_ installation: InstalledLocalModel,
              configuration: LocalLoadConfiguration) async throws -> LocalLoadedModel

    /// Start a generation against the resident model.
    func generate(_ request: LocalGenerationRequest) -> AsyncThrowingStream<String, Error>

    /// Stop the in-flight generation, if any, and wait until the runtime has actually stopped —
    /// not merely been asked to. The coordinator relies on this before unloading.
    func cancelGeneration() async

    /// Release the model and everything allocated with it. Must be safe to call when nothing is
    /// resident, and must have completed all accelerator work before returning.
    func unload() async

    /// What is resident right now, or nil.
    var loadedModel: LocalLoadedModel? { get async }
}
