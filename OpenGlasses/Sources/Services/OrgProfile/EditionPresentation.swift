import Foundation

/// Plan CT 3b — what the Field Assist edition hides from the technician, as pure rules the views
/// read and the tests pin.
///
/// **Hidden is not forbidden.** These rules decide what is *drawn*; nothing here changes a setting
/// or a ceiling, and the administrator session (`AdminGate`) lifts all of them. The kept lists are
/// the inverted form on purpose: a feature added to the app later is hidden from technicians until
/// someone decides otherwise.
enum EditionPresentation {

    // MARK: - Tabs

    /// Tabs the technician does not see: the other modes, and chat with them.
    static let hiddenTabs: Set<MainTab> = [.modes, .chat]

    /// The bar as built, given the Job rule and whether the technician's view is in force.
    static func tabs(showingJob: Bool, restricted: Bool) -> [MainTab] {
        MainTab.visibleOrder(showingJob: showingJob).filter { !(restricted && hiddenTabs.contains($0)) }
    }

    /// Where a selection or a request for a tab ends up: a hidden tab falls back to Voice, the
    /// session surface, rather than to whatever happens to be next along the bar.
    static func tab(_ tab: MainTab, restricted: Bool) -> MainTab {
        restricted && hiddenTabs.contains(tab) ? .voice : tab
    }

    // MARK: - Settings

    /// The hub rows a technician keeps. Accessibility is here and also guaranteed below: it is the
    /// pinned assistive surface, which no organisation profile may withhold.
    static let keptCategoryIds: Set<String> = [
        CapabilityCatalog.accessibility,
        CapabilityCatalog.glasses,
        CapabilityCatalog.diagnostics,
    ]

    /// The hub's rows under the edition.
    static func categories(_ categories: [CapabilityCategory], restricted: Bool) -> [CapabilityCategory] {
        guard restricted else { return categories }
        return categories.filter { keptCategoryIds.contains($0.id) || $0.id == CapabilityCatalog.accessibility }
    }

    // MARK: - The Voice tab

    /// Dock tiles the technician does not see: the model picker, which is the mode switch on the
    /// session surface. The organisation chose the model.
    static func hidesDockSlot(_ slot: DockSlot, restricted: Bool) -> Bool {
        guard restricted, case .control(.model) = slot else { return false }
        return true
    }
}
