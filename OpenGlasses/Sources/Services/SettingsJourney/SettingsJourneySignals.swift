import Foundation

/// The `Config`-reading half of the journey migration (Plan DE P1).
///
/// Kept apart from `SettingsJourneyMigration` on purpose: the *decision* is pure
/// and headlessly tested; this is only the measurement. Each predicate answers
/// one question — "has the user configured anything in this category?" — and
/// errs towards yes, because the cost of a false yes is a category shown to
/// someone who didn't need it, while the cost of a false no is a setting that
/// vanishes on update.
enum SettingsJourneySignals {
    static func detect() -> SettingsJourneyMigration.Signals {
        SettingsJourneyMigration.Signals(
            hasPriorInstall: Config.isPastOnboarding,
            configuredCategoryIDs: configuredCategoryIDs()
        )
    }

    static func configuredCategoryIDs() -> Set<String> {
        var ids: Set<String> = []
        if hasCaptureConfiguration { ids.insert(CapabilityCatalog.capture) }
        if hasDisplayConfiguration { ids.insert(CapabilityCatalog.display) }
        if hasIntelligenceConfiguration { ids.insert(CapabilityCatalog.intelligence) }
        if hasToolsConfiguration { ids.insert(CapabilityCatalog.tools) }
        if hasConnectionsConfiguration { ids.insert(CapabilityCatalog.connections) }
        return ids
    }

    // MARK: - Per-category probes

    private static var hasCaptureConfiguration: Bool {
        Config.isBroadcastConfigured
            || Config.broadcastChatReadbackEnabled
            || !Config.broadcastRTMPURL.isEmpty
    }

    private static var hasDisplayConfiguration: Bool {
        Config.glassesDisplayEnabled
            || Config.displayBackend != .metaRayBan
            || !Config.hudChoiceButtonsEnabled
    }

    /// Note what is *not* here: a count of saved models, or "has any persona". Both
    /// are seeded — a fresh install arrives with several models (the on-device one
    /// among them) and exactly one default persona — so either test marks every
    /// first launch as configured and unfolds the category for a user who has chosen
    /// nothing. A credential, or a *second* persona, is what only a person supplies.
    private static var hasIntelligenceConfiguration: Bool {
        Config.savedModels.contains { !$0.apiKey.isEmpty }
            || Config.savedPersonas.count > 1
            || Config.autoModelRoutingEnabled
            || Config.agentModeEnabled
    }

    private static var hasToolsConfiguration: Bool {
        !Config.disabledTools.isEmpty
            || Config.fieldAssistEnabled
            || !Config.customTools.isEmpty
    }

    private static var hasConnectionsConfiguration: Bool {
        !Config.savedGateways.isEmpty
            || !Config.mcpServers.isEmpty
            || !Config.elevenLabsAPIKey.isEmpty
            || !Config.perplexityAPIKey.isEmpty
    }

    /// `advanced` has no configuration of its own to detect — it is a set of
    /// inspectors, not settings. An upgrader reaches it through the prior-install
    /// marker; a fresh install meets it as a Discover card, which is the right
    /// answer for a developer surface.
    static let categoriesWithoutProbes: Set<String> = [CapabilityCatalog.advanced]
}
