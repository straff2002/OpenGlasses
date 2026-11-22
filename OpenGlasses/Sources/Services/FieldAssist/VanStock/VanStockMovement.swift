import Foundation

/// One dated fact about one line of van stock (Plan IH §1).
///
/// The log is append-only: a mistake is taken back by a `reversed` movement that names it, never
/// by removing it. Movements carry no free text, so the log holds part data and job references and
/// nothing about a person.
struct VanStockMovement: Codable, Equatable, Identifiable, Sendable {

    enum Kind: String, Codable, Sendable {
        /// Onto the van. Adds.
        case loaded
        /// Fitted on a job. Subtracts.
        case used
        /// Off the van for another reason. Subtracts.
        case removed
        /// A stocktake. Sets the level.
        case counted
        /// A replacement asked for. No effect on the level; closed by later loads, oldest first.
        case ordered
        /// An attribute of the line changed. No effect on the level.
        case edited
        /// Takes one earlier movement back.
        case reversed
        /// What a folded history left behind: the level as it stood, carried forward.
        case opening
        /// Taken out and thrown away, for a `WasteReason` (Plan MY §3). Subtracts. Its own kind,
        /// never a removal, so a report counts waste apart from returns (Decision 3).
        case wasted
    }

    enum Source: String, Codable, Sendable {
        case spoken
        case typed
        case scanned
        case sheet
        case handover
    }

    enum RemovalReason: String, Codable, CaseIterable, Sendable {
        case returned
        case damaged
        case lent
        case other
    }

    /// Why stock was wasted (Plan MY §3). A closed list, so a report can count each reason.
    enum WasteReason: String, Codable, CaseIterable, Sendable {
        case expired
        /// The fridge went out of range.
        case coldChain = "cold_chain"
        case drawnUpNotGiven = "drawn_up_not_given"
        /// Broken or dropped.
        case broken
        /// The doses left in an opened vial that had to be thrown out.
        case openedVialDiscarded = "opened_vial_discarded"
        case other

        /// "cold chain", for a sentence.
        var spoken: String {
            switch self {
            case .expired: return "expired"
            case .coldChain: return "cold chain"
            case .drawnUpNotGiven: return "drawn up and not given"
            case .broken: return "broken or dropped"
            case .openedVialDiscarded: return "opened vial discarded"
            case .other: return "other"
            }
        }
    }

    /// The attributes of a line an `edited` movement can name.
    enum Attribute: String, Codable, Sendable {
        case number
        case description
        case unit
        case minimum
        case standard
        case bin
        case code
        case verified
        /// Doses per carton (Plan MY §2).
        case dosesPerCarton = "doses_per_carton"
    }

    let id: String
    let itemID: String
    let kind: Kind
    /// In thousandths of the line's unit (`StockQuantity`). Zero for `edited` and `reversed`.
    let quantity: StockQuantity
    let at: Date
    /// One spoken sentence, or one imported sheet, is one batch.
    let batch: String
    let source: Source
    /// The job a use was fitted on, or a load was put on for.
    var jobSessionID: String?
    var jobReference: String?
    var reason: RemovalReason?
    /// The parts request an order belongs to, when this phone made it.
    var requestID: String?
    /// The movement a `reversed` takes back.
    var reverses: String?
    var attribute: Attribute?
    var oldValue: String?
    var newValue: String?
    /// For `opening` only: whether the carried level was last established by a count, and whether
    /// the line was unreliable when the history was folded.
    var openingCounted: Bool?
    var openingUnreliable: Bool?
    /// The lot this movement is about (Plan MY §1), one of its line's. Nil for a line with no
    /// lots and for every movement recorded before lots existed, which fold as they always did.
    var lotID: String?
    /// For `wasted` only: why.
    var wasteReason: WasteReason?

    init(id: String = UUID().uuidString,
         itemID: String,
         kind: Kind,
         quantity: StockQuantity = .zero,
         at: Date,
         batch: String,
         source: Source,
         jobSessionID: String? = nil,
         jobReference: String? = nil,
         reason: RemovalReason? = nil,
         requestID: String? = nil,
         reverses: String? = nil,
         attribute: Attribute? = nil,
         oldValue: String? = nil,
         newValue: String? = nil,
         openingCounted: Bool? = nil,
         openingUnreliable: Bool? = nil,
         lotID: String? = nil,
         wasteReason: WasteReason? = nil) {
        self.id = id
        self.itemID = itemID
        self.kind = kind
        self.quantity = quantity
        self.at = at
        self.batch = batch
        self.source = source
        self.jobSessionID = jobSessionID
        self.jobReference = jobReference
        self.reason = reason
        self.requestID = requestID
        self.reverses = reverses
        self.attribute = attribute
        self.oldValue = oldValue
        self.newValue = newValue
        self.openingCounted = openingCounted
        self.openingUnreliable = openingUnreliable
        self.lotID = lotID
        self.wasteReason = wasteReason
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, quantity, at, batch, source, reason, reverses, attribute
        case itemID = "item_id"
        case jobSessionID = "job_session_id"
        case jobReference = "job_reference"
        case requestID = "request_id"
        case oldValue = "old_value"
        case newValue = "new_value"
        case openingCounted = "opening_counted"
        case openingUnreliable = "opening_unreliable"
        case lotID = "lot_id"
        case wasteReason = "waste_reason"
    }

    /// Whether this kind changes how many are on the van.
    var changesLevel: Bool {
        switch kind {
        case .loaded, .used, .removed, .counted, .opening, .wasted: return true
        case .ordered, .edited, .reversed: return false
        }
    }
}
