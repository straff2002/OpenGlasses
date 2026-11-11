import Foundation

/// Plan KX §6: the wearer's Home Assistant quick actions as a list on the lens (Today › Menu ›
/// Home). Pure.
///
/// One button per action (`ha:<id>`, its own label), at most `pageSize` (5) to a page, then
/// **More…** when there are more, **Back** (the previous page, or the Menu from the first) and
/// **Close** (the launcher). The first action takes focus. Pressing one runs it
/// (`HomeFavouriteRunner`) and a short line says how it went, over the list, which stays up for the
/// next press.
enum HUDHomeFavouritesBuilder {
    static let pageSize = 5

    enum ItemID {
        static let more = "kx.home.more"
        static let back = "back"
        static let close = "kx.home.close"
        static func action(_ id: String) -> String { "ha:\(id)" }
    }

    static var title: String {
        String(localized: "Home", comment: "Glasses: heading of the Home Assistant favourites list, and its launcher item.")
    }

    /// The favourites among `actions`: Home Assistant quick actions that name a service.
    static func favourites(_ actions: [QuickAction]) -> [QuickAction] {
        actions.filter { $0.type == .homeAssistant && !($0.haService ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    }

    static func pageCount(_ count: Int) -> Int { max(1, (count + pageSize - 1) / pageSize) }

    static func screen(_ actions: [QuickAction], page: Int,
                       onRun: @escaping (QuickAction) -> Void,
                       onMore: @escaping (Int) -> Void,
                       onBack: @escaping () -> Void,
                       onClose: @escaping () -> Void) -> HUDScreen {
        let pages = pageCount(actions.count)
        let page = min(max(0, page), pages - 1)
        let start = page * pageSize
        let slice = actions.isEmpty ? [] : Array(actions[start..<min(start + pageSize, actions.count)])
        var items = slice.map { action in
            HUDItem(id: ItemID.action(action.id), label: action.label, style: .primary) { onRun(action) }
        }
        if page + 1 < pages {
            items.append(HUDItem(id: ItemID.more, label: String(localized: "More…", comment: "Glasses: the next page of a list."),
                                 style: .secondary) { onMore(page + 1) })
        }
        items.append(HUDItem(id: ItemID.back, label: String(localized: "Back", comment: "Glasses: back to the previous screen."),
                             style: .outline, action: onBack))
        items.append(HUDItem(id: ItemID.close, label: String(localized: "Close", comment: "Glasses: closes a card."),
                             style: .outline, action: onClose))
        var lines: [HUDLine] = []
        if actions.isEmpty {
            lines.append(HUDLine(String(localized: "No Home Assistant actions yet", comment: "Glasses: the Home list with nothing in it."),
                                 emphasis: .secondary))
        } else if pages > 1 {
            lines.append(HUDLine("\(page + 1)/\(pages)", emphasis: .meta))
        }
        return HUDScreen(title: title, lines: lines, items: items, focusItemID: slice.first.map { ItemID.action($0.id) })
    }

    /// The line a run leaves on the lens, by how it went.
    static func line(for outcome: HomeFavouriteOutcome, label: String) -> String {
        switch outcome {
        case .done:
            return String(localized: "✓ \(label)", comment: "Glasses: a Home Assistant action ran. The argument is its name.")
        case .failed:
            return String(localized: "Couldn't run \(label)", comment: "Glasses: a Home Assistant action failed. The argument is its name.")
        case .declined:
            return String(localized: "Not run: \(label)", comment: "Glasses: a Home Assistant action was not approved. The argument is its name.")
        }
    }
}

/// How a favourite's run went.
enum HomeFavouriteOutcome: Equatable {
    case done, failed, declined
}

/// Plan KX §6: runs one Home Assistant quick action pressed on the lens.
///
/// **Directly, not through the model.** The phone's quick action asks the model to call the
/// service; a press on the lens calls it itself (`HomeAssistantTool.runFavourite`), with the same
/// guards the tool applies (Medical egress, the configured URL and token, Plan GS's service-data
/// allowlist) and no Conversation fallback, so the line can say plainly whether it ran.
///
/// **Confirmation first where it is owed.** An action the confirmation floor classes as
/// security-relevant (`HighImpactToolPolicy`: unlock, open a cover or garage, arm or disarm) is never
/// run on one press: it goes to the shared consent surface (`ToolConfirmationCoordinator`), which
/// P2 draws as the approval card on the lens, and runs only on Approve.
enum HomeFavouriteRunner {
    /// The service call a quick action names: `light.turn_off` on `light.kitchen` is domain `light`,
    /// service `turn_off`. The domain is the service's own prefix, else the entity's. Nil when the
    /// action names no service or no entity.
    struct Call: Equatable {
        let domain: String
        let service: String
        let entityId: String
        let dataJSON: String?
    }

    static func call(for action: QuickAction) -> Call? {
        guard action.type == .homeAssistant else { return nil }
        let raw = (action.haService ?? "").trimmingCharacters(in: .whitespaces)
        let entity = (action.haEntityId ?? "").trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty, !entity.isEmpty else { return nil }
        let parts = raw.split(separator: ".", maxSplits: 1).map(String.init)
        let service = parts.count == 2 ? parts[1] : raw
        let domain = parts.count == 2 ? parts[0] : (entity.split(separator: ".").first.map(String.init) ?? "homeassistant")
        guard !service.isEmpty, !domain.isEmpty else { return nil }
        let data = action.haData?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Call(domain: domain, service: service, entityId: entity, dataJSON: (data?.isEmpty ?? true) ? nil : data)
    }

    /// The confirmation summary when the floor asks for one, else nil.
    static func confirmationSummary(for call: Call) -> String? {
        let args: [String: Any] = ["action": "call_service", "service": "\(call.domain).\(call.service)",
                                   "entity_id": call.entityId]
        if case .requiresConfirmation(let summary) = HighImpactToolPolicy.evaluate(tool: "home_assistant", args: args) {
            return summary
        }
        return nil
    }

    /// The service data as a dictionary; nil when it is set but is not a JSON object.
    static func data(for call: Call) -> [String: Any]? {
        guard let json = call.dataJSON else { return [:] }
        guard let bytes = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return nil }
        return object
    }

    /// Run `action`: confirm first when owed, then call. `confirm` asks the wearer (true: approved);
    /// `perform` makes the call (true: Home Assistant accepted it).
    @MainActor
    static func run(_ action: QuickAction,
                    confirm: (String) async -> Bool,
                    perform: (Call, [String: Any]) async -> Bool) async -> HomeFavouriteOutcome {
        guard let call = call(for: action), let data = data(for: call) else { return .failed }
        if let summary = confirmationSummary(for: call) {
            guard await confirm(summary) else { return .declined }
        }
        return await perform(call, data) ? .done : .failed
    }
}
