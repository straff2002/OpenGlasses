import Foundation

/// Creating an action, as data.
///
/// A new grid action is a name, a glyph, a kind, and a sentence — nothing here can express
/// anything the grid could not already run, because what it produces is an ordinary
/// `QuickAction` in the store the widget, the watch and the HUD launcher already read. The
/// composition rules live in this file rather than in the sheet that collects them, so "can this
/// be edited", "is this name taken" and "what does deleting it revoke" are answerable without a
/// screen.
struct HomeActionDraft: Equatable {
    /// The action being edited, or nil for a new one.
    var id: String?
    var name: String = ""
    var icon: String = HomeActionIcons.defaultSymbol
    var kind: HomeGridAction.Kind = .prompt
    var prompt: String = ""

    var isNew: Bool { id == nil }

    /// The two kinds the grid draws, as the store spells them.
    var actionType: QuickAction.ActionType {
        kind == .photoPrompt ? .photoThenPrompt : .prompt
    }

    init(id: String? = nil, name: String = "", icon: String = HomeActionIcons.defaultSymbol,
         kind: HomeGridAction.Kind = .prompt, prompt: String = "") {
        self.id = id
        self.name = name
        self.icon = icon
        self.kind = kind
        self.prompt = prompt
    }

    /// Load an existing speed-dial action for editing. Returns nil for anything this editor is
    /// not allowed to express — an action whose kind it could not round-trip is one it would
    /// quietly rewrite, which is worse than refusing.
    init?(editing action: QuickAction) {
        guard SpeedDialEditor.isEditable(action) else { return nil }
        self.init(
            id: action.id,
            name: action.label,
            icon: action.icon,
            kind: action.type == .photoThenPrompt ? .photoPrompt : .prompt,
            prompt: action.promptText ?? "")
    }
}

/// The glyphs the creation sheet offers. A curated set, not a symbol browser: every one of these
/// reads at the tile's 16 pt and says something about what the action does.
enum HomeActionIcons {
    static let defaultSymbol = "star"

    static let curated: [(symbol: String, name: String)] = [
        ("star", "Star"), ("eye", "Describe"), ("camera", "Camera"),
        ("calendar", "Calendar"), ("checklist", "Checklist"), ("lightbulb", "Light On"),
        ("lightbulb.slash", "Light Off"), ("house", "Home"), ("lock", "Lock"),
        ("lock.open", "Unlock"), ("thermometer", "Climate"), ("fan", "Fan"),
        ("music.note", "Music"), ("phone", "Phone"), ("message", "Message"),
        ("envelope", "Email"), ("globe", "Web"), ("map", "Map"),
        ("location", "Location"), ("bell", "Alert"), ("alarm", "Alarm"),
        ("timer", "Timer"), ("brain", "AI"), ("wand.and.stars", "Magic"),
        ("fork.knife", "Food"), ("cart", "Shopping"), ("car", "Drive"),
        ("airplane", "Travel"), ("figure.walk", "Walk"), ("text.viewfinder", "Read"),
    ]

    static func contains(_ symbol: String) -> Bool {
        curated.contains { $0.symbol == symbol }
    }
}

/// Create, edit and delete the wearer's speed-dial actions — the half of the grid that is data.
///
/// Pure over the two stores it touches (`Config.quickActions` and `SiriExposureConfig`), so the
/// rules that matter are provable: what is immune, what a name may be, and — the one with teeth —
/// that deleting an action and revoking its voice exposure is a single result rather than two
/// calls a caller can half-make.
enum SpeedDialEditor {
    enum Issue: Equatable {
        case emptyName
        case duplicateName(String)
        case emptyPrompt
        /// Built-in: shipped in code, or re-merged into every install. Not the wearer's to edit.
        case notEditable
    }

    /// Speed-dial ids the app itself manages. Field Assist is injected per read and never
    /// persisted; the travel templates and the record toggle are merged back into any list that
    /// lacks them. Offering "delete" on one of these would be a lie — it returns on the next read
    /// — so they are built-ins here in exactly the sense the shipped grid actions are.
    static var managedIds: Set<String> {
        var ids = Set(QuickAction.travelTemplates.map(\.id))
        ids.insert(QuickAction.fieldAssist.id)
        ids.insert(QuickAction.recordMeeting.id)
        return ids
    }

    /// Whether this editor may rewrite the action: the wearer authored it, and it is one of the
    /// two kinds the editor can express.
    static func isEditable(_ action: QuickAction) -> Bool {
        guard !managedIds.contains(action.id) else { return false }
        return action.type == .prompt || action.type == .photoThenPrompt
    }

    /// Whether the action can be deleted outright. Same rule as editing, minus the kind check:
    /// an action of an advanced kind is still the wearer's data, and removing it must work from
    /// wherever they can see it.
    static func isDeletable(_ action: QuickAction) -> Bool {
        !managedIds.contains(action.id)
    }

    /// A grid entry the editor may act on at all — the shipped tiles never are.
    static func editableAction(for entry: HomeGridEntry) -> QuickAction? {
        guard case .quickAction(let action) = entry, isEditable(action) else { return nil }
        return action
    }

    static func validate(_ draft: HomeActionDraft, against actions: [QuickAction]) -> Issue? {
        if let id = draft.id,
           let existing = actions.first(where: { $0.id == id }),
           !isEditable(existing) {
            return .notEditable
        }
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return .emptyName }

        // Names are spoken now, not just drawn: two tiles called the same thing are two entities
        // Siri cannot tell apart. Checked against the shipped tiles as well as the speed dial.
        let taken: [String] = HomeGridAction.builtIns.map(\.label)
            + actions.filter { $0.id != draft.id }.map(\.label)
        if let collision = taken.first(where: { $0.lowercased() == name.lowercased() }) {
            return .duplicateName(collision)
        }

        if draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .emptyPrompt
        }
        return nil
    }

    /// The stored action a draft becomes. `id` is preserved on edit, which is what keeps a tile's
    /// place in the arrangement and its voice exposure attached across a rename.
    static func quickAction(from draft: HomeActionDraft) -> QuickAction {
        var action = QuickAction(
            id: draft.id ?? UUID().uuidString,
            label: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
            icon: draft.icon,
            type: draft.actionType)
        action.promptText = draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return action
    }

    /// The list to persist after saving `draft`: an edit in place, or an append.
    static func applying(_ draft: HomeActionDraft, to actions: [QuickAction]) -> [QuickAction] {
        let saved = quickAction(from: draft)
        var next = persistable(actions)
        if let index = next.firstIndex(where: { $0.id == saved.id }) {
            next[index] = saved
        } else {
            next.append(saved)
        }
        return next
    }

    /// What deleting an action leaves behind — both stores, or neither.
    struct Deletion: Equatable {
        var actions: [QuickAction]
        var exposure: SiriExposureConfig
        /// Whether the action was exposed to voice before this deletion. The confirm copy says so.
        var revokedVoiceExposure: Bool
    }

    /// Delete a speed-dial action and revoke its voice exposure in the same step.
    ///
    /// Returned as one value rather than performed as two writes: an id that still sits in
    /// `enabledCapabilityIds` after its action is gone is an entry the catalog silently drops and
    /// the wearer can never see to turn off again. Nil for anything not deletable.
    static func deleting(id: String, from actions: [QuickAction],
                         exposure: SiriExposureConfig) -> Deletion? {
        guard let action = actions.first(where: { $0.id == id }), isDeletable(action) else {
            return nil
        }
        var nextExposure = exposure
        let key = exposureKey(forQuickActionId: id)
        let wasExposed = nextExposure.enabledCapabilityIds.remove(key) != nil
        return Deletion(
            actions: persistable(actions).filter { $0.id != id },
            exposure: nextExposure,
            revokedVoiceExposure: wasExposed)
    }

    /// The key this action's voice exposure is stored under — the grid's own entry id, wrapped
    /// the way every harvested capability is.
    static func exposureKey(forQuickActionId id: String) -> String {
        SiriExposureConfig.capabilityKey(
            kind: .gridAction, id: HomeGridEntry.quickAction(
                QuickAction(id: id, label: "", icon: "", type: .prompt)).id)
    }

    /// Strip the entries that are injected per read rather than stored, so a save never writes a
    /// copy of one back into the persisted list.
    private static func persistable(_ actions: [QuickAction]) -> [QuickAction] {
        actions.filter { $0.id != QuickAction.fieldAssist.id }
    }
}
