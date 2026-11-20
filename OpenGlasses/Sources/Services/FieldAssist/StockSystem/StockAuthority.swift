import Foundation

/// A connection on this phone to a business's own stock system, as far as deciding who answers
/// needs it (Plan MM §3): which connector, and which of the system's locations are this place.
/// The key and everything else about the connection live with the connection (Plan MM P2).
struct StockSystemConnection: Equatable, Sendable {
    /// The connector's own id: a lowercase token, compared to nothing but other connector ids.
    let connectorID: String
    /// The system's locations chosen on the phone as this place ("Which stock is here?").
    let locationIDs: [String]

    init(connectorID: String, locationIDs: [String]) {
        self.connectorID = connectorID
        self.locationIDs = locationIDs
    }
}

/// Who holds the count for a place (Plan MM §1). Pure.
///
/// `phone` is the phone's own movement log, as before this plan, and the default. `system` is a
/// connected system and the locations of it that are this place. It is the one thing `van_stock`
/// asks about who answers.
enum StockAuthority: Equatable, Sendable {
    case phone
    case system(connectorID: String, locationIDs: [String])

    /// What the phone's own list for the place is while this authority holds (Decision 3).
    enum PhoneList: Equatable, Sendable {
        /// The list counts: every movement is recorded on it.
        case counting
        /// The list is kept, read-only, as the previous list, and counts again when the
        /// connection is removed. Nothing is merged and nothing is lost.
        case previous
    }

    /// Who answers, in Plan MM §1's order:
    ///
    /// 1. The organisation's office route ceiling (`organizationFieldServiceRoute = office`):
    ///    the office connects outside systems and supplies stock through Plan HF, so a direct
    ///    connection's snapshot is retired and the phone answers as before (Decision 2).
    /// 2. Otherwise the connection on this phone, once it names a connector and at least one
    ///    location. A connection with no location chosen yet answers for nothing.
    /// 3. Otherwise the phone.
    static func resolve(officeRoute: Bool, connection: StockSystemConnection?) -> StockAuthority {
        if officeRoute { return .phone }
        guard let connection else { return .phone }
        let connector = connection.connectorID.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen = Set<String>()
        let locations = connection.locationIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !connector.isEmpty, !locations.isEmpty else { return .phone }
        return .system(connectorID: connector, locationIDs: locations)
    }

    /// Whether a connected system holds the count.
    var isSystem: Bool {
        if case .system = self { return true }
        return false
    }

    /// The system's locations that are this place; empty for the phone.
    var locationIDs: [String] {
        if case .system(_, let ids) = self { return ids }
        return []
    }

    /// What the phone's own list is under this authority. Exactly one of the two, always.
    var phoneList: PhoneList {
        switch self {
        case .phone: return .counting
        case .system: return StockSystemPolicy.phoneListWhileSystemHolds
        }
    }
}
