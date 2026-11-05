import Foundation

/// How Settings › Field Assist lays out its trades: one collapsible row per trade, holding that
/// trade's switch and its own settings, so a technician sees their trade's settings and not every
/// trade's at once. Pure.
///
/// - **Order:** the trades the technician has come first — on in the selection in force, or
///   declared by a vault they can open — then the rest, each group in `FieldTrade.allCases` order.
/// - **Open on arrival:** the trades the technician has. Every other row starts collapsed.
/// - **Settings shown:** a trade's own settings follow `FieldTradeGate.isAvailable`, as the
///   separate sections did — hidden while some other trade is on and this one is off.
enum FieldTradeAccordion {
    struct Row: Equatable, Identifiable, Sendable {
        let trade: FieldTrade
        /// On in the selection in force (technician, organisation or vault).
        let isOn: Bool
        /// A vault this phone can open declares the trade.
        let hasVault: Bool
        /// The trade's own settings are offered (`FieldTradeGate.isAvailable`).
        let showsSettings: Bool

        var id: String { trade.rawValue }
        /// The technician works in this trade: it comes first and opens on arrival.
        var isTheirs: Bool { isOn || hasVault }
    }

    /// Bundled vaults that predate manifest `trades` and are still the trade's vault. Their
    /// manifests deliberately declare none — a declared trade becomes the vault layer of the
    /// selection — so ownership is read here, for layout only, and never changes what is in force.
    static let undeclaredVaultTrades: [String: FieldTrade] = [
        "refrigeration": .refrigerationHVAC,
    ]

    /// The trades among the vaults this phone can open: each vault's declared `trades`, else the
    /// trade its bundled id implies. Once each, in `allCases` order.
    static func ownedTrades(unlockedVaults: [(id: String, trades: [String]?)]) -> [FieldTrade] {
        var raw: [String] = []
        for vault in unlockedVaults {
            if let declared = vault.trades, !declared.isEmpty {
                raw.append(contentsOf: declared)
            } else if let implied = undeclaredVaultTrades[vault.id] {
                raw.append(implied.rawValue)
            }
        }
        return FieldTrade.known(raw)
    }

    /// One row per trade: the technician's trades first, then the rest.
    static func rows(activeTrades: [FieldTrade], ownedTrades: [FieldTrade]) -> [Row] {
        let all = FieldTrade.allCases.map { trade in
            Row(trade: trade,
                isOn: activeTrades.contains(trade),
                hasVault: ownedTrades.contains(trade),
                showsSettings: FieldTradeGate.isAvailable(trade, activeTrades: activeTrades))
        }
        return all.filter(\.isTheirs) + all.filter { !$0.isTheirs }
    }

    /// The rows open when the screen first appears: the technician's trades.
    static func initiallyExpanded(_ rows: [Row]) -> Set<FieldTrade> {
        Set(rows.filter(\.isTheirs).map(\.trade))
    }
}
