import CoreGraphics
import Foundation

/// The colour the app draws its own marks in on the in-lens display (Display & HUD › Highlight
/// colour). Pure.
///
/// **What it can colour, and what it can't.** Every line of lens text on the Meta Display is the
/// Display SDK's own text, and DAT 1.0.1 offers it two colours only (`TextColor.primary` and
/// `.secondary`, white and grey, set by the glasses). So this never reaches native text. It
/// reaches what the app draws itself:
/// - the marks and the position frame on a manual page (`LensPageRenderer`),
/// - the walking route's turn arrow (`HUDTurnArrow`),
/// - the Web App's text and focus ring (`WebHUDRenderer`, the Display's web surface, which can
///   take any colour).
///
/// **Standard** keeps what each drew before the setting existed: coral marks, a white arrow, and
/// white text with an amber focus ring on the Web App. Any other choice draws all three in it.
///
/// **The palette.** Black is clear on the additive lens, so a dark colour fades into the world
/// behind it; every choice is bright. No cyan or blue (house rule, and a blue reads dim on the
/// lens).
enum LensHighlightColour: String, CaseIterable, Identifiable, Sendable {
    case standard
    case coral
    case amber
    case yellow
    case green
    case white

    var id: String { rawValue }

    static let storageKey = "lensHighlightColour"

    /// The Web App's amber focus ring (`WebHUDRenderer`'s `.item:focus`).
    static let webFocusAmberHex: UInt32 = 0xFFB000

    /// The chosen colour, or nil for Standard (each surface keeps its own).
    var hex: UInt32? {
        switch self {
        case .standard: return nil
        case .coral: return AccentColors.aiAccentDarkHex
        case .amber: return Self.webFocusAmberHex
        case .yellow: return 0xFFE14D
        case .green: return 0x5BE37D
        case .white: return 0xFFFFFF
        }
    }

    /// Manual-page marks and the position frame's crop. Standard: the AI accent on a dark ground.
    var markHex: UInt32 { hex ?? AccentColors.aiAccentDarkHex }

    /// The turn arrow. Standard: white.
    var arrowHex: UInt32 { hex ?? 0xFFFFFF }

    /// The Web App's title, body lines and button labels. Standard: white.
    var webTextHex: UInt32 { hex ?? 0xFFFFFF }

    /// The Web App's focus ring: amber, unless the text is already amber or yellow, when white
    /// keeps the focused button apart from the rest.
    var webFocusHex: UInt32 {
        switch self {
        case .amber, .yellow: return 0xFFFFFF
        default: return Self.webFocusAmberHex
        }
    }

    /// Appended to a picture's `contentKey`, so a frame drawn in another colour is drawn again and
    /// sent. Empty for Standard, which keeps every existing key.
    var keySuffix: String { self == .standard ? "" : ":hl-\(rawValue)" }

    static func cgColor(_ hex: UInt32) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    /// `#RRGGBB`, for the Web App's CSS.
    static func css(_ hex: UInt32) -> String {
        String(format: "#%06X", hex & 0xFFFFFF)
    }

    /// The stored choice; Standard when nothing (or something unknown) is stored.
    static func stored(in defaults: UserDefaults = .standard) -> LensHighlightColour {
        defaults.string(forKey: storageKey).flatMap(LensHighlightColour.init(rawValue:)) ?? .standard
    }
}
