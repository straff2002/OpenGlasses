import Foundation

/// What the Stock screen says about the place, localised for the person reading it (Plan MK §3).
/// Pure.
///
/// Kept apart from `StockPlaceWording`, which is English on purpose because the model reads it.
/// The screen's sentences name no place (Plan MK Decision 5). The place shows only where a name
/// works on its own, the title and the Job-tab row, and in the three strings that need the kind:
/// the takeover, the empty list's hint and the name field's placeholder.
enum StockPlaceScreenText {

    /// The title when the list has no name of its own: "Van stock", "Store stock", "Stock".
    static func title(_ kind: StockPlace.Kind) -> String {
        switch kind {
        case .van: return String(localized: "Van stock")
        case .truck: return String(localized: "Truck stock")
        case .store: return String(localized: "Store stock")
        case .warehouse: return String(localized: "Warehouse stock")
        case .stock: return String(localized: "Stock")
        }
    }

    /// The screen's title and the Job-tab row: the list's name when it has one, otherwise the
    /// kind's title (Plan MK §3).
    static func title(_ kind: StockPlace.Kind, name: String?) -> String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? title(kind) : trimmed
    }

    /// The choice that takes a workbook over as this phone's list. A vehicle is what the next
    /// shift takes over; at premises it is the list that changes hands (Plan MK Decision 9).
    static func takeOver(_ kind: StockPlace.Kind) -> String {
        switch kind {
        case .van: return String(localized: "Take over this van")
        case .truck: return String(localized: "Take over this truck")
        case .store, .warehouse, .stock: return String(localized: "Take over this list")
        }
    }

    /// The empty list's hint: what to say to the assistant to put stock on it. A vehicle keeps
    /// the hint it has always had.
    static func emptyHint(_ kind: StockPlace.Kind) -> String {
        switch kind.family {
        case .vehicle:
            return String(localized: "Tell the assistant what you've loaded — “I've loaded four flame sensors” — or count what's on the shelves.")
        case .premises:
            return String(localized: "Tell the assistant what you've put in — “I've put in six cases of soda water” — or count what's on the shelves.")
        }
    }

    /// An example name for the name field.
    static func namePlaceholder(_ kind: StockPlace.Kind) -> String {
        switch kind {
        case .van: return String(localized: "Van 2")
        case .truck: return String(localized: "Truck 4")
        case .store: return String(localized: "Main street store")
        case .warehouse: return String(localized: "Warehouse A")
        case .stock: return String(localized: "Workshop")
        }
    }

    /// The kind as the place picker lists it.
    static func kindName(_ kind: StockPlace.Kind) -> String {
        switch kind {
        case .van: return String(localized: "Van")
        case .truck: return String(localized: "Truck")
        case .store: return String(localized: "Store")
        case .warehouse: return String(localized: "Warehouse")
        case .stock: return String(localized: "Somewhere else")
        }
    }

    /// The organisation profile's summary line for the place it sets (Plan MK §2).
    static func profileSummary(_ kind: StockPlace.Kind) -> String {
        switch kind {
        case .van: return String(localized: "Stock is kept on the van")
        case .truck: return String(localized: "Stock is kept on the truck")
        case .store: return String(localized: "Stock is kept in the store")
        case .warehouse: return String(localized: "Stock is kept in the warehouse")
        case .stock: return String(localized: "Stock is kept on a list that names no place")
        }
    }

    /// The organisation profile's summary line for the clinical flag (Plan MY §9).
    static func clinicalProfileSummary(_ clinical: Bool) -> String {
        clinical ? String(localized: "The stock list is a clinic's: doses given and wasted, by lot")
                 : String(localized: "The stock list is not a clinic's")
    }

    // MARK: - The book numbers are checked against

    /// Which book the list names, as the "Check numbers against" picker shows it (Plan MK §4).
    enum Book: Equatable {
        /// Nothing is searched with no job open.
        case none
        /// An installed vault, by id.
        case installed(String)
        /// The list names a vault that is no longer on this phone. It is treated as none, and the
        /// sheet says it has gone.
        case gone(String)
    }

    /// The list's saved vault id, read against the vaults this phone can open now.
    static func book(saved: String?, installed: Set<String>) -> Book {
        guard let saved, !saved.isEmpty else { return .none }
        return installed.contains(saved) ? .installed(saved) : .gone(saved)
    }
}

extension StockPlaceSetting {
    /// The place in force on this phone: the organisation's profile over the list's own choice,
    /// over van (Plan MK §2).
    static func current(list: StockPlace.Kind?) -> Resolved {
        resolve(profile: Config.organizationStockPlace, list: list)
    }
}

extension VanStockStore {
    /// The place in force for this list (Plan MK §2). The screen, the Job-tab row and the
    /// workbook all read it from here.
    var resolvedPlace: StockPlaceSetting.Resolved { StockPlaceSetting.current(list: van?.place) }

    /// The screen's title: the list's name, or the place's title (Plan MK §3).
    var screenTitle: String { StockPlaceScreenText.title(resolvedPlace.kind, name: van?.name) }

    /// Whether the list is a clinic's (Plan MY §9): the organisation's profile over the list's
    /// own choice.
    var resolvedClinical: StockClinicalSetting.Resolved {
        StockClinicalSetting.resolve(profile: Config.organizationStockClinical, list: van?.clinical)
    }
}
