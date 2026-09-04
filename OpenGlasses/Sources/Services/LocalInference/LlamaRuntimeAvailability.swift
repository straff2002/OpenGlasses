import Foundation
import LlamaCppWrapper

/// What the app can say about the vendored llama.cpp engine before anything is loaded through it
/// (Plan DZ P1). This is the whole of the app's contact with the engine at this stage: the GGUF
/// backend that actually loads and generates arrives with the next slice.
///
/// It exists for two reasons, and neither is decoration:
///
/// 1. **It is the compile-only smoke test with a home.** Importing `LlamaCppWrapper` from the app
///    target is what proves the vendored package links in Debug and Release, for simulator and
///    device. A smoke test that lives only in the test bundle would not prove the app links it.
/// 2. **It is where the revision comes from.** The diagnostics card in the model manager has to
///    report the engine revision, and the only trustworthy source is the binary itself — a
///    constant typed into Swift would keep claiming the pinned revision after someone rebuilt the
///    framework from a different one.
///
/// Linking the engine is not enabling it. Every member here is inert until
/// `Config.ggufModelsEnabled` is on, and `isEnabled` is the single place that reads the flag.
/// With the flag off — its shipping default — nothing in this type initializes the runtime, and
/// the MLX path never comes near it.
enum LlamaRuntimeAvailability {

    /// Whether GGUF models are switched on for this install. Off by default; see
    /// `Config.ggufModelsEnabled`.
    static var isEnabled: Bool { Config.ggufModelsEnabled }

    /// The llama.cpp commit this binary's engine was built from, as reported by the engine
    /// itself. `nil` when the framework was built without the pin stamped in — an unknown
    /// revision is reported as unknown rather than guessed at.
    static var engineRevision: String? {
        normalized(String(cString: og_llama_engine_revision()))
    }

    /// The release tag that revision belongs to, e.g. `v0.3.0`.
    static var engineTag: String? {
        normalized(String(cString: og_llama_engine_tag()))
    }

    /// True when the engine binary carries a GPU-offload backend. It does **not** mean Metal
    /// execution has been shown to work on this device: the simulator answers true here and still
    /// runs on the CPU, and device execution is only proven by running a model on one.
    static var supportsGPUOffload: Bool { og_llama_metal_compiled_in() }

    /// A one-line description for the diagnostics card, e.g. `llama.cpp v0.3.0 (c1d0e7a00401)`.
    /// Not localized on purpose: it is a build identifier, and translating it would make two
    /// people's bug reports disagree about the same binary.
    static var engineDescription: String {
        guard let revision = engineRevision else { return "llama.cpp (revision unknown)" }
        let short = String(revision.prefix(12))
        guard let tag = engineTag else { return "llama.cpp (\(short))" }
        return "llama.cpp \(tag) (\(short))"
    }

    private static func normalized(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.isEmpty || trimmed == "unknown") ? nil : trimmed
    }
}
