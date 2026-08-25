import Foundation

// The settings hub opens on what a new user needs today and offers the rest as
// discoverable capabilities (Plan DE). Everything in this file is pure data and
// pure functions: no Config reads, no UserDefaults, no views — so the invariants
// below can be asserted headlessly.
//
// Two rules the *types* enforce rather than merely document:
//
//   1. Folding is expressed as `CategoryPlacement.discover(FoldableTier)`, and
//      `FoldableTier` has no `everyday` case. "An Everyday category, folded
//      away" is not a representable state.
//   2. The assistive surface is built by `CapabilityCategory.pinnedAssistive`,
//      which takes no placement parameter at all.

/// The four intent tiers. Tiers describe *who a capability is for today* — they
/// are not complexity levels, and emphatically not price tiers: licence gating
/// (Field Assist, Medical Compliance) is untouched by any of this.
enum CapabilityTier: String, CaseIterable, Codable, Sendable {
    /// What the hub opens with. Always visible, never folded.
    case everyday
    /// Recording, streaming, and reading the room back to you.
    case creator
    /// Models, tools, the in-lens display, and the developer surface.
    case power
    /// Field, clinical, and organisation deployment.
    case proAndOrg

    var title: String {
        switch self {
        case .everyday: return "Everyday"
        case .creator: return "Create"
        case .power: return "Power"
        case .proAndOrg: return "Pro & Teams"
        }
    }
}

/// The tiers a category can be folded *into*.
///
/// `everyday` is deliberately absent. Folding means "the hub shows a Discover
/// card instead of the row", and Everyday is the surface the hub opens with, so
/// there is no such thing as a folded Everyday category. Pinning accessibility
/// to Everyday is therefore a statement the type system checks, not a rule a
/// future edit can quietly drop.
enum FoldableTier: String, CaseIterable, Codable, Sendable {
    case creator, power, proAndOrg

    var tier: CapabilityTier {
        switch self {
        case .creator: return .creator
        case .power: return .power
        case .proAndOrg: return .proAndOrg
        }
    }

    /// Order of the Discover groups in the hub — the same order a user is
    /// likely to grow through them.
    var order: Int {
        switch self {
        case .creator: return 0
        case .power: return 1
        case .proAndOrg: return 2
        }
    }

    var title: String { tier.title }
}

/// Where a category sits in the hub.
enum CategoryPlacement: Equatable, Hashable, Sendable {
    /// Rendered as a row, always, whatever the journey state says.
    case everyday
    /// Rendered as a Discover card until the user unfolds it — one tap, no gate.
    case discover(FoldableTier)

    var tier: CapabilityTier {
        switch self {
        case .everyday: return .everyday
        case .discover(let tier): return tier.tier
        }
    }

    var isFoldable: Bool {
        if case .discover = self { return true }
        return false
    }

    var foldableTier: FoldableTier? {
        if case .discover(let tier) = self { return tier }
        return nil
    }
}

/// One row of the settings hub.
struct CapabilityCategory: Identifiable, Equatable, Hashable, Sendable {
    /// Stable across releases — it is the key the unfolded set persists under.
    let id: String
    let title: String
    /// SF Symbol for the row's icon tile and the Discover card.
    let icon: String
    /// Draw the icon tile in the muted (neutral) treatment rather than the accent
    /// one — for power-user surfaces that shouldn't pull the eye down the list.
    let mutedIcon: Bool
    /// The row's supporting line.
    let subtitle: String
    /// The one-line Discover pitch. Empty for Everyday categories, which never
    /// pitch because they are never folded.
    let pitch: String
    let placement: CategoryPlacement
    /// Simple Mode (the caretaker lock, BM P10) hides the owner-configuration
    /// surface. Entirely orthogonal to the journey: a category can be unfolded
    /// and still hidden by Simple Mode, and unfolding never changes what Simple
    /// Mode hides.
    let hiddenInSimpleMode: Bool

    var tier: CapabilityTier { placement.tier }
    var isFoldable: Bool { placement.isFoldable }
}

extension CapabilityCategory {
    /// An Everyday category: always rendered.
    static func everyday(
        id: String,
        title: String,
        icon: String,
        mutedIcon: Bool = false,
        subtitle: String,
        hiddenInSimpleMode: Bool = false
    ) -> CapabilityCategory {
        CapabilityCategory(
            id: id, title: title, icon: icon, mutedIcon: mutedIcon, subtitle: subtitle,
            pitch: "", placement: .everyday, hiddenInSimpleMode: hiddenInSimpleMode
        )
    }

    /// A category the hub folds into a Discover card until the user taps it.
    static func discover(
        id: String,
        title: String,
        icon: String,
        mutedIcon: Bool = false,
        subtitle: String,
        pitch: String,
        tier: FoldableTier,
        hiddenInSimpleMode: Bool = false
    ) -> CapabilityCategory {
        CapabilityCategory(
            id: id, title: title, icon: icon, mutedIcon: mutedIcon, subtitle: subtitle,
            pitch: pitch, placement: .discover(tier), hiddenInSimpleMode: hiddenInSimpleMode
        )
    }

    /// The assistive surface.
    ///
    /// Assistive features are free forever and a blind or low-vision wearer is a
    /// first-class day-one user, not a power user. No org profile may withhold
    /// them and no journey state may hide them — so this constructor exposes no
    /// placement parameter and no Simple Mode parameter. There is nowhere else
    /// to put it.
    static func pinnedAssistive(
        id: String,
        title: String,
        icon: String,
        subtitle: String
    ) -> CapabilityCategory {
        CapabilityCategory(
            id: id, title: title, icon: icon, mutedIcon: false, subtitle: subtitle,
            pitch: "", placement: .everyday, hiddenInSimpleMode: false
        )
    }
}

/// The shipped hub layout: every category, its tier, and its pitch.
enum CapabilityCatalog {
    static let voice = "voice"
    static let appleIntegrations = "apple-integrations"
    static let accessibility = "accessibility"
    static let glasses = "glasses"
    static let lookAndFeel = "look-and-feel"
    static let diagnostics = "diagnostics"
    static let capture = "capture"
    static let display = "display"
    static let intelligence = "intelligence"
    static let tools = "tools"
    static let advanced = "advanced"
    static let connections = "connections"

    static let all: [CapabilityCategory] = [
        .everyday(
            id: voice,
            title: "Voice & Triggers",
            icon: "waveform",
            subtitle: "Wake phrase, push-to-talk, hands-free triggers"
        ),
        .everyday(
            id: appleIntegrations,
            title: "Works with your iPhone",
            icon: "iphone.gen3",
            subtitle: "Home, Calendar, Reminders, Contacts, Music, Maps, Alarms",
            hiddenInSimpleMode: true
        ),
        .pinnedAssistive(
            id: accessibility,
            title: "Accessibility",
            icon: "accessibility",
            subtitle: "Assistive narration, guidance, and reading help"
        ),
        .everyday(
            id: glasses,
            title: "Glasses & Privacy",
            icon: "lock.shield",
            subtitle: "Hardware, privacy, and medical compliance"
        ),
        .everyday(
            id: lookAndFeel,
            title: "Look & Feel",
            icon: "paintbrush",
            subtitle: "Theme, accent colour, and languages"
        ),
        // Everyday, and visible in Simple Mode, on purpose: the wearers who most need a
        // self-test and a way to report a problem are the ones who never see Advanced.
        .everyday(
            id: diagnostics,
            title: "Diagnostics & Support",
            icon: "stethoscope",
            subtitle: "Test the glasses, camera, and AI — or report a problem"
        ),
        .discover(
            id: capture,
            title: "Capture & Streaming",
            icon: "video",
            subtitle: "Recordings, meetings, and going live",
            pitch: "Record what you see, or stream it live.",
            tier: .creator,
            hiddenInSimpleMode: true
        ),
        .discover(
            id: display,
            title: "Display & HUD",
            icon: "eyeglasses",
            subtitle: "The in-lens display and everything that draws on it",
            pitch: "Put answers, captions and directions in your lens.",
            tier: .power,
            hiddenInSimpleMode: true
        ),
        .discover(
            id: intelligence,
            title: "AI & Personality",
            icon: "brain.head.profile",
            subtitle: "Models, personas, prompt, and behaviour",
            pitch: "Choose the model and give it a character.",
            tier: .power,
            hiddenInSimpleMode: true
        ),
        .discover(
            id: tools,
            title: "Tools & Actions",
            icon: "wrench.and.screwdriver",
            subtitle: "Quick actions, tools, skills, and playbooks",
            pitch: "Decide what the assistant is allowed to do.",
            tier: .power,
            hiddenInSimpleMode: true
        ),
        .discover(
            id: advanced,
            title: "Advanced",
            icon: "gearshape.2",
            mutedIcon: true,
            subtitle: "Diagnostics and power-user tools",
            pitch: "Watch the prompts and traffic behind every answer.",
            tier: .power,
            hiddenInSimpleMode: true
        ),
        .discover(
            id: connections,
            title: "Connections",
            icon: "point.3.connected.trianglepath.dotted",
            subtitle: "Services, gateways, and MCP servers",
            pitch: "Wire the assistant into the services you already run.",
            tier: .proAndOrg,
            hiddenInSimpleMode: true
        ),
    ]

    static func category(id: String) -> CapabilityCategory? {
        all.first { $0.id == id }
    }

    /// Every category that has a folded representation.
    static var foldable: [CapabilityCategory] { all.filter(\.isFoldable) }

    static var foldableIDs: Set<String> { Set(foldable.map(\.id)) }
}
