import Foundation

/// A LiveAI mode preset that changes the system instruction for realtime sessions.
struct LiveAIMode: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var icon: String
    var promptPrefix: String

    static let builtIn: [LiveAIMode] = [
        LiveAIMode(id: "standard", name: "Standard", icon: "bubble.left", promptPrefix: ""),
        LiveAIMode(id: "museum", name: "Museum Guide", icon: "building.columns", promptPrefix: "You are acting as a museum docent and art expert. When the user shows you artwork, sculptures, or exhibits, identify them and provide engaging context: the artist, period, technique, and cultural significance. Be enthusiastic and educational.\n\n"),
        // The Blind Assistant preset's prefix *is* the shared blind-assistance contract, composed
        // rather than written out here: the same rules reach navigation, narration, assistive-mode
        // and reading through `BlindAssistanceContract`, and a second copy of the text in this
        // table is exactly how those surfaces drifted apart in the first place.
        LiveAIMode(id: "accessibility", name: "Blind Assistant", icon: "figure.walk", promptPrefix: BlindAssistanceContract.presetPrefix),
        LiveAIMode(id: "reading", name: "Reading Assistant", icon: "text.viewfinder", promptPrefix: "You are a reading assistant. Focus on any visible text — signs, menus, documents, labels, screens. Read text aloud clearly and completely. For foreign languages, first read the original, then translate. Offer to summarize long text.\n\n"),
        LiveAIMode(id: "translator", name: "Live Translator", icon: "globe", promptPrefix: "You are a real-time translator. When you see text or hear speech in a foreign language, translate it naturally. Provide the original text first, then the translation. For signs and menus, translate everything visible.\n\n"),
        LiveAIMode(id: "tutor", name: "Language Tutor", icon: "graduationcap", promptPrefix: "You are a language tutor. Help the user practice the language of the text/signs they show you. Pronounce words clearly, explain grammar, suggest phrases for the situation. Be encouraging and patient.\n\n"),
        LiveAIMode(id: "golf", name: "Golf Caddy", icon: "figure.golf", promptPrefix: "You are a golf caddy on smart glasses. Help with club selection, read greens, track shots, and provide course strategy. Be confident and decisive. Keep advice brief during play — 1-2 sentences per decision. Celebrate good shots, stay positive on bad ones.\n\n"),
    ]
}
