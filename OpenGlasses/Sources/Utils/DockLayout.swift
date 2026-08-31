import Foundation

/// The bottom dock's reorderable items (Plan CL follow-up). Every button in the
/// scrolling row is one of these; the user arranges them in Settings → Quick
/// Actions → Bar Layout. Contextual items (camera preview, the on-device model
/// chip) still only *appear* when relevant — ordering decides where they appear.
///
/// The dock carries controls only. The `quickActions` slot that used to sit here
/// moved to the home grid; a stored order still naming it salvages like any other
/// stale identifier, so no migration is needed.
enum DockItem: String, CaseIterable, Identifiable {
    case model
    case camera
    case preview
    case type
    case micMode
    case assistive
    case disconnect

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .model: return "Model Picker"
        case .camera: return "Camera"
        case .preview: return "Preview"
        case .type: return "Type"
        case .micMode: return "Wake Word / Push-Talk"
        case .assistive: return "Assistive Mode"
        case .disconnect: return "Disconnect"
        }
    }

    var icon: String {
        switch self {
        case .model: return "brain"
        case .camera: return "camera"
        case .preview: return "eye"
        case .type: return "keyboard"
        case .micMode: return "hand.tap.fill"
        case .assistive: return "figure.walk"
        case .disconnect: return "moon.fill"
        }
    }
}

/// Pure order arithmetic for the dock, so the merge rules are testable:
/// the stored order wins, stale identifiers vanish, duplicates collapse to
/// their first appearance, and items this build knows about that the stored
/// order doesn't (new features, fresh installs) append in canonical order.
enum DockLayout {
    /// The order the bar shipped with before it became arrangeable.
    static let canonical: [DockItem] = [
        .model, .camera, .preview, .type, .micMode, .assistive, .disconnect,
    ]

    static func effectiveOrder(stored: [String]) -> [DockItem] {
        var seen = Set<DockItem>()
        var result: [DockItem] = []
        for raw in stored {
            guard let item = DockItem(rawValue: raw), !seen.contains(item) else { continue }
            seen.insert(item)
            result.append(item)
        }
        for item in canonical where !seen.contains(item) {
            result.append(item)
        }
        return result
    }

    /// Round-trip helpers for the `@AppStorage` string both views observe.
    static func encode(_ order: [DockItem]) -> String {
        order.map(\.rawValue).joined(separator: ",")
    }

    static func decode(_ encoded: String) -> [DockItem] {
        effectiveOrder(stored: encoded.split(separator: ",").map(String.init))
    }

    /// The asset a provider's own mark would be bundled under. The tile prefers it when the asset
    /// catalog carries one and falls back to `modelTileGlyph` when it does not — so a brand mark is
    /// a drop-in asset rather than a code change, and no mark is ever drawn from an approximation
    /// of somebody's trademark.
    static func providerMarkAsset(for provider: LLMProvider) -> String {
        "ProviderMark-\(provider.rawValue)"
    }

    /// Glyph for the model-picker tile, keyed to the active model's provider. The tile used to
    /// carry the model's name, which made it the widest thing in the row; the provider identity
    /// survives as the symbol and the full name stays in the accessibility label.
    ///
    /// Deliberately exhaustive: a new provider should have to answer this question rather than
    /// inherit a generic brain from a `default` clause.
    static func modelTileGlyph(for provider: LLMProvider) -> String {
        switch provider {
        case .anthropic: return "sparkle"
        case .openai, .chatgpt: return "text.bubble"
        case .gemini, .geminiVertex: return "rhombus"
        case .groq: return "bolt"
        case .zai: return "circle.hexagongrid"
        case .qwen: return "cloud"
        case .minimax: return "triangle"
        case .xai: return "xmark.circle"
        case .local: return "cpu"
        case .appleOnDevice: return "apple.logo"
        case .openrouter: return "arrow.triangle.branch"
        case .custom: return "server.rack"
        }
    }
}
