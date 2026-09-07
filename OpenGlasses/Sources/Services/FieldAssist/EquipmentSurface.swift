import Foundation

/// The slice of `FieldSessionService` the equipment surfaces need — the session card and the
/// lens line. A protocol so both are provable without standing up a vault, a session or SwiftUI,
/// in the same shape `ProcedureHosting` already uses for the HUD procedure card.
@MainActor
protocol EquipmentHosting: AnyObject {
    var activeEquipment: EquipmentIdentity? { get }
    var modelIndex: VaultModelIndex { get }
    func setEquipment(_ identity: EquipmentIdentity)
    func clearEquipment()
}

extension FieldSessionService: EquipmentHosting {}

/// What the session card draws for the machine in front of the technician, decided without
/// SwiftUI (Plan EL P2).
///
/// Identity was recorded, persisted and used in P1 and shown nowhere: the one place a wrong read
/// is visible is a screen, and the one place it can be corrected without speaking is a button. A
/// vault that names no models has nothing to draw and says so with `.unavailable` — the section is
/// then absent rather than empty, which is what keeps the bundled vaults' screens as they were.
@MainActor
struct EquipmentSectionModel {

    enum State: Equatable {
        /// This vault's core names no models — draw nothing at all.
        case unavailable
        /// No machine recorded yet; these are the vault's own models to pick from.
        case unset(choices: [Choice])
        /// A machine is recorded. `choices` lets the technician correct it in one tap.
        case identified(Detail, choices: [Choice])
    }

    /// One model section of the vault, as the picker lists it.
    struct Choice: Equatable, Identifiable {
        /// The heading — unique per model section, and what identity is matched on.
        var id: String { heading }
        let name: String
        let heading: String
        let file: String
        let isActive: Bool
    }

    /// The recorded machine, in the words the card shows.
    struct Detail: Equatable {
        let model: String
        let heading: String
        let source: EquipmentIdentity.Source
        let recognisedAt: Date

        /// "from the nameplate at 14:02" — the provenance line under the model token.
        var provenance: String {
            "\(source.provenancePhrase) at \(EquipmentIdentity.clock(recognisedAt))"
        }
    }

    private let host: EquipmentHosting

    init(host: EquipmentHosting) {
        self.host = host
    }

    var state: State {
        let index = host.modelIndex
        guard !index.isEmpty else { return .unavailable }
        let active = host.activeEquipment
        let choices = index.models.map {
            Choice(name: $0.name, heading: $0.heading, file: $0.file,
                   isActive: $0.heading == active?.heading)
        }
        guard let active else { return .unset(choices: choices) }
        return .identified(Detail(model: active.modelToken, heading: active.heading,
                                  source: active.source, recognisedAt: active.recognisedAt),
                           choices: choices)
    }

    /// Record the model the technician picked from the list. `.manual` rather than `.spoken`:
    /// the audit record should not say the technician read a plate when they tapped a row.
    func select(_ choice: Choice) {
        guard let model = host.modelIndex.models.first(where: { $0.heading == choice.heading }) else { return }
        host.setEquipment(EquipmentIdentity(model: model, token: model.name, source: .manual))
    }

    func clear() {
        host.clearEquipment()
    }
}

/// The one line the lens carries about the machine (Plan EL P2).
///
/// Same path as the figure cue: a transient notification over whatever the HUD is showing, and
/// nothing persistent. A technician who has just been told "answering for the 090" needs to see
/// which machine that was; they do not need a permanent banner eating the display.
enum EquipmentHUDCue {

    /// "SLP99UH090XV60CK · Lennox SLP99 Furnace Service", or what a cleared identity says.
    static func line(for identity: EquipmentIdentity?, vaultName: String?) -> String {
        let vault = vaultName.flatMap { $0.isEmpty ? nil : $0 }
        guard let identity else {
            return vault.map { "No equipment set · \($0)" } ?? "No equipment set"
        }
        return vault.map { "\(identity.modelToken) · \($0)" } ?? identity.modelToken
    }

    /// Flash the line. A no-op without a display, which the service itself decides.
    @MainActor
    static func show(_ identity: EquipmentIdentity?, vaultName: String?, on display: GlassesDisplayService) {
        display.showNotification(title: nil, body: line(for: identity, vaultName: vaultName),
                                 icon: .info, duration: 5)
    }
}
