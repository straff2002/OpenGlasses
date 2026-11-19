import Foundation

/// Where a stock list is kept: a kind from a closed list, and the list's own name (Plan MK §1).
///
/// The kind is what sentences are built from, because a sentence needs a noun whose grammar it
/// knows: "on" a vehicle, "in" a building. The name is a label that works on its own, in a title,
/// a row or a handover message. A free word such as "the cellar" is a name on one of these kinds,
/// never a kind of its own. Pure.
struct StockPlace: Codable, Equatable, Sendable {

    /// What sort of place it is (Plan MK §1). Van is the default, because field technicians are
    /// who the feature was built for.
    enum Kind: String, Codable, CaseIterable, Sendable {
        case van
        case truck
        case store
        case warehouse
        /// The neutral catch-all (Plan MK Decision 10). It names no place: "22 in stock", "the
        /// stock list". It covers a factory, a workshop, a storeroom or a bar, with the list's name
        /// saying which one.
        case stock

        /// The default for a list nobody has given a place.
        static let `default` = Kind.van

        /// Which of the van stock steps the place offers (Plan MK §5).
        var family: Family {
            switch self {
            case .van, .truck: return .vehicle
            case .store, .warehouse, .stock: return .premises
            }
        }

        /// A kind read strictly: nil for anything that is not one of the five, so the profile path
        /// can drop an unknown kind by name instead of guessing (Plan MK §2). Spaces and case are
        /// forgiven, nothing else.
        init?(strict raw: String?) {
            guard let raw else { return nil }
            self.init(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }

        /// A kind read leniently, as a workbook's or a stored list's is: anything this build does
        /// not know, from a newer build, reads as van (Plan MK §1), so an unknown kind never makes a
        /// list unreadable.
        init(lenient raw: String?) {
            self = Kind(strict: raw) ?? .default
        }

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self.init(lenient: raw)
        }
    }

    /// The two families a kind belongs to (Plan MK §5). A vehicle is loaded for a route and comes
    /// back; premises keep their stock where it is, with no job to tag a use to.
    enum Family: String, Codable, Sendable {
        case vehicle
        case premises
    }

    var kind: Kind
    /// The list's own name, "Truck 4" or "Main street store". Nil or empty when nobody named it.
    var name: String?

    init(kind: Kind = .default, name: String? = nil) {
        self.kind = kind
        self.name = name
    }

    var family: Family { kind.family }

    /// The words the model hears about this place (Plan MK §3).
    var wording: StockPlaceWording { StockPlaceWording(kind) }
}

/// Which place a list is kept in, and who decided (Plan MK §2). Pure.
///
/// One order, in one place: the organisation's profile, which sets and locks it; then the list's
/// own choice; then van. The profile's kind is never written into the list, so removing the
/// profile gives the list's own choice back.
enum StockPlaceSetting {

    struct Resolved: Equatable, Sendable {
        let kind: StockPlace.Kind
        /// The organisation's profile set it, so the person keeping the list cannot change it.
        let isLocked: Bool
    }

    /// `profile` is the profile's raw value, strictly read: absent or unknown is no setting at
    /// all, never a guess. `list` is the list's own stored place.
    static func resolve(profile: String?, list: StockPlace.Kind?) -> Resolved {
        if let locked = StockPlace.Kind(strict: profile) {
            return Resolved(kind: locked, isLocked: true)
        }
        return Resolved(kind: list ?? .default, isLocked: false)
    }
}
