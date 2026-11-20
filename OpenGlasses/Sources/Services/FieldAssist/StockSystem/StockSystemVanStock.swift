import Foundation

/// The book a system's figures are joined against (Plan MK §4's order: the open job's vault, else
/// the list's named vault, else none), with the name it is shown under.
struct StockSystemBook {
    let parts: VaultPartsIndex
    let name: String?
}

/// `van_stock` while a business's own system holds the place's count (Plan MM §5, P3).
///
/// Every answer is the system's figure from the last snapshot, with its as-of time, through
/// `StockSystemJoin` and `StockSystemAnswerComposer`. A use is noted on the phone
/// (`StagedStockUseStore`) and the system's count does not change: nothing here writes to the
/// phone's own list or to the system. Receiving, counting, standards, top-ups and the handover are
/// the system's, so they are refused; a sale is the till's. Vendor-neutral: the system's name comes
/// from the snapshot or the connection.
@MainActor
struct StockSystemVanStock {

    /// The job that is open, when one is.
    struct Job: Equatable {
        let sessionID: String
        let reference: String?
    }

    let snapshot: StockSystemSnapshot?
    /// The system's name, for every sentence.
    let system: String
    let connectorID: String
    /// The system's locations that are this place.
    let here: [String]
    let capabilities: StockSystemCapabilities?
    let staged: StagedStockUseStore
    let kind: StockPlace.Kind
    let job: Job?
    let book: StockSystemBook?
    let now: Date
    let calendar: Calendar
    let makeID: () -> String

    var wording: StockPlaceWording { StockPlaceWording(kind) }

    var composer: StockSystemAnswerComposer {
        StockSystemAnswerComposer(now: now, calendar: calendar, wording: wording, system: system)
    }

    // MARK: - Finding the line

    /// What a spoken line names in the system's figures.
    enum Resolution {
        /// One line, with how it joins the book.
        case one(StockSystemSnapshot.Line, StockSystemJoin.Outcome)
        /// Several fit, or one only sounds like it: asked about, never acted on.
        case several([StockSystemSnapshot.Line])
        /// The system does not carry it.
        case none(StockSystemJoin.Outcome)
    }

    /// A part number is joined across the book and the system (supersession both ways). Words
    /// are matched against the system's descriptions the way the phone's own list is matched
    /// (`VanStockMatcher`), and the line found is then joined by its own number.
    func resolve(_ line: VanStockService.Line, in snapshot: StockSystemSnapshot) -> Resolution {
        let join = StockSystemJoin(snapshot: snapshot, parts: book?.parts)
        if let number = Self.number(in: line) ?? line.code.flatMap(Self.numberText) {
            let outcome = join.join(number: number)
            if let found = outcome.line { return .one(found, outcome) }
            if Self.number(in: line) != nil { return .none(outcome) }
        }
        let items = snapshot.lines.map { snapshotLine in
            VanStockItem(id: snapshotLine.itemID, number: snapshotLine.part.map(VaultPartsIndex.normalise),
                         description: snapshotLine.description, unit: snapshotLine.unit ?? .each, createdBatch: "")
        }
        let matcher = VanStockMatcher(items: items, partsIndex: book?.parts ?? VaultPartsIndex(files: []))
        let byID = Dictionary(snapshot.lines.map { ($0.itemID, $0) }, uniquingKeysWith: { first, _ in first })
        switch matcher.match(description: line.description ?? line.part) {
        case .one(let item):
            guard let found = byID[item.id] else { return .none(.neither) }
            if let part = found.part {
                let outcome = join.join(number: part)
                if outcome.line?.itemID == found.itemID { return .one(found, outcome) }
            }
            return .one(found, .systemOnly(found, bookSearched: false))
        case .several(let items), .near(let items):
            return .several(items.compactMap { byID[$0.id] })
        case .none:
            return .none(.neither)
        }
    }

    /// The system's ids for what `line` names, for a check-now; empty when it names none.
    func itemIDs(for line: VanStockService.Line) -> [String] {
        guard let snapshot else { return [] }
        switch resolve(line, in: snapshot) {
        case .one(let found, _): return [found.itemID]
        case .several(let lines): return lines.map(\.itemID)
        case .none: return []
        }
    }

    /// The unit a spoken figure is read in: the system's line's, when it names one the phone keeps;
    /// otherwise the unit said; otherwise each. Writes nothing.
    func quantityUnit(for line: VanStockService.Line) -> (unit: VanStockUnit, name: String) {
        if let snapshot, case .one(let found, _) = resolve(line, in: snapshot), let unit = found.unit {
            return (unit, found.name)
        }
        return (line.unit.flatMap(VanStockUnit.init(spoken:)) ?? .each, line.reference)
    }

    // MARK: - Reading

    func check(_ line: VanStockService.Line) -> String {
        guard let snapshot else { return composer.noFigures() }
        switch resolve(line, in: snapshot) {
        case .one(let found, let outcome):
            return composer.check(outcome, in: snapshot, here: here, unsent: unsent(found.itemID))
        case .several(let lines):
            return composer.candidates(lines)
        case .none(let outcome):
            return composer.check(outcome, in: snapshot, here: here)
        }
    }

    func list(bin: String?) -> String {
        guard let snapshot else { return composer.noFigures() }
        return composer.list(snapshot, here: here, bin: bin)
    }

    func low() -> String {
        guard let snapshot else { return composer.noFigures() }
        return composer.low(in: snapshot, here: here)
    }

    /// What is noted and not yet sent for an item, in the scope in force.
    private func unsent(_ itemID: String) -> StockSystemAnswerComposer.Unsent? {
        guard let scope = scope else { return nil }
        let quantity = staged.entries(in: scope).filter { $0.use.itemID == itemID }
            .reduce(StockQuantity.zero) { $0 + $1.use.quantity }
        return quantity > .zero ? .init(quantity: quantity, state: .staged) : nil
    }

    // MARK: - Noting a use

    /// Where a use waits: the open job; at premises with no job open, the day's list; on a vehicle
    /// with no job open, nowhere, because every use from a vehicle belongs to a job.
    var scope: StagedStockUseEntry.Scope? {
        if let job { return .job(job.sessionID) }
        guard kind.family == .premises else { return nil }
        return .day(StagedStockUseStore.dayKey(now, calendar: calendar))
    }

    /// The reason the system keeps for a removal, or nil when it keeps none for it. Only damage
    /// is a reason a part leaves stock without being used; returned, lent and other are not the
    /// system's to record.
    func keptReason(for reason: VanStockMovement.RemovalReason) -> StockAdjustmentReason? {
        guard reason == .damaged, let kept = capabilities?.adjustmentReasons else { return nil }
        return [StockAdjustmentReason.damage, .waste].first { kept.contains($0) }
    }

    /// Note `lines` as used on the job (or the day's list), or as written off for `writeOff`.
    /// Each line is checked before it is noted: one the system does not carry, or a quantity the
    /// item cannot take, is refused with the reason and the rest are still noted. Returns the
    /// answer and what the reply must say was done.
    func use(_ lines: [VanStockService.Line], source: VanStockMovement.Source,
             writeOff: StockAdjustmentReason? = nil) -> (answer: String, done: [String]) {
        guard let snapshot else { return (composer.noFigures(), []) }
        guard let scope else { return (composer.useNeedsJob(), []) }
        guard !lines.isEmpty else { return ("Say which part, and how many.", []) }
        let call = makeID()
        var answers: [String] = []
        var entries: [StagedStockUseEntry] = []
        var done: [String] = []
        for line in lines {
            switch resolve(line, in: snapshot) {
            case .several(let candidates):
                answers.append(composer.candidates(candidates))
            case .none(let outcome):
                answers.append(composer.check(outcome, in: snapshot, here: here))
            case .one(let found, let outcome):
                let quantity = line.quantity ?? StockQuantity(whole: 1)
                let said = line.unit.flatMap(VanStockUnit.init(spoken:))
                if line.unit != nil, said == nil {
                    answers.append("'\(line.unit ?? "")' is not a unit kept on the phone. Nothing was noted.")
                    continue
                }
                if let said, let unit = found.unit, said != unit {
                    answers.append("\(system) keeps \(found.name) in \(unit.unitName), not \(said.unitName). Nothing was noted.")
                    continue
                }
                let unit = found.unit ?? said ?? .each
                if case .failure(let refusal) = StockSystemQuantityConversion.outgoing(
                    quantity, unit: unit, itemUnit: found.unit,
                    wholeNumbersOnly: capabilities?.wholeNumbersOnly ?? false, decimalPlaces: found.decimalPlaces) {
                    answers.append(composer.notStaged(found, refusal, quantity: quantity, unit: unit))
                    continue
                }
                let use = StagedStockUse(id: makeID(), itemID: found.itemID, part: found.part,
                                         description: found.description, quantity: quantity, unit: unit,
                                         verification: verification(outcome), source: Self.source(source))
                let location = here.first { found.level(at: $0) != nil } ?? here.first ?? ""
                entries.append(StagedStockUseEntry(scope: scope, jobReference: job?.reference, connectorID: connectorID,
                                                   locationID: location, use: use, reason: writeOff, stagedAt: now,
                                                   call: call))
                let onJob = job != nil
                if writeOff != nil {
                    answers.append(composer.stagedWrittenOff(quantity, of: found, jobReference: job?.reference, onJob: onJob))
                } else if onJob {
                    answers.append(composer.staged(quantity, of: found, jobReference: job?.reference))
                } else {
                    answers.append(composer.stagedForToday(quantity, of: found))
                }
                done.append("\(composer.phrase(found, quantity)) noted for \(system)"
                    + (onJob ? (job?.reference.map { " on job \($0)" } ?? " on this job") : " on today's list"))
            }
        }
        if !entries.isEmpty, !staged.stage(entries) {
            return (composer.notSaved(), [])
        }
        return (answers.joined(separator: "\n"), done)
    }

    /// Take back the last call's noted lines, before anything is sent.
    func undo() -> (answer: String, done: [String]) {
        guard let scope, let taken = staged.undoLastCall(in: scope), !taken.isEmpty else {
            return (composer.nothingToUnstage(), [])
        }
        return (composer.unstaged(taken), ["the last note for \(system) taken back"])
    }

    // MARK: - Pieces

    private func verification(_ outcome: StockSystemJoin.Outcome) -> VanStockVerification {
        switch outcome {
        case .inBoth: return .found(in: book?.name)
        case .systemOnly(_, let searched): return searched ? .notFound(in: book?.name) : .notChecked
        case .vaultOnly, .neither: return .notChecked
        }
    }

    private static func source(_ source: VanStockMovement.Source) -> StagedStockUse.Source {
        switch source {
        case .spoken: return .spoken
        case .scanned: return .scanned
        case .typed, .sheet, .handover: return .typed
        }
    }

    /// The part number in a line, when what was given is one: no spaces and at least one digit.
    private static func number(in line: VanStockService.Line) -> String? {
        line.part.flatMap(numberText)
    }

    private static func numberText(_ text: String) -> String? {
        guard !text.contains(where: \.isWhitespace), text.contains(where: \.isNumber) else { return nil }
        let normalised = VaultPartsIndex.normalise(text)
        return normalised.isEmpty ? nil : normalised
    }
}
