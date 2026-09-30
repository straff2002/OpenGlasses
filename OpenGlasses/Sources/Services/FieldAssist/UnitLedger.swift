import Foundation

/// The machines a job covered, and which work was done on which (Plan GB P2).
///
/// The session already kept the pieces — every unit it was on (`visitedUnits`) and the continuity
/// scope each task was recorded under (`taskEquipmentScopes`) — and nothing put them together, so
/// job 1011's two furnaces printed as one. This is the putting together: one entry per scope, in
/// the order the job reached them, each with the tasks recorded under it. A scope that has work and
/// no identified machine is still a unit — an unidentified one — because the work happened on
/// something.
///
/// Pure: built from the session's own values, so the same session always yields the same ledger.
struct UnitLedger: Equatable {

    struct Unit: Codable, Equatable {
        /// 1-based, in the order the job reached the unit.
        let number: Int
        /// The continuity scope the unit's work was recorded under.
        let scope: String
        /// What the technician said the model was. Nil for a unit nobody identified.
        let statedModel: String?
        /// The vault section it matched, when that is not simply what was said.
        let vaultSection: String?
        /// How it matched the vault: exact, alias, near — or nil, not in the vault.
        let vaultMatch: String?
        let serial: String?
        /// The tasks recorded on this unit, in record order.
        let taskIds: [String]

        enum CodingKeys: String, CodingKey {
            case number, scope, serial
            case statedModel = "stated_model"
            case vaultSection = "vault_section"
            case vaultMatch = "vault_match"
            case taskIds = "task_ids"
        }

        /// "SLP99UH090XV48C (vault section SLP99UH090XV48CK)", "SLP99UH070XB36B (not in the
        /// vault)", or "Unidentified unit".
        var label: String {
            guard let statedModel else { return "Unidentified unit" }
            if let vaultSection { return "\(statedModel) (vault section \(vaultSection))" }
            if vaultMatch == nil { return "\(statedModel) (not in the vault)" }
            return statedModel
        }

        /// "Unit 2: SLP99UH090XV48C (vault section SLP99UH090XV48CK), serial 5820A12345."
        var headerLine: String {
            var line = "Unit \(number): \(label)"
            if let serial, !serial.isEmpty { line += ", serial \(serial)" }
            return line + "."
        }
    }

    let units: [Unit]

    /// The unit a task was recorded on, when there is more than one unit to choose from.
    func unit(forTask id: String) -> Unit? { units.first { $0.taskIds.contains(id) } }

    /// Whether the job covered several machines — the only case in which anything is grouped.
    var isMultiUnit: Bool { units.count >= 2 }

    init(units: [Unit]) { self.units = units }

    init(session: FieldSession) {
        self.init(visitedUnits: session.visitedUnits, tasks: session.tasks,
                  taskScopes: session.taskEquipmentScopes, currentScope: session.continuityScope,
                  currentEquipment: session.equipment)
    }

    init(visitedUnits: [VisitedUnit], tasks: [FieldSession.Task], taskScopes: [String: String],
         currentScope: String, currentEquipment: EquipmentIdentity? = nil) {
        // Scopes in the order the job reached them: a unit's first sighting, or the first task
        // recorded under a scope nobody identified.
        var firstSeen: [String: Date] = [:]
        var identity: [String: VisitedUnit] = [:]
        for unit in visitedUnits {
            // The latest entry for a scope is the one in force — a correction rewrites the unit it
            // is on rather than adding one.
            identity[unit.continuityScope] = unit
            firstSeen[unit.continuityScope] = min(firstSeen[unit.continuityScope] ?? unit.firstSeenAt,
                                                  unit.firstSeenAt)
        }
        var tasksByScope: [String: [String]] = [:]
        for task in tasks {
            let scope = taskScopes[task.id] ?? "initial"
            tasksByScope[scope, default: []].append(task.id)
            if identity[scope] == nil {
                firstSeen[scope] = min(firstSeen[scope] ?? task.createdAt, task.createdAt)
            }
        }
        // A current machine the visited list somehow lacks (a session restored from before the
        // list existed) is still the machine the current scope's work was done on.
        if let currentEquipment, identity[currentScope] == nil {
            identity[currentScope] = VisitedUnit(identity: currentEquipment, continuityScope: currentScope,
                                                 firstSeenAt: currentEquipment.recognisedAt)
            firstSeen[currentScope] = min(firstSeen[currentScope] ?? currentEquipment.recognisedAt,
                                          currentEquipment.recognisedAt)
        }
        let scopes = firstSeen.keys
            .filter { identity[$0] != nil || !(tasksByScope[$0] ?? []).isEmpty }
            .sorted { (firstSeen[$0]!, $0) < (firstSeen[$1]!, $1) }
        units = scopes.enumerated().map { index, scope in
            let seen = identity[scope]
            return Unit(number: index + 1, scope: scope,
                        statedModel: seen?.stated,
                        vaultSection: seen?.vaultSectionIfDifferent,
                        vaultMatch: seen?.matchKind,
                        serial: seen?.serial,
                        taskIds: tasksByScope[scope] ?? [])
        }
    }
}

extension VisitedUnit {
    /// What was said, or — for a unit recorded before the stated model was kept — the model the
    /// record has always printed.
    var stated: String { statedModel ?? modelToken }

    /// The vault section, when it is worth saying: not for an exact match, which says the same thing
    /// twice, and not for a unit out of the vault, which has none.
    var vaultSectionIfDifferent: String? {
        guard let section = vaultSection, matchKind != nil else { return nil }
        return EquipmentRecognition.normalised(section) == EquipmentRecognition.normalised(stated)
            ? nil : section
    }

    /// The kind of match as recorded, with a legacy unit (no statedModel) read as the exact match
    /// it was always treated as.
    var matchKind: String? {
        if statedModel == nil { return EquipmentIdentity.VaultMatch.Kind.exact.rawValue }
        return vaultMatchKind
    }
}
