import Foundation

/// Plan GM P0 — property-list encoding for glance surfaces, with a hard byte budget per consumer.
///
/// Apple documents no byte limit for `updateApplicationContext` or `sendMessage`, so the budgets
/// are self-imposed and conservative; the real ceiling is an owed device measurement. Over budget
/// is refused with a reason, never truncated silently — except a `places` card, which drops
/// trailing rows to fit and records how many it dropped.
enum GlanceSurfaceCodec {

    /// The most a consumer will take.
    struct Budget: Equatable, Sendable {
        /// The whole `surfaces` value.
        let surfacesBytes: Int
        /// One `RouteDelta`.
        let deltaBytes: Int

        /// The watch: 48 KB for the context value, 8 KB for a delta.
        static let watch = Budget(surfacesBytes: 48 * 1024, deltaBytes: 8 * 1024)
    }

    /// Why an encode was refused.
    enum Refusal: Error, Equatable, CustomStringConvertible {
        case overBudget(bytes: Int, limit: Int)
        case encodingFailed

        var description: String {
            switch self {
            case .overBudget(let bytes, let limit):
                return "The surface is \(bytes) bytes, over the \(limit)-byte budget."
            case .encodingFailed:
                return "The surface could not be encoded."
            }
        }
    }

    /// An encoded set, and the set exactly as encoded (rows may have been dropped).
    struct Encoded: Equatable {
        let data: Data
        let set: GlanceSurfaceSet
    }

    // MARK: - Surfaces

    static func encode(_ set: GlanceSurfaceSet, budget: Budget = .watch) -> Result<Encoded, Refusal> {
        guard let data = plist(set) else { return .failure(.encodingFailed) }
        if data.count <= budget.surfacesBytes { return .success(Encoded(data: data, set: set)) }

        // Only a list of nearby places shrinks: the trailing rows are the least relevant.
        guard let current = set.current, case .places(let card) = current.kind, !card.rows.isEmpty else {
            return .failure(.overBudget(bytes: data.count, limit: budget.surfacesBytes))
        }
        var rows = card.rows
        var smallest = data.count
        while !rows.isEmpty {
            rows.removeLast()
            var surface = current
            surface.kind = .places(PlacesCard(query: card.query, rows: rows, wearer: card.wearer,
                                              droppedRows: card.droppedRows + (card.rows.count - rows.count)))
            var trimmed = set
            trimmed.current = surface
            guard let attempt = plist(trimmed) else { return .failure(.encodingFailed) }
            smallest = attempt.count
            if attempt.count <= budget.surfacesBytes { return .success(Encoded(data: attempt, set: trimmed)) }
        }
        return .failure(.overBudget(bytes: smallest, limit: budget.surfacesBytes))
    }

    static func decode(_ data: Data) -> GlanceSurfaceSet? {
        try? PropertyListDecoder().decode(GlanceSurfaceSet.self, from: data)
    }

    // MARK: - Deltas

    static func encode(_ delta: RouteDelta, budget: Budget = .watch) -> Result<Data, Refusal> {
        guard let data = plist(delta) else { return .failure(.encodingFailed) }
        guard data.count <= budget.deltaBytes else {
            return .failure(.overBudget(bytes: data.count, limit: budget.deltaBytes))
        }
        return .success(data)
    }

    static func decodeDelta(_ data: Data) -> RouteDelta? {
        try? PropertyListDecoder().decode(RouteDelta.self, from: data)
    }

    // MARK: -

    private static func plist<T: Encodable>(_ value: T) -> Data? {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try? encoder.encode(value)
    }
}
