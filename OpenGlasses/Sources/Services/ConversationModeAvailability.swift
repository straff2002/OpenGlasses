import Foundation

/// Which conversation modes the user can actually choose right now, and why not when they can't.
///
/// Device-traced 2026-08-23: **there was no in-app way to reach `.geminiLive` at all.** The only
/// `switchMode(to: .geminiLive)` call sites were App Intents, so the mode was reachable through
/// Siri and nowhere else — and since the Camera button only exists in a realtime mode, the whole
/// live-vision path was unreachable from the app's own UI. A mode you can only enter by voice is
/// not a mode most people will find.
///
/// Pure so the rules can be tested without a session, a key, or a pair of glasses: availability is
/// a decision about configuration, and it is the kind of decision that silently rots when it lives
/// inline in a view body.
enum ConversationModeAvailability {

    struct Option: Equatable, Identifiable {
        let mode: AppMode
        let isAvailable: Bool
        /// Why the mode cannot be chosen — shown to the user, so it names what to *do*.
        /// `nil` when available.
        let unavailableReason: String?

        var id: String { mode.rawValue }
    }

    /// What a caller must tell us about the saved configuration. Passed in rather than read from
    /// `Config`, so a test can describe a setup that does not exist on this machine.
    struct Configuration: Equatable {
        /// A saved Gemini model carrying an API key (`Config.isGeminiLiveConfigured`).
        var hasGeminiKey: Bool
        /// A saved OpenAI model whose id names a realtime variant.
        var hasOpenAIRealtimeModel: Bool
    }

    static func options(for configuration: Configuration) -> [Option] {
        AppMode.allCases.map { mode in
            switch mode {
            case .direct:
                // Always available: it is the fallback every other mode degrades to.
                return Option(mode: mode, isAvailable: true, unavailableReason: nil)
            case .geminiLive:
                return Option(
                    mode: mode,
                    isAvailable: configuration.hasGeminiKey,
                    unavailableReason: configuration.hasGeminiKey
                        ? nil
                        : "Add a Gemini model with an API key in Settings to use Gemini Live."
                )
            case .openaiRealtime:
                return Option(
                    mode: mode,
                    isAvailable: configuration.hasOpenAIRealtimeModel,
                    unavailableReason: configuration.hasOpenAIRealtimeModel
                        ? nil
                        : "Add an OpenAI model with \"realtime\" in its id to use OpenAI Realtime."
                )
            }
        }
    }

    /// Live configuration, read at the point of display.
    static var current: Configuration {
        Configuration(
            hasGeminiKey: Config.isGeminiLiveConfigured,
            hasOpenAIRealtimeModel: Config.savedModels.contains { model in
                model.llmProvider == .openai && model.model.lowercased().contains("realtime")
            }
        )
    }
}
