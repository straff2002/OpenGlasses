import Foundation

/// The words a dictation turn is likely to contain, handed to Apple Speech as contextual strings.
///
/// The wake-word listener has always passed its phrases as hints; dictation passed nothing, so the
/// recogniser that hears "Carrier 58MVC" or a part number had no idea those words were likely even
/// when the job, the vault and the van all named them. This builds that list from what the app
/// already holds.
///
/// Pure: no `UserDefaults`, no singletons. The caller assembles an `Input` from live state every
/// turn, so a job change applies to the next turn.
///
/// **What is deliberately not here.** `Input` has no field for a customer's name, a site address,
/// a serial number or any free text the office wrote about the site. The recogniser does not need
/// them, and a list of customers' names handed to a recogniser that may run on a server is a
/// disclosure nobody asked for. A new source belongs in `Input` only if it is a word about the
/// work, never about the person or place it is done for.
struct DictationVocabulary: Equatable, Sendable {

    /// The most hints a single turn carries. Apple documents no hard limit, but a long list slows
    /// the recogniser's start and dilutes the hints that matter. Trimmed from the generic end:
    /// the job's own words come first and survive.
    static let cap = 250

    /// A hint longer than this is a sentence, not a word to listen for — a van-stock description
    /// written as a note, a manual title with an edition statement. Dropped rather than truncated,
    /// because half a phrase is not a phrase anyone says.
    static let maxEntryLength = 64

    /// Everything the list may be built from. Every field may be empty.
    struct Input: Sendable {
        /// The machine the session believes is in front of the technician.
        var activeEquipment: EquipmentIdentity?
        /// The machines the active job says are on site (make, model and where it sits).
        var jobEquipment: [KnownEquipment]
        /// What is on the van: part numbers and their names.
        var vanStock: [VanStockItem]
        /// The vaults in play: each vault's name and its manuals' titles.
        var vaults: [VaultManifest]
        /// The enabled personas' wake phrases, so a mid-turn "hey …" still matches.
        var wakePhrases: [String]
        /// The trades in force; each contributes its glossary, last.
        var trades: [FieldTrade]

        init(activeEquipment: EquipmentIdentity? = nil,
             jobEquipment: [KnownEquipment] = [],
             vanStock: [VanStockItem] = [],
             vaults: [VaultManifest] = [],
             wakePhrases: [String] = [],
             trades: [FieldTrade] = []) {
            self.activeEquipment = activeEquipment
            self.jobEquipment = jobEquipment
            self.vanStock = vanStock
            self.vaults = vaults
            self.wakePhrases = wakePhrases
            self.trades = trades
        }
    }

    /// The hints, in priority order, ready for `contextualStrings`.
    let phrases: [String]

    init(_ input: Input) {
        phrases = Self.build(input)
    }

    /// Order: active equipment, job equipment, van stock, vault titles, wake phrases, glossary.
    /// Trimmed, single characters and over-long entries dropped, de-duplicated case-insensitively
    /// keeping the first spelling, then capped.
    static func build(_ input: Input) -> [String] {
        var candidates: [String] = []

        if let equipment = input.activeEquipment {
            if let stated = equipment.statedModel { candidates.append(stated) }
            candidates.append(equipment.modelToken)
            // The heading carries the alternate spellings of the model ("SLP99UH 090XV60CK /
            // -090-060C"); its model-like tokens are the useful part, not its prose.
            candidates += VaultModelIndex.modelLikeTokens(in: equipment.heading)
        }

        for machine in input.jobEquipment {
            if let make = machine.make, let model = machine.model {
                candidates.append("\(make) \(model)")
            }
            candidates += [machine.model, machine.make, machine.label].compactMap { $0 }
        }

        for item in input.vanStock {
            if let number = item.number { candidates.append(number) }
            candidates.append(item.description)
        }

        for vault in input.vaults {
            candidates.append(vault.name)
            candidates += vault.documents.map(\.title)
        }

        candidates += input.wakePhrases

        for trade in input.trades {
            candidates += glossary(for: trade)
        }

        return Array(normalised(candidates).prefix(cap))
    }

    /// Trim, drop what is not a hint, and keep the first spelling of each.
    static func normalised(_ candidates: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in candidates {
            let phrase = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard phrase.count > 1, phrase.count <= maxEntryLength else { continue }
            if seen.insert(phrase.lowercased()).inserted { out.append(phrase) }
        }
        return out
    }

    // MARK: - After recognition

    /// A transcript as the trades in force read it (Plan KD P0): with the electrical trade, every
    /// spoken AWG aught size is written as printed ("four aught" → "4/0"), so the model and
    /// `table_lookup` see the size the technician said rather than a "4" and a word. Nothing else
    /// is rewritten, and without the electrical trade nothing at all.
    static func postProcess(_ transcript: String, trades: [FieldTrade]) -> String {
        guard trades.contains(.electrical) else { return transcript }
        return AWGSize.rewritingSpokenSizes(in: transcript)
    }

    // MARK: - Trade glossaries

    /// The words a technician in this trade says that a general recogniser hears badly:
    /// refrigerant names, component names, gauges and ratings said aloud, and the abbreviations
    /// said letter by letter. A modest table in code, not a dictionary.
    static func glossary(for trade: FieldTrade) -> [String] {
        switch trade {
        case .refrigerationHVAC: return refrigerationHVACGlossary
        case .electrical: return electricalGlossary
        }
    }

    static let refrigerationHVACGlossary: [String] = [
        // Refrigerants
        "R-410A", "R-32", "R-22", "R-454B", "R-134a", "R-404A", "R-407C", "R-448A", "R-449A",
        "R-290", "R-744", "R-1234yf", "R-513A",
        // Measurements
        "superheat", "subcooling", "static pressure", "inches of water column", "delta T",
        "microns", "CFM", "BTU", "SEER", "tonnage",
        // Components
        "compressor", "condenser", "evaporator", "contactor", "run capacitor", "start capacitor",
        "dual run capacitor", "blower motor", "ECM motor", "PSC motor", "flame sensor", "hot surface igniter",
        "inducer motor", "pressure switch", "limit switch", "rollout switch", "heat exchanger",
        "reversing valve", "defrost board", "control board", "thermostat", "line set",
        "suction line", "liquid line", "filter drier", "Schrader valve", "manifold gauge",
        "micron gauge", "condensate pump", "float switch",
        // Equipment and valves said letter by letter
        "TXV", "EEV", "RTU", "AHU", "VRF", "mini split", "heat pump", "furnace",
    ]

    static let electricalGlossary: [String] = [
        // Wire gauges and sizes said aloud
        "AWG", "14 gauge", "12 gauge", "10 gauge", "8 gauge", "6 gauge", "4 gauge", "2 gauge",
        "1/0", "2/0", "3/0", "4/0", "kcmil", "MCM",
        // The aught sizes as printed in some books and as said aloud (Plan KD P0)
        "00", "000", "0000", "one aught", "two aught", "three aught", "four aught", "double aught",
        "triple aught", "quadruple aught",
        // Cable and conduit
        "Romex", "NM-B", "THHN", "MC cable", "EMT", "conduit", "junction box",
        // Protection said letter by letter
        "GFCI", "AFCI", "RCD", "RCBO", "MCB",
        // Breakers and panels
        "single pole breaker", "double pole breaker", "main breaker", "panelboard", "subpanel",
        "load center", "bus bar", "disconnect",
        // Earthing and bonding
        "neutral", "ground", "bonding", "grounding electrode",
        // Motor control
        "contactor", "overload relay", "VFD",
        // Testing and supply
        "megger", "insulation resistance", "continuity", "voltage drop", "amperage",
        "line to line", "line to neutral", "single phase", "three phase",
        "120 volt", "208 volt", "240 volt", "480 volt", "kVA", "transformer",
    ]
}
