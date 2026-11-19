import Foundation

/// What a lookup of a line's part number said, and which book answered (Plan MK §4).
///
/// Three states, not two. Before this a stored `false` meant both "searched and not found" and
/// "never searched", because a line loaded with no job open had no vault to look in. `notFound` is
/// only ever recorded for a lookup that ran against a vault with a parts table or manuals; with no
/// book the line stays `notChecked`. A found number is not proof of stock, only that the number
/// exists in that book. Never a gate.
struct VanStockVerification: Codable, Equatable, Sendable {

    enum State: String, Codable, Sendable {
        case found
        case notFound = "not_found"
        case notChecked = "not_checked"

        /// A state this build does not know, from a newer build, reads as not checked, so it can
        /// neither claim a number nor put a mark on it.
        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = State(rawValue: raw) ?? .notChecked
        }
    }

    let state: State
    /// The name of the vault that answered, "Supplier catalogue". Nil for `notChecked`, and for a
    /// `found` carried over from a stored `true` that never said where.
    let vault: String?

    init(state: State, vault: String? = nil) {
        self.state = state
        let trimmed = vault?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.vault = state == .notChecked || trimmed?.isEmpty != false ? nil : trimmed
    }

    static let notChecked = VanStockVerification(state: .notChecked)
    static func found(in vault: String?) -> VanStockVerification { .init(state: .found, vault: vault) }
    static func notFound(in vault: String?) -> VanStockVerification { .init(state: .notFound, vault: vault) }

    /// A stored `verified` Bool, read as Plan MK §4 decides: `true` was found, and `false` is not
    /// checked, because today's `false` cannot say whether anything was searched.
    init(legacy verified: Bool) {
        self = verified ? .found(in: nil) : .notChecked
    }

    var isFound: Bool { state == .found }

    // MARK: - As one stored value

    /// The value an `edited` movement records for it: "found", "not_found:Supplier catalogue".
    /// The state never holds a colon, so everything after the first one is the vault's name.
    var storedValue: String {
        vault.map { "\(state.rawValue):\($0)" } ?? state.rawValue
    }

    /// Read a movement's recorded value back. Today's "true" and "false" read as the legacy Bool
    /// does, so an old log's verification edits still undo correctly; anything else unknown is not
    /// checked.
    init(storedValue raw: String?) {
        guard let raw else { self = .notChecked; return }
        switch raw {
        case "true": self = .init(legacy: true)
        case "false": self = .init(legacy: false)
        default:
            let parts = raw.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard let first = parts.first, let state = State(rawValue: String(first)) else {
                self = .notChecked
                return
            }
            self = .init(state: state, vault: parts.count > 1 ? String(parts[1]) : nil)
        }
    }
}
