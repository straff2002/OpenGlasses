import Foundation

// Where the in-lens display settings are drawn. Glasses are one interface among several, so a
// setting that only display glasses use belongs with the glasses: Devices & Privacy › Glasses, and
// only for someone who has display glasses. Before this they were drawn at the bottom of Devices &
// Privacy for everyone on a copy that offers glasses, where a wearer with new display glasses did
// not think to look and everyone else read switches that do nothing for them.
//
// A drawing rule and nothing else. `.display` is still a category of its own: its id, the
// organisation lockdown that can lock it, Simple Mode hiding it, and `AppState.openSettings(.display)`
// opening its own screen are all unchanged. Pure, so `DisplaySettingsPlacementTests` holds it headless.

enum DisplaySettingsPlacement {

    /// What says this person has display glasses. Any one is enough.
    ///
    /// The live capability (`GlassesDisplayService.hasDisplayCapability`) is true only while the
    /// glasses are connected, and the settings must stay reachable while they are off or charging,
    /// so it is never read here directly: the first time it is true is remembered
    /// (`Config.displayGlassesSeen`, through `remembersSeen(previously:hasDisplayCapability:)`).
    struct Evidence: Equatable, Sendable {
        /// Display glasses have been connected to this phone at least once.
        var displayGlassesSeen = false
        /// The in-lens display switch is on.
        var displayEnabled = false
        /// The "Your glasses have a display" offer was answered, or the display switch was moved
        /// by hand. The offer is raised only for connected display glasses, so this also covers a
        /// wearer who answered it before the seen flag existed and has not reconnected since.
        var displayOfferAnswered = false
        /// The EVEN G2 display backend is chosen: glasses that are nothing but a display.
        var evenBackendChosen = false
        /// An organisation's lockdown leaves Display & HUD open where it is locked by default: it
        /// wants its technicians to reach the display settings.
        var organisationOpensDisplay = false

        var hasDisplayGlasses: Bool {
            displayGlassesSeen || displayEnabled || displayOfferAnswered || evenBackendChosen
                || organisationOpensDisplay
        }
    }

    /// Whether Devices & Privacy › Glasses draws the link to Display & HUD.
    ///
    /// `categoryVisible` is `.display` being among the hub's visible categories
    /// (`SettingsHub.visibleCategories`): Simple Mode hides it, an organisation's lockdown can lock
    /// it, and a copy without glasses never has it. None of that is got round by moving the link.
    static func showsOnGlassesPage(categoryVisible: Bool, evidence: Evidence) -> Bool {
        categoryVisible && evidence.hasDisplayGlasses
    }

    /// Whether Devices & Privacy › Glasses offers the choice of which glasses draw the lens (the
    /// display backend). Anyone who can see the category may choose: EVEN G2 glasses are only a
    /// display, so they are recognised only once chosen, and the choice cannot wait for the evidence.
    /// It is on the Glasses page and nowhere else.
    static func showsBackendChoiceOnGlassesPage(categoryVisible: Bool) -> Bool {
        categoryVisible
    }

    /// The categories Devices & Privacy draws as sections on its own page, after its own. Display &
    /// HUD is on the hub row still (it is a category of that row, so locks and paths follow it),
    /// but its sections are drawn behind Glasses instead.
    static func sectionsOnDevicesPage(alsoShowing children: [SettingsCategoryID]) -> [SettingsCategoryID] {
        children.filter { $0 != .devices && $0 != .display }
    }

    /// The remembered flag after one reading of the live capability: set the first time display
    /// glasses are connected, and never cleared by their going away.
    static func remembersSeen(previously seen: Bool, hasDisplayCapability: Bool) -> Bool {
        seen || hasDisplayCapability
    }

    /// Whether an organisation's lockdown opens Display & HUD on purpose. The standard lockdown
    /// locks it; a lockdown that leaves it open was told to.
    static func organisationOpensDisplay(_ lockdown: ManagedLockdown?) -> Bool {
        guard let lockdown else { return false }
        return ManagedLockdown.standard.lockedCategories.contains(.display)
            && !lockdown.lockedCategories.contains(.display)
    }
}
