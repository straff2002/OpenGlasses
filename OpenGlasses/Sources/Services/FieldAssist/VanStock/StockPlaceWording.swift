import Foundation

/// Every word the model hears about where the stock is kept (Plan MK §3). Pure, and English on
/// purpose: the model reads these and answers in the person's own language, as the rest of van
/// stock's model-facing text does (Plan IH P0).
///
/// One row of the plan's table per member, one switch per member, so a new kind is one case in
/// each. Phrases are lower case, ready to go inside a sentence; `title` is the one that stands
/// alone. The van's phrases are what shipped before Plan MK, so a list left at van reads exactly as
/// it always has. Every sentence van stock says to the model is built from these (Plan MK P1);
/// `StockPlaceWordingGuardTests` fails on a place word written anywhere else.
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
    var list: String { "the \(listNoun)" }

    /// The list without its article: "no readable van list".
    var listNoun: String {
        switch kind {
        case .van: return "van list"
        case .truck: return "truck list"
        case .store, .warehouse, .stock: return "stock list"
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

    // MARK: - The words sentences need besides the table (Plan MK P1)

    /// What the stock is called as a thing: "a van stock entry", "the stock list on this phone".
    var stockName: String {
        switch kind {
        case .van: return "van stock"
        case .truck: return "truck stock"
        case .store, .warehouse, .stock: return "stock"
        }
    }

    /// The movement log by name: "as far as the van log knows".
    var log: String {
        switch kind {
        case .van: return "the van log"
        case .truck: return "the truck log"
        case .store, .warehouse, .stock: return "the stock log"
        }
    }

    /// Who keeps the list: a technician on a vehicle; at premises, whoever is serving or stocking.
    var person: String {
        switch family {
        case .vehicle: return "the technician"
        case .premises: return "the person"
        }
    }

    /// What is there now, after a figure: "(2 on board)", "(2 on hand)".
    var aboard: String {
        switch family {
        case .vehicle: return "on board"
        case .premises: return "on hand"
        }
    }

    /// The place as the object of a sentence: "bring the van back to its standard load". The
    /// neutral kind has no place, so it brings "the stock" back.
    var placeNoun: String {
        switch kind {
        case .van: return "the van"
        case .truck: return "the truck"
        case .store: return "the store"
        case .warehouse: return "the warehouse"
        case .stock: return "the stock"
        }
    }

    /// The place as this list's own: "No standard load is set for this van".
    var this: String {
        switch kind {
        case .van: return "this van"
        case .truck: return "this truck"
        case .store: return "this store"
        case .warehouse: return "this warehouse"
        case .stock: return "this list"
        }
    }

    /// A part leaving the place, after "did not" or "to have": "come off the van".
    var comeFrom: String {
        switch kind {
        case .van: return "come off the van"
        case .truck: return "come off the truck"
        case .store: return "come from the store"
        case .warehouse: return "come from the warehouse"
        case .stock: return "come from stock"
        }
    }

    /// The same, in the past: "whether each came off the van".
    var cameFrom: String {
        switch kind {
        case .van: return "came off the van"
        case .truck: return "came off the truck"
        case .store: return "came from the store"
        case .warehouse: return "came from the warehouse"
        case .stock: return "came from stock"
        }
    }

    /// A part that did not leave the place: "noted as not from the van".
    var notFrom: String {
        switch kind {
        case .van: return "not from the van"
        case .truck: return "not from the truck"
        case .store: return "not from the store"
        case .warehouse: return "not from the warehouse"
        case .stock: return "not from stock"
        }
    }

    /// How many a line should have: "Say how many fuses the van should carry".
    var shouldHold: String {
        switch kind {
        case .van: return "the van should carry"
        case .truck: return "the truck should carry"
        case .store: return "the store should keep"
        case .warehouse: return "the warehouse should keep"
        case .stock: return "should be kept in stock"
        }
    }

    /// Stock arriving, as a noun: "the load of 4 × Flame sensor", "the receipt of 6 packs".
    var putNoun: String {
        switch family {
        case .vehicle: return "load"
        case .premises: return "receipt"
        }
    }

    /// The Stock screen, by the title the place gives it: "the Van stock screen", "the Stock
    /// screen".
    var screen: String { "the \(title) screen" }

    /// What the list holds, for the tool's description: parts on a vehicle, stock at premises.
    var goods: String {
        switch family {
        case .vehicle: return "parts"
        case .premises: return "stock"
        }
    }

    /// The tool description's first two sentences (Plan MK §3): what the list is and when to use
    /// it. A van keeps the sentences it has always had.
    var toolLead: String {
        switch kind {
        case .van:
            return "The technician's own van or truck stock, kept on the phone. Use it whenever they ask what is "
                + "on the van or truck, or say they loaded, used, returned or counted parts."
        case .truck:
            return "The technician's own truck stock, kept on the phone. Use it whenever they ask what is "
                + "on the truck, or say they loaded, used, returned or counted parts."
        case .store, .warehouse:
            return "The stock kept \(location), on the phone. Use it whenever they ask what is \(location), "
                + "or say they received, sold, used, returned or counted stock."
        case .stock:
            return "The stock list, kept on the phone. Use it whenever they ask what is in stock, "
                + "or say they received, used, sold, returned or counted stock."
        }
    }

    /// What `use` records, for the tool's description: "parts fitted from the van".
    var useGloss: String {
        switch kind {
        case .van: return "parts fitted from the van"
        case .truck: return "parts fitted from the truck"
        case .store: return "stock sold or used from the store"
        case .warehouse: return "stock sold or used from the warehouse"
        case .stock: return "stock used or sold"
        }
    }

    /// What `send_to_base` does, for the tool's description. Premises send the stock list, never
    /// to base (Plan MK Decision 9).
    var handoverGloss: String {
        switch family {
        case .vehicle: return "stages the end-of-shift stock for the technician to send"
        case .premises: return "stages the stock list, with what to reorder and what needs counting, for the person to send"
        }
    }

    /// Why the handover is refused under Medical Compliance mode, as the sentence starts.
    var handoverNotSent: String {
        switch family {
        case .vehicle: return "The stock is not sent to base"
        case .premises: return "The stock list is not sent"
        }
    }

    /// The day's extras question `send_to_base` asks first, about stock loaded this shift and
    /// still on board beyond the standard load. Nil at premises: a shop's stock does not travel,
    /// so "returning it, or keeping it on the truck?" would only confuse (Plan MK §5).
    func extrasQuestion(_ listed: String) -> String? {
        guard family == .vehicle else { return nil }
        return "Loaded this shift and still on board beyond the standard load: " + listed
            + ". Ask for each: returning it, or keeping it on the truck? Record a return with action 'remove' "
            + "and reason 'returned'. For one that is kept, offer to make it part of this truck's standard load "
            + "(action 'set_standard')."
    }

    /// `phrase` with its first letter in capitals, to open a sentence: "The van list is empty".
    static func capitalised(_ phrase: String) -> String {
        phrase.prefix(1).uppercased() + phrase.dropFirst()
    }

    /// The members sentences are built from besides the table's, for the same tests.
    var sentencePhrases: [String] {
        [listNoun, stockName, log, person, aboard, placeNoun, this, comeFrom, cameFrom, notFrom, shouldHold,
         putNoun, screen, useGloss, handoverGloss, handoverNotSent]
    }

    /// Every phrase, for tests and guards that need to look at all of them at once.
    var allPhrases: [String] {
        [location, list, putVerb, putThere, takenVerb, takenFrom, usualFigure, setByOffice, setByList,
         handover, title]
    }
}
