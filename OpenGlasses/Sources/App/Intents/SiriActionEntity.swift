import AppIntents

/// A user-exposed OpenGlasses action, resolvable inside an App Shortcut phrase
/// ("Run *pump inspection* on OpenGlasses") — Plan BQ P1.
///
/// The entity list is runtime data (`SiriActionCatalog`), which is the whole trick: static
/// intents can't be added/removed after compile, but what THIS entity's query returns is
/// entirely user-controlled — built-in toggles, harvested capabilities, hand-made actions.
struct SiriActionEntity: AppEntity, Identifiable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "OpenGlasses Action"
    static var defaultQuery = SiriActionQuery()

    let id: String
    let displayName: String

    init(entry: SiriActionCatalog.Entry) {
        self.id = entry.id
        self.displayName = entry.displayName
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(displayName)")
    }
}

/// Builds the catalog the entity query + `RunGlassesActionIntent` resolve against.
/// `override` is the headless-test seam; the live path reads Config + the capability
/// libraries (Field Assist vault contents are only visible while a session's vault is
/// active — harvest degrades gracefully to whatever is readable).
@MainActor
enum SiriActionCatalogProvider {
    static var override: (() -> SiriActionCatalog)?

    static func current() -> SiriActionCatalog {
        if let override { return override() }
        return live()
    }

    private static func live() -> SiriActionCatalog {
        let flows = FieldSessionService.shared.activeVault
            .map { CaptureFlowLibrary(store: $0).all.map { (id: $0.id, title: $0.title) } } ?? []
        let procedures = FieldSessionService.shared.availableProcedureDefinitions()
            .map { (id: $0.id, title: $0.title) }
        let playbooks = (AppStateProvider.shared?.playbookStore.playbooks ?? [])
            .map { (id: $0.id, name: $0.name) }
        let harvested = CapabilityHarvester.harvest(
            flows: flows,
            procedures: procedures,
            playbooks: playbooks,
            customTools: Config.customTools,
            // The whole grid, not the arranged subset: a tile taken off the bar is still the
            // wearer's action, and a hardware button bound to it keeps working.
            gridEntries: HomeGridCatalog.available(quickActions: Config.quickActions)
        )
        return SiriActionCatalog(
            config: Config.siriExposure,
            harvested: harvested,
            agentModeEnabled: Config.agentModeEnabled,
            blockedToolNames: Config.hipaaMode ? Config.hipaaDisabledTools : []
        )
    }
}

/// `EntityStringQuery` (not just `EntityQuery`) so Siri resolves a *spoken* action name —
/// "run daily briefing" — against names and synonyms, mirroring `PersonaQuery`.
struct SiriActionQuery: EntityStringQuery {
    /// Resolve by id. Deliberately includes disabled entries: a stale saved Shortcut should
    /// resolve and then fail with the clear "turned off in Settings" error from the intent,
    /// not Siri's generic "couldn't find that".
    func entities(for identifiers: [SiriActionEntity.ID]) async throws -> [SiriActionEntity] {
        let catalog = await SiriActionCatalogProvider.current()
        return identifiers.compactMap { catalog.entry(id: $0).map(SiriActionEntity.init) }
    }

    func suggestedEntities() async throws -> [SiriActionEntity] {
        await SiriActionCatalogProvider.current().enabledEntries.map(SiriActionEntity.init)
    }

    func entities(matching string: String) async throws -> [SiriActionEntity] {
        await SiriActionCatalogProvider.current().entries(matching: string).map(SiriActionEntity.init)
    }
}
