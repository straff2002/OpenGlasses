import Foundation

/// The bottom dock's reorderable items (Plan CL follow-up). Every button in the
/// scrolling row is one of these; the user arranges them in Settings → Quick
/// Actions → Bar Layout. Contextual items (camera preview, the on-device model
/// chip) still only *appear* when relevant — ordering decides where they appear.
enum DockItem: String, CaseIterable, Identifiable {
    case model
    case quickActions
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
        case .quickActions: return "Quick Actions"
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
        case .quickActions: return "square.grid.2x2"
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
        .model, .quickActions, .camera, .preview, .type, .micMode, .assistive, .disconnect,
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
}
