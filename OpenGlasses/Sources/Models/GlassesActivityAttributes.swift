import ActivityKit
import Foundation

/// ActivityKit attributes for the glasses Live Activity (Lock Screen + Dynamic Island).
struct GlassesActivityAttributes: ActivityAttributes {
    /// Static context set when the activity starts.
    var glassesName: String

    /// Dynamic state updated throughout the activity's lifecycle.
    struct ContentState: Codable, Hashable {
        var isConnected: Bool
        var isListening: Bool
        var isSpeaking: Bool
        var isProcessing: Bool
        var lastResponseSnippet: String
        var deviceName: String?
        var batteryLevel: Int?  // 0-100, nil if unknown

        /// Top 3 persona names for widget/watch quick-launch buttons.
        /// Each entry is (id, name). Empty if no personas configured.
        var personaButtons: [PersonaButton]

        /// Top 4 quick actions for widget buttons (used when no personas configured).
        var quickActionButtons: [QuickActionButton]

        struct PersonaButton: Codable, Hashable {
            var id: String
            var name: String
        }

        struct QuickActionButton: Codable, Hashable {
            var id: String
            var label: String
            var icon: String
        }
    }
}
