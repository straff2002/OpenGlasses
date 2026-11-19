import Foundation

/// Every word the model hears about where the stock is kept (Plan MK §3). Pure, and English on
/// purpose: the model reads these and answers in the person's own language, as the rest of van
/// stock's model-facing text does (Plan IH P0).
///
/// One row of the plan's table per member, one switch per member, so a new kind is one case in
/// each. Phrases are lower case, ready to go inside a sentence; `title` is the one that stands
/// alone. The van's phrases are what ships today, so a list left at van reads exactly as before.
/// Nothing routes through this yet: Plan MK P1 moves each sentence onto it.
struct StockPlaceWording: Equatable, Sendable {

    let kind: StockPlace.Kind

    init(_ kind: StockPlace.Kind) {
        self.kind = kind
    }

    var family: StockPlace.Family { kind.family }

    /// Where the stock is: "22 on the van", "22 in the store", "22 in stock".
    var location: String {
        switch kind {
        case .van: return "on the van"
        case .truck: return "on the truck"
        case .store: return "in the store"
        case .warehouse: return "in the warehouse"
        case .stock: return "in stock"
        }
    }

    /// The list itself: "It is not a line on the van list".
    var list: String {
        switch kind {
        case .van: return "the van list"
        case .truck: return "the truck list"
        case .store, .warehouse, .stock: return "the stock list"
        }
    }

    /// The one word for stock arriving: "loaded 4 × Flame sensor". Premises say "received", the
    /// word the plan's tool description gives a store (Plan MK §3), because "loaded" belongs to a
    /// vehicle.
    var putVerb: String {
        switch family {
        case .vehicle: return "loaded"
        case .premises: return "received"
        }
    }

    /// Stock arriving, with the place: "put on the van", "put in the store", "put into stock".
    var putThere: String {
        switch kind {
        case .van: return "put on the van"
        case .truck: return "put on the truck"
        case .store: return "put in the store"
        case .warehouse: return "put in the warehouse"
        case .stock: return "put into stock"
        }
    }

    /// The word for stock going out: "used" on a vehicle, "sold or used" at premises.
    var takenVerb: String {
        switch kind {
        case .van, .truck: return "used"
        case .store, .warehouse: return "sold or used"
        case .stock: return "used or sold"
        }
    }

    /// Stock going out, with the place: "taken off the van", "taken from the store".
    var takenFrom: String {
        switch kind {
        case .van: return "taken off the van"
        case .truck: return "taken off the truck"
        case .store: return "taken from the store"
        case .warehouse: return "taken from the warehouse"
        case .stock: return "taken from stock"
        }
    }

    /// The figure a line is brought back up to: "standard load" on a vehicle, "par level" at
    /// premises (Plan MK Decision 8).
    var usualFigure: String {
        switch family {
        case .vehicle: return "standard load"
        case .premises: return "par level"
        }
    }

    /// Who set the usual figure when it came from outside the list: "set by base", "set by the
    /// office".
    var setByOffice: String {
        switch family {
        case .vehicle: return "base"
        case .premises: return "the office"
        }
    }

    /// Who set the usual figure when the list set it itself. A van says "this truck", as its
    /// workbook already does.
    var setByList: String {
        switch kind {
        case .van, .truck: return "this truck"
        case .store: return "this store"
        case .warehouse: return "this warehouse"
        case .stock: return "this list"
        }
    }

    /// What the end-of-shift handover does: "send the stock to base", or at premises "send the
    /// stock list", which never says base (Plan MK Decision 9).
    var handover: String {
        switch family {
        case .vehicle: return "send the stock to base"
        case .premises: return "send the stock list"
        }
    }

    /// The list's title when it has no name of its own: "Van stock", "Store stock", "Stock".
    /// English here, for the model and the handover message; the screen's localised titles come in
    /// Plan MK P2.
    var title: String {
        switch kind {
        case .van: return "Van stock"
        case .truck: return "Truck stock"
        case .store: return "Store stock"
        case .warehouse: return "Warehouse stock"
        case .stock: return "Stock"
        }
    }

    /// Every phrase, for tests and guards that need to look at all of them at once.
    var allPhrases: [String] {
        [location, list, putVerb, putThere, takenVerb, takenFrom, usualFigure, setByOffice, setByList,
         handover, title]
    }
}
