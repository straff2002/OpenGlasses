import Foundation

/// How the digest is delivered when pulled up.
enum DigestDelivery: String, Codable, CaseIterable {
    case visual    // HUD glance only
    case spoken    // TTS only (audio-only glasses)
    case both

    var displayName: String {
        switch self {
        case .visual: return "Glance"
        case .spoken: return "Spoken"
        case .both: return "Both"
        }
    }
}

/// Plan BZ — digest settings.
extension Config {

    /// Master toggle (default on — inert until a source produces an item).
    static var digestEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "digestEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "digestEnabled") }
    }

    /// Top-N line budget for the glance (3 fits the panel; a hardware read may retune).
    static var digestMaxItems: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: "digestMaxItems")
            return stored == 0 ? DigestComposer.defaultTopN : max(1, min(stored, 6))
        }
        set { UserDefaults.standard.set(newValue, forKey: "digestMaxItems") }
    }

    static var digestDelivery: DigestDelivery {
        get {
            UserDefaults.standard.string(forKey: "digestDelivery")
                .flatMap(DigestDelivery.init(rawValue:)) ?? .both
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "digestDelivery") }
    }

    /// Flash the digest once on glasses (re)connect when an urgent item is pending.
    static var digestAutoSurfaceOnConnect: Bool {
        get { UserDefaults.standard.object(forKey: "digestAutoSurfaceOnConnect") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "digestAutoSurfaceOnConnect") }
    }
}
