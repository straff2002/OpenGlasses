import Foundation

/// What does the thinking while the conversation is on the phone (Plan GE P0).
///
/// On-device MLX runs on the GPU through Metal, and iOS forbids GPU work in the background — a
/// command buffer submitted there is an uncatchable process kill. So the phone in a pocket needs a
/// different answer from the phone in a hand. This picks, first available wins:
///
/// **Foreground:** the user's on-device model (MLX, or a GGUF model through llama.cpp), then Apple's
/// on-device model.
///
/// **Background** (the phone locked in a pocket — the common case):
/// 1. Apple's on-device model, *only if verified* to serve a backgrounded app. Unverified on device,
///    so off.
/// 2. A GGUF model through llama.cpp on the CPU only (no GPU layers). CPU work is allowed while the
///    audio background mode keeps the app alive; the risk is the background CPU budget and heat.
///    Unverified on device, so off — and the local inference coordinator still refuses every
///    background load, which is the invariant that keeps Metal out of the background. Turning this
///    rung on needs a CPU-only load path through that guard *and* device numbers.
/// 3. Nothing: requests a native tool can serve without a model go through the deterministic router;
///    anything else is held until the connection is back.
///
/// Never MLX in the background, whatever the inputs say.
enum OfflineBrainSelector {

    enum Brain: Equatable {
        /// The saved on-device model configuration (MLX or GGUF), foreground only.
        case localModel(configId: String)
        /// Apple's on-device model, through its saved configuration.
        case appleOnDevice(configId: String)
        /// A GGUF model on the CPU only, while backgrounded.
        case cpuLocalModel(configId: String)
        /// No model can think on the phone right now: deterministic router, then hold.
        case none

        var configId: String? {
            switch self {
            case .localModel(let id), .appleOnDevice(let id), .cpuLocalModel(let id): return id
            case .none: return nil
            }
        }
    }

    /// What is on this phone, as values.
    struct Available: Equatable {
        /// A saved `.local` configuration whose weights are on disk.
        var localModelConfigId: String?
        /// That model runs through llama.cpp (GGUF) rather than MLX.
        var localModelIsGGUF = false
        /// A saved Apple on-device configuration, on a device where the system model is available.
        var appleOnDeviceConfigId: String?
        /// Apple's on-device model has been measured to serve a backgrounded app.
        var appleOnDeviceServesBackground = false
        /// The llama.cpp CPU-only rung is allowed.
        var cpuTierAllowed = false

        init(localModelConfigId: String? = nil, localModelIsGGUF: Bool = false,
             appleOnDeviceConfigId: String? = nil, appleOnDeviceServesBackground: Bool = false,
             cpuTierAllowed: Bool = false) {
            self.localModelConfigId = localModelConfigId
            self.localModelIsGGUF = localModelIsGGUF
            self.appleOnDeviceConfigId = appleOnDeviceConfigId
            self.appleOnDeviceServesBackground = appleOnDeviceServesBackground
            self.cpuTierAllowed = cpuTierAllowed
        }

        /// Whether anything on the phone could think in the foreground — what the setting needs.
        var hasAnyModel: Bool { localModelConfigId != nil || appleOnDeviceConfigId != nil }
    }

    /// Device-verified facts, held here so turning a rung on is one deliberate edit with a device
    /// run behind it. Both are unmeasured today (Plan GE P3 device checks).
    static let appleOnDeviceVerifiedInBackground = false
    static let cpuTierVerifiedOnDevice = false

    static func select(appActive: Bool, available: Available) -> Brain {
        if appActive {
            if let id = available.localModelConfigId { return .localModel(configId: id) }
            if let id = available.appleOnDeviceConfigId { return .appleOnDevice(configId: id) }
            return .none
        }
        if available.appleOnDeviceServesBackground, let id = available.appleOnDeviceConfigId {
            return .appleOnDevice(configId: id)
        }
        if available.cpuTierAllowed, available.localModelIsGGUF, let id = available.localModelConfigId {
            return .cpuLocalModel(configId: id)
        }
        return .none
    }
}
