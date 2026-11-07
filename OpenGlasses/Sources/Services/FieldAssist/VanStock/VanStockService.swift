import Foundation

/// What a technician says about the van, turned into movements and a read-back (Plan IH §3).
///
/// The tool parses arguments and the screen shows rows; this is the one place a spoken line is
/// matched, recorded and answered, so the voice and the phone cannot disagree about what a load or
/// a use means. Nothing here touches the network.
@MainActor
final class VanStockService {

    static let shared = VanStockService()

    /// One spoken line: "four flame sensors, part 62-23543-01".
    struct Line: Equatable {
        var part: String?
        var description: String?
        var quantity: Int?
        var unit: String?
        var code: String?
        /// The technician said this is a different part from the similar line already on the van.
        /// Only its number or its code may then match; its description starts a new line.
        var asNew: Bool

        init(part: String? = nil, description: String? = nil, quantity: Int? = nil,
             unit: String? = nil, code: String? = nil, asNew: Bool = false) {
            self.part = part?.trimmingCharacters(in: .whitespacesAndNewlines).vanStockNonEmpty
            self.description = description?.trimmingCharacters(in: .whitespacesAndNewlines).vanStockNonEmpty
            self.quantity = quantity
            self.unit = unit?.trimmingCharacters(in: .whitespacesAndNewlines).vanStockNonEmpty
            self.code = code?.trimmingCharacters(in: .whitespacesAndNewlines).vanStockNonEmpty
            self.asNew = asNew
        }

        /// What to call the line when nothing on the van matches it.
        var reference: String { part ?? description ?? "that code" }
    }

    /// The job that is open, when one is.
    struct Job: Equatable {
        let sessionID: String
        let reference: String?
    }

    /// A model that retries must not load four sensors twice: the same write inside this many
    /// seconds is one write.
    static let duplicateWindow: TimeInterval = 10

    private let store: VanStockStore
    private let verify: @MainActor (String) -> TaskPart
    private let partsIndex: @MainActor () -> VaultPartsIndex
    private let activeJob: @MainActor () -> Job?
    private let now: () -> Date
    private let calendar: Calendar
    private let makeID: () -> String
    /// The open job's own record of what came off the van (Plan IH P4): told of a use, of uses an
    /// undo took back, and of a part that did not come from the van.
    private let jobUses: JobUses

    /// How a use reaches the job it was recorded on.
    @MainActor
    struct JobUses {
        var record: @MainActor (VanStockUse) -> Void
        var remove: @MainActor (Set<String>) -> Void
        /// False when there is no job open to say it about.
        var notFromVan: @MainActor (String) -> Bool
        /// The names of the parts on the open job that still have no stock entry.
        var unrecorded: @MainActor () -> [TaskPart]

        static let none = JobUses(record: { _ in }, remove: { _ in }, notFromVan: { _ in false }, unrecorded: { [] })
        static let shared = JobUses(
            record: { FieldSessionService.shared.recordVanStockUse($0) },
            remove: { FieldSessionService.shared.removeVanStockUses(movementIDs: $0) },
            notFromVan: { FieldSessionService.shared.markNotFromVan(part: $0) },
            unrecorded: { FieldSessionService.shared.unrecordedVanParts })
    }

    private var lastWrite: (signature: String, at: Date, answer: String)?

    init(store: VanStockStore? = nil,
         verify: (@MainActor (String) -> TaskPart)? = nil,
         partsIndex: (@MainActor () -> VaultPartsIndex)? = nil,
         activeJob: (@MainActor () -> Job?)? = nil,
         now: @escaping () -> Date = Date.init,
         calendar: Calendar = .current,
         makeID: @escaping () -> String = { UUID().uuidString },
         jobUses: JobUses? = nil) {
        self.store = store ?? .shared
        self.verify = verify ?? { FieldSessionService.shared.verifyPart($0) }
        self.partsIndex = partsIndex ?? { FieldSessionService.shared.partsIndex }
        self.activeJob = activeJob ?? {
            FieldSessionService.shared.activeSession.map { Job(sessionID: $0.id, reference: $0.jobReference) }
        }
        self.now = now
        self.calendar = calendar
        self.makeID = makeID
        // A service built for a test with its own store speaks to no job unless it is given one.
        self.jobUses = jobUses ?? (store == nil ? .shared : .none)
    }

    private var composer: VanStockAnswerComposer { VanStockAnswerComposer(now: now(), calendar: calendar) }

    private static let unreadable = "The van stock list on this phone could not be read, so nothing "
        + "was looked up or changed. Tell the technician; do not guess what is on the van."

    // MARK: - Reading

    func check(_ line: Line) -> String {
        guard !store.isUnreadable else { return Self.unreadable }
        let log = store.log
        guard !log.isEmpty else { return composer.emptyVan() }
        switch match(line, in: log) {
        case .one(let item): return composer.check(item, level: log.level(of: item.id))
        case .several(let items): return composer.candidates(items, levels: log.levels)
        case .none: return composer.notCarried(line.reference)
        }
    }

    func low() -> String {
        guard !store.isUnreadable else { return Self.unreadable }
        let log = store.log
        guard !log.isEmpty else { return composer.emptyVan() }
        let levels = log.levels
        return composer.low(log.lowItems.map { (item: $0, level: levels[$0.id] ?? VanStockLevel(itemID: $0.id)) })
    }

    // MARK: - Writing

    func load(_ lines: [Line], source: VanStockMovement.Source = .spoken) -> String {
        write("load", lines) { log, line, batch, at in
            let quantity = line.quantity ?? 1
            guard quantity >= 1 else { return ("Nothing loaded for \(line.reference): the quantity has to be at least 1.", nil) }
            switch self.target(line, in: &log, batch: batch, at: at, source: source, mayCreate: true) {
            case .failure(let message): return (message, nil)
            case .success(let found):
                let before = log.level(of: found.item.id)
                let job = self.activeJob()
                log.record(.loaded, itemID: found.item.id, quantity: quantity, at: at, batch: batch,
                           source: source, id: self.makeID(), jobSessionID: job?.sessionID,
                           jobReference: job?.reference)
                return (self.composer.loaded(found.item, quantity: quantity, before: before,
                                             after: log.level(of: found.item.id), created: found.created),
                        "\(found.item.phrase(quantity)) put on the van")
            }
        }
    }

    func use(_ lines: [Line], source: VanStockMovement.Source = .spoken) -> String {
        write("use", lines) { log, line, batch, at in
            let quantity = line.quantity ?? 1
            guard quantity >= 1 else { return ("Nothing recorded for \(line.reference): the quantity has to be at least 1.", nil) }
            switch self.target(line, in: &log, batch: batch, at: at, source: source, mayCreate: false) {
            case .failure(let message): return (message, nil)
            case .success(let found):
                let before = log.level(of: found.item.id)
                let job = self.activeJob()
                let movement = log.record(.used, itemID: found.item.id, quantity: quantity, at: at, batch: batch,
                                          source: source, id: self.makeID(), jobSessionID: job?.sessionID,
                                          jobReference: job?.reference)
                if job != nil, let movement {
                    self.jobUses.record(VanStockUse(id: movement.id, number: found.item.number,
                                                    description: found.item.description, quantity: quantity,
                                                    unit: found.item.unit, verified: found.item.verified, at: at))
                }
                return (self.composer.used(found.item, quantity: quantity, before: before,
                                           after: log.level(of: found.item.id), jobReference: job?.reference),
                        "\(found.item.phrase(quantity)) taken off the van" + (job?.reference.map { " for job \($0)" } ?? ""))
            }
        }
    }

    func remove(_ lines: [Line], reason: VanStockMovement.RemovalReason,
                source: VanStockMovement.Source = .spoken) -> String {
        write("remove:\(reason.rawValue)", lines) { log, line, batch, at in
            let quantity = line.quantity ?? 1
            guard quantity >= 1 else { return ("Nothing removed for \(line.reference): the quantity has to be at least 1.", nil) }
            switch self.target(line, in: &log, batch: batch, at: at, source: source, mayCreate: false) {
            case .failure(let message): return (message, nil)
            case .success(let found):
                let before = log.level(of: found.item.id)
                log.record(.removed, itemID: found.item.id, quantity: quantity, at: at, batch: batch,
                           source: source, id: self.makeID(), reason: reason)
                return (self.composer.removed(found.item, quantity: quantity, reason: reason, before: before,
                                              after: log.level(of: found.item.id)),
                        "\(found.item.phrase(quantity)) taken off the van (\(reason.rawValue))")
            }
        }
    }

    func count(_ lines: [Line], source: VanStockMovement.Source = .spoken) -> String {
        write("count", lines) { log, line, batch, at in
            guard let quantity = line.quantity else { return ("Say how many \(line.reference) were counted.", nil) }
            guard quantity >= 0 else { return ("Nothing counted for \(line.reference): a count cannot be below zero.", nil) }
            switch self.target(line, in: &log, batch: batch, at: at, source: source, mayCreate: true) {
            case .failure(let message): return (message, nil)
            case .success(let found):
                log.record(.counted, itemID: found.item.id, quantity: quantity, at: at, batch: batch,
                           source: source, id: self.makeID())
                let after = log.level(of: found.item.id)
                return (self.composer.counted(found.item, after: after, created: found.created),
                        "\(found.item.name) counted: \(after.onHand) on the van")
            }
        }
    }

    /// Take back the most recent batch.
    func undo(source: VanStockMovement.Source = .spoken) -> String {
        guard !store.isUnreadable else { return Self.unreadable }
        lastWrite = nil
        let at = now()
        let undone = store.update { $0.undoLastBatch(at: at, batch: self.makeID(), source: source, makeID: self.makeID) }
        guard let undone = undone ?? nil else { return composer.nothingToUndo() }
        let uses = Set(undone.movements.filter { $0.kind == .used }.map(\.id))
        if !uses.isEmpty { jobUses.remove(uses) }
        return Self.saying(composer.undone(undone, items: store.log.items), ["the last van stock entry taken back"])
    }

    // MARK: - The job's own account

    /// Parts on the open job's finished tasks with no stock entry, for the model to ask about.
    func unrecorded() -> String {
        let parts = jobUses.unrecorded()
        guard !parts.isEmpty else {
            return "Every part on this job's finished tasks has a van stock entry, or was said not to have come off the van."
        }
        return "No van stock entry on this job for " + VanStockReconciler.named(parts)
            + ". Ask the technician whether each came off the van; do not record a use they did not confirm."
    }

    /// The technician said a part on the open job did not come off the van.
    func notFromVan(_ line: Line) -> String {
        guard let part = line.part else { return "Say which part did not come off the van, by its part number." }
        guard jobUses.notFromVan(part) else { return "There is no job open to say that about. Nothing was changed." }
        let number = VaultPartsIndex.normalise(part)
        return Self.saying("Noted: \(number) did not come off the van on this job. The van list is unchanged.",
                           ["\(number) noted as not from the van"])
    }

    // MARK: - From the screen

    /// Whether there is an entry to take back.
    var canUndo: Bool { !store.isUnreadable && store.log.canUndo }

    /// A count typed on the Van Stock screen. False when nothing was recorded.
    @discardableResult
    func setCount(itemID: String, to quantity: Int) -> Bool {
        lastWrite = nil
        let at = now()
        let batch = makeID()
        let recorded = store.update { log in
            log.record(.counted, itemID: itemID, quantity: quantity, at: at, batch: batch,
                       source: .typed, id: self.makeID()) != nil
        }
        return recorded ?? false
    }

    /// Changes typed on the Van Stock screen, as one batch. A new part number is looked up again,
    /// so a corrected number is not left marked as verified on the strength of the old one.
    @discardableResult
    func edit(itemID: String, _ changes: [VanStockLog.Change]) -> Bool {
        lastWrite = nil
        let at = now()
        let batch = makeID()
        let changed = store.update { log -> Bool in
            var any = false
            for change in changes {
                any = log.edit(itemID: itemID, change, at: at, batch: batch, source: .typed, id: self.makeID()) || any
                if case .number(let number) = change {
                    let verified = number.map { self.verify($0).verified } ?? false
                    any = log.edit(itemID: itemID, .verified(verified), at: at, batch: batch,
                                   source: .typed, id: self.makeID()) || any
                }
            }
            return any
        }
        return changed ?? false
    }

    // MARK: - The shift (Plan IH P5)

    /// What it takes to bring the van back to its standard load.
    func topUp() -> String {
        guard !store.isUnreadable else { return Self.unreadable }
        let log = store.log
        guard !log.isEmpty else { return composer.emptyVan() }
        let shortfalls = VanStockHandover.topUp(log)
        let measured = VanStockHandover.hasStandards(log)
        guard !shortfalls.isEmpty else {
            return measured ? "Nothing to top up: every line is at its standard load."
                            : "Nothing has run out. No standard load is set for this van, so there is nothing to top up to."
        }
        let listed = shortfalls.map { shortfall in
            shortfall.short.map { "\(shortfall.item.phrase($0)) (\(shortfall.onHand) on board)" }
                ?? "\(shortfall.item.name) (\(shortfall.onHand) on board)"
        }
        let lead = measured ? "\(shortfalls.count) to top up"
                            : "No standard load is set for this van; \(shortfalls.count) have run out or are below minimum"
        return "\(lead): " + listed.joined(separator: "; ") + "."
    }

    /// "Topped up everything except the flame sensors": every short line but those is brought to
    /// its standard load, as one batch that one undo takes back.
    func loadToStandard(except exceptions: [Line] = [], source: VanStockMovement.Source = .spoken) -> String {
        guard !store.isUnreadable else { return Self.unreadable }
        lastWrite = nil
        let at = now()
        let batch = makeID()
        var skipped: [VanStockItem] = []
        var unmatched: [String] = []
        var filled = 0
        store.update { log in
            for line in exceptions {
                switch self.match(line, in: log) {
                case .one(let item): skipped.append(item)
                case .several(let items): skipped.append(contentsOf: items)
                case .none: unmatched.append(line.reference)
                }
            }
            let left = Set(skipped.map(\.id))
            for shortfall in VanStockHandover.topUp(log) {
                guard let short = shortfall.short, !left.contains(shortfall.item.id) else { continue }
                log.record(.loaded, itemID: shortfall.item.id, quantity: short, at: at, batch: batch,
                           source: source, id: self.makeID())
                filled += 1
            }
        }
        guard VanStockHandover.hasStandards(store.log) else {
            return "No standard load is set for this van, so there is nothing to top up to. Nothing was changed."
        }
        var lines = [filled == 0 ? "Nothing was short of its standard load, so nothing was loaded."
                                 : "\(filled) \(filled == 1 ? "line" : "lines") brought to the standard load."]
        if !skipped.isEmpty { lines.append("Left as they were: " + skipped.map(\.name).joined(separator: "; ") + ".") }
        if !unmatched.isEmpty {
            lines.append("Not on the van list, so not treated as an exception: " + unmatched.joined(separator: "; ") + ".")
        }
        if filled > 0 { lines.append("The technician can say 'undo that' to take the whole top-up back.") }
        return Self.saying(lines.joined(separator: " "),
                           filled > 0 ? ["\(filled) \(filled == 1 ? "line" : "lines") brought to the standard load"] : [])
    }

    /// Set what the van should carry of one line. Set by the technician, so it is this truck's own.
    func setStandard(_ line: Line) -> String {
        guard !store.isUnreadable else { return Self.unreadable }
        guard let quantity = line.quantity, quantity >= 0 else { return "Say how many \(line.reference) the van should carry." }
        lastWrite = nil
        let at = now()
        let batch = makeID()
        var answer = composer.notOnVan(line.reference)
        var done: [String] = []
        store.update { log in
            switch self.match(line, in: log) {
            case .several(let items): answer = self.composer.candidates(items, levels: log.levels)
            case .none: break
            case .one(let item):
                log.edit(itemID: item.id, .standard(quantity == 0 ? nil : quantity, setBy: .van), at: at,
                         batch: batch, source: .spoken, id: self.makeID())
                answer = quantity == 0 ? "\(item.name) has no standard load now."
                                       : "The standard load for this truck is now \(item.phrase(quantity))."
                done = [quantity == 0 ? "no standard load for \(item.name) now"
                                      : "the standard load set to \(item.phrase(quantity))"]
            }
        }
        return Self.saying(answer, done)
    }

    /// What `send_to_base` says before anything is staged: parts with no stock entry, and the
    /// day's extras still on board. Nil when there is nothing left to ask.
    func handoverQuestions() -> String? {
        var lines: [String] = []
        let parts = jobUses.unrecorded()
        if !parts.isEmpty {
            lines.append("Before the stock is sent: there is no van stock entry on the open job for "
                + VanStockReconciler.named(parts) + ". Ask whether each came off the van.")
        }
        let extras = VanStockHandover.surplus(store.log, since: VanStockHandover.shiftStart(store.log, now: now(), calendar: calendar))
        if !extras.isEmpty {
            lines.append("Loaded this shift and still on board beyond the standard load: "
                + extras.map { $0.item.phrase($0.extra) }.joined(separator: "; ")
                + ". Ask for each: returning it, or keeping it on the truck? Record a return with action 'remove' "
                + "and reason 'returned'. For one that is kept, offer to make it part of this truck's standard load "
                + "(action 'set_standard').")
        }
        guard !lines.isEmpty else { return nil }
        lines.append("Then call send_to_base again with 'answered' true.")
        return lines.joined(separator: " ")
    }

    /// The text that goes to base with the workbook.
    func handoverMessage() -> String {
        VanStockHandover.message(store.log, van: store.van, now: now(), calendar: calendar)
    }

    /// Take a van over from a workbook: its list replaces the phone's.
    func takeOver(_ takeover: VanStockHandover.Takeover) {
        lastWrite = nil
        store.replace(with: takeover.log, van: takeover.van)
    }

    /// Read a workbook as a van to take over.
    func takeover(from sheets: [XLSXReader.Sheet]) -> Result<VanStockHandover.Takeover, VanStockSheet.Failure> {
        VanStockHandover.takeover(from: sheets, at: now(), batch: makeID(), makeID: makeID)
    }

    /// Apply base's baseline to this van's standards, as one batch.
    @discardableResult
    func apply(baseline changes: [VanStockHandover.BaselineChange], takingBaseFigure: Set<String> = []) -> Bool {
        lastWrite = nil
        let at = now()
        let batch = makeID()
        let before = store.log
        store.update { log in
            VanStockHandover.apply(changes, to: &log, takingBaseFigure: takingBaseFigure, at: at,
                                   batch: batch, makeID: self.makeID)
        }
        return store.log != before
    }

    // MARK: - The spreadsheet

    /// The van's stock as a workbook, written to a temporary file for the share sheet. The caller
    /// removes it once the share is finished. Nil when there is nothing readable to export.
    func exportFile() -> URL? {
        guard !store.isUnreadable else { return nil }
        let at = now()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("van-stock-export-\(makeID())", isDirectory: true)
        let url = folder.appendingPathComponent(VanStockSheet.fileName(exportedAt: at, calendar: calendar))
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try VanStockSheet.data(store.log, van: store.van, exportedAt: at, calendar: calendar)
                .write(to: url, options: [.atomic, .completeFileProtection])
            return url
        } catch {
            return nil
        }
    }

    /// Apply a reviewed workbook as one batch, so one undo takes the whole import back.
    @discardableResult
    func apply(_ proposal: VanStockSheet.Proposal, keepingPhoneFigure: Set<String> = []) -> Bool {
        lastWrite = nil
        let at = now()
        let batch = makeID()
        let before = store.log
        store.update { log in
            VanStockSheet.apply(proposal, to: &log, keepingPhoneFigure: keepingPhoneFigure, at: at,
                                batch: batch, verify: { self.verify($0) }, makeID: self.makeID)
        }
        return store.log != before
    }

    /// A replacement was asked for: the van now knows something is coming. Nil when the part is
    /// not a line on the van — an order never creates one.
    @discardableResult
    func noteOrdered(number: String, quantity: Int, requestID: String) -> String? {
        guard !store.isUnreadable else { return nil }
        let at = now()
        let batch = makeID()
        let recorded = store.update { log -> VanStockLevel? in
            guard case .one(let item) = VanStockMatcher(items: log.items, partsIndex: self.partsIndex())
                .match(number: number) else { return nil }
            log.record(.ordered, itemID: item.id, quantity: max(quantity, 1), at: at, batch: batch,
                       source: .spoken, id: self.makeID(), requestID: requestID)
            return log.level(of: item.id)
        } ?? nil
        return recorded.map { "The van list now shows \($0.onOrder) asked for and not yet loaded." }
    }

    // MARK: - One write

    /// One spoken write: `apply` returns, per line, its answer and — when it changed the van — what
    /// the reply must say was done (`saying(_:_:)`).
    private func write(_ action: String, _ lines: [Line],
                       _ apply: (inout VanStockLog, Line, _ batch: String, _ at: Date) -> (answer: String, done: String?)) -> String {
        guard !store.isUnreadable else { return Self.unreadable }
        guard !lines.isEmpty else { return "Say which part, and how many." }

        let at = now()
        let signature = action + "|" + lines.map {
            "\($0.part ?? "")~\($0.description ?? "")~\($0.quantity.map(String.init) ?? "")~\($0.unit ?? "")~\($0.code ?? "")~\($0.asNew)"
        }.joined(separator: "|")
        if let last = lastWrite, last.signature == signature,
           at.timeIntervalSince(last.at) < Self.duplicateWindow {
            return "Already recorded a moment ago, not recorded twice. " + last.answer
        }

        let batch = makeID()
        let answers = store.update { log in lines.map { apply(&log, $0, batch, at) } } ?? []
        let answer = Self.saying(answers.map(\.answer).joined(separator: "\n"), answers.compactMap(\.done))
        lastWrite = (signature, at, answer)
        return answer
    }

    // MARK: - What the reply says was done (Plan KR P7)

    /// Opens the line a stock change's result ends with.
    static let sayPrefix = "Say: "

    /// `answer`, ending with the one line the reply must carry when something on the van changed
    /// (Plan KR P7, owner decision 7). In the partner's run a part came off the van in the same
    /// breath as a question about a test; the stock was recorded and the reply answered only the
    /// question. Worded like `set_job_reference`'s confirmation: what was done, said as done.
    /// Nothing changed, nothing to say: `answer` unchanged.
    static func saying(_ answer: String, _ done: [String]) -> String {
        guard !done.isEmpty else { return answer }
        return answer + "\n" + sayPrefix + done.joined(separator: "; ")
            + ". Put this in the reply, whatever else the technician asked this turn."
    }

    // MARK: - Finding or making the line

    private struct Found {
        let item: VanStockItem
        let created: Bool
    }

    private enum Target {
        case success(Found)
        case failure(String)
    }

    private func match(_ line: Line, in log: VanStockLog, byWords: Bool = true) -> VanStockMatcher.Match {
        let matcher = VanStockMatcher(items: log.items, partsIndex: partsIndex())
        guard byWords else { return matcher.match(number: Self.number(in: line), code: line.code) }
        return matcher.match(number: line.part, description: line.description, code: line.code)
    }

    /// The line a write is about. Only a load or a count may make a new one; anything else that
    /// matches nothing changes nothing.
    private func target(_ line: Line, in log: inout VanStockLog, batch: String, at: Date,
                        source: VanStockMovement.Source, mayCreate: Bool) -> Target {
        switch match(line, in: log, byWords: !(mayCreate && line.asNew)) {
        case .several(let items):
            return .failure(composer.candidates(items, levels: log.levels))
        case .one(let item):
            if let raw = line.unit {
                guard let unit = VanStockUnit(spoken: raw) else { return .failure(Self.unknownUnit(raw)) }
                guard unit == item.unit else {
                    return .failure("\(item.name) is counted in \(item.unit.rawValue), not \(unit.rawValue). Nothing was changed.")
                }
            }
            attach(line, to: item, in: &log, batch: batch, at: at, source: source)
            return .success(Found(item: log.item(id: item.id) ?? item, created: false))
        case .none:
            guard mayCreate else { return .failure(composer.notOnVan(line.reference)) }
            return create(line, in: &log, batch: batch)
        }
    }

    /// What a write can add to a line it matched: a number it did not have, a scanned code, and a
    /// fresh look in the manuals for a number that was not verified last time.
    private func attach(_ line: Line, to item: VanStockItem, in log: inout VanStockLog, batch: String,
                        at: Date, source: VanStockMovement.Source) {
        if item.number == nil, let number = Self.number(in: line) {
            let checked = verify(number)
            log.edit(itemID: item.id, .number(checked.number), at: at, batch: batch, source: source, id: makeID())
            log.edit(itemID: item.id, .verified(checked.verified), at: at, batch: batch, source: source, id: makeID())
        } else if let number = item.number, !item.verified, verify(number).verified {
            log.edit(itemID: item.id, .verified(true), at: at, batch: batch, source: source, id: makeID())
        }
        if let code = line.code {
            log.edit(itemID: item.id, .addCode(code), at: at, batch: batch, source: .scanned, id: makeID())
        }
    }

    private func create(_ line: Line, in log: inout VanStockLog, batch: String) -> Target {
        let number = Self.number(in: line)
        // Words given where a number goes are the description.
        let described = line.description ?? (number == nil ? line.part : nil)
        guard number != nil || described != nil else {
            if line.code != nil {
                return .failure("That code is not on the van list yet. Ask the technician what the part is, "
                    + "then record it again with the code and its part number or description.")
            }
            return .failure("Say what the part is: a part number, a description, or both.")
        }
        var unit = VanStockUnit.each
        if let raw = line.unit {
            guard let spoken = VanStockUnit(spoken: raw) else { return .failure(Self.unknownUnit(raw)) }
            unit = spoken
        }
        let checked = number.map(verify)
        let item = log.addItem(id: makeID(),
                               number: checked?.number ?? number,
                               description: described ?? checked?.partDescription ?? "",
                               unit: unit,
                               codes: line.code.map { [$0] } ?? [],
                               verified: checked?.verified ?? false,
                               batch: batch)
        return .success(Found(item: item, created: true))
    }

    /// The part number in a line, when what was given is one. A part number has no spaces and at
    /// least one digit; words in its place are a description.
    private static func number(in line: Line) -> String? {
        guard let part = line.part, !part.contains(where: \.isWhitespace),
              part.contains(where: \.isNumber) else { return nil }
        let normalised = VaultPartsIndex.normalise(part)
        return normalised.isEmpty ? nil : normalised
    }

    private static func unknownUnit(_ raw: String) -> String {
        "'\(raw)' is not a unit the van list keeps. Use one of: "
            + VanStockUnit.allCases.map(\.rawValue).joined(separator: ", ") + ". Nothing was changed."
    }
}

private extension String {
    var vanStockNonEmpty: String? { isEmpty ? nil : self }
}
