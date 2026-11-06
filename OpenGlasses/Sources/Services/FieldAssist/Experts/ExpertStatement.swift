import Foundation

extension EscalationContact.Rate {
    /// The rate's billing grain without its money (Plan KM P4): what a job's record keeps.
    var billingRule: ExpertBillingRule {
        ExpertBillingRule(minimumMinutes: minimumMinutes, roundingMinutes: roundingMinutes)
    }
}

extension EscalationContact {
    /// A contracted expert's billing grain, minutes only; nil for staff and for an unrated entry.
    /// What the call and the reply put on the job, so the technician's side never handles the rate.
    var billingRule: ExpertBillingRule? { kind == .contracted ? rate?.billingRule : nil }
}

/// One expert's month, for the organisation's records (Plan KM §6, P4): one row per job — the
/// date, the job reference, the minutes, the billable minutes, the rate and the amount, and any
/// difference between the expert's reply and the call the phone saw — and a total. It is what the
/// expert invoices against.
///
/// **For the device owner or the office only** (decision 6): it is the one place a rate and an
/// amount appear. Built from the jobs on this phone (each job's own `ExpertTime`), and figured at
/// the rate on this phone's list as it stands now. **The amount is a figure only**: the app never
/// takes or sends a payment, and the statement says so. A staff expert's statement has minutes and
/// no rate, billable minutes or amount — their time is for the job's costing.
///
/// Pure: the jobs, the list entry and the calendar are arguments.
struct ExpertStatement: Equatable, Sendable {

    struct Row: Equatable, Sendable {
        let date: Date
        let sessionId: String
        let jobReference: String?
        let minutes: Int
        let billableMinutes: Int?
        let amount: Decimal?
        let source: ExpertTime.Source
        let reconciliation: ExpertTimeReconciliation
    }

    let expertId: String
    let expertName: String
    let kind: EscalationContact.Kind
    let month: CalendarMonth
    /// The organisation the statement is kept for, when this phone knows its name.
    let organisation: String?
    /// The contracted expert's rate on the list now; nil for staff, and for one the list no longer
    /// rates.
    let rate: EscalationContact.Rate?
    let rows: [Row]
    let preparedAt: Date

    var totalMinutes: Int { rows.reduce(0) { $0 + $1.minutes } }

    /// Nil when no row has billable minutes (a staff expert, or no rule known).
    var totalBillableMinutes: Int? {
        let billed = rows.compactMap(\.billableMinutes)
        return billed.isEmpty ? nil : billed.reduce(0, +)
    }

    /// Nil when no row has an amount.
    var totalAmount: Decimal? {
        let amounts = rows.compactMap(\.amount)
        return amounts.isEmpty ? nil : amounts.reduce(0, +)
    }

    var differences: Int { rows.filter { $0.reconciliation.isDifference }.count }

    // MARK: - Building

    /// The experts any job on this phone has time for, by id, with the snapshot the jobs give.
    static func experts(in sessions: [FieldSession]) -> [ExpertSnapshot] {
        var seen: [String: ExpertSnapshot] = [:]
        var order: [String] = []
        for session in uniqued(sessions).sorted(by: { $0.startedAt < $1.startedAt }) {
            for time in ExpertTime.build(session: session) where seen[time.expertId] == nil {
                seen[time.expertId] = ExpertSnapshot(id: time.expertId, name: time.expertName, kind: time.kind)
                order.append(time.expertId)
            }
        }
        return order.compactMap { seen[$0] }
    }

    /// The months an expert has time in, newest first.
    static func months(expertId: String, sessions: [FieldSession], calendar: Calendar) -> [CalendarMonth] {
        let months = uniqued(sessions).flatMap { session in
            ExpertTime.build(session: session).filter { $0.expertId == expertId }.map { CalendarMonth($0.dated, calendar: calendar) }
        }
        return Array(Set(months)).sorted(by: >)
    }

    /// - Parameters:
    ///   - expert: the jobs' snapshot of the expert (id, name, kind).
    ///   - listed: the expert's entry on this phone's list now, for the rate; nil when they are no
    ///     longer listed.
    static func build(expert: ExpertSnapshot, listed: EscalationContact?, month: CalendarMonth,
                      sessions: [FieldSession], organisation: String?, calendar: Calendar,
                      preparedAt: Date) -> ExpertStatement {
        let kind = expert.kind
        // Only a contracted expert has a rate, and only the one the list gives now.
        let rate = kind == .contracted && listed?.kind == .contracted ? listed?.rate : nil
        var rows: [Row] = []
        for session in uniqued(sessions) {
            for time in ExpertTime.build(session: session)
            where time.expertId == expert.id && month.contains(time.dated, calendar: calendar) {
                // The job's own billable minutes (the rule kept when the time arrived), else the
                // list's rule now, for a contracted expert whose job never had one.
                let billable = kind == .contracted ? (time.billableMinutes ?? rate?.billingRule.billableMinutes(for: time.minutes)) : nil
                rows.append(Row(date: time.dated, sessionId: session.id, jobReference: session.jobReference,
                                minutes: time.minutes, billableMinutes: billable,
                                amount: billable.flatMap { minutes in rate.map { amount(minutes: minutes, perHour: $0.perHour) } },
                                source: time.source, reconciliation: time.reconciliation))
            }
        }
        rows.sort { ($0.date, $0.sessionId) < ($1.date, $1.sessionId) }
        return ExpertStatement(expertId: expert.id, expertName: expert.name, kind: kind, month: month,
                               organisation: organisation, rate: rate, rows: rows, preparedAt: preparedAt)
    }

    /// Billable minutes at a rate per hour, to the cent (half up).
    static func amount(minutes: Int, perHour: Decimal) -> Decimal {
        var raw = Decimal(minutes) * perHour / 60
        var rounded = Decimal()
        NSDecimalRound(&rounded, &raw, 2, .plain)
        return rounded
    }

    /// "45.00": two places, a point, no grouping, whatever the phone's locale.
    static func money(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.roundingMode = .halfUp
        return formatter.string(from: value as NSDecimalNumber) ?? "\(value)"
    }

    private static func uniqued(_ sessions: [FieldSession]) -> [FieldSession] {
        var seen = Set<String>()
        return sessions.filter { seen.insert($0.id).inserted }
    }

    // MARK: - The document

    static let paymentNote = "The amount is a figure for the organisation's records and the expert's invoice. "
        + "The app never takes or sends a payment."
    static let basisNote = "Minutes are the expert's own clock from their time reply where they sent one, else the "
        + "call this phone saw. A difference between the two is shown, never settled by the app."

    var hasMoney: Bool { kind == .contracted }

    func document(calendar: Calendar) -> MinutesTableDocument {
        var lede: [String] = []
        if let organisation, !organisation.isEmpty { lede.append("For \(organisation)'s records.") }
        switch kind {
        case .staff:
            lede.append("Staff expert: minutes for the job's costing, with no rate and no amount.")
        case .contracted:
            if let rate {
                lede.append("Contracted expert. Rate: \(rate.currency) \(Self.money(rate.perHour)) an hour; "
                            + "at least \(rate.minimumMinutes) minutes a job, rounded up to \(rate.roundingMinutes) minutes.")
            } else {
                lede.append("Contracted expert. No rate on this phone's list, so no amount is figured.")
            }
        }
        lede.append("Prepared \(MinutesTableDocument.isoDay(preparedAt, calendar: calendar)), at the rate on this phone's list then.")
        lede.append(Self.basisNote)

        let currency = rate?.currency ?? ""
        var columns = ["Date", "Job", "Minutes"]
        if hasMoney { columns += ["Billable minutes", "Rate per hour", "Amount"] }
        columns.append("Check")
        let rows = rows.map { row -> [String] in
            var cells = [MinutesTableDocument.isoDay(row.date, calendar: calendar), row.jobReference ?? "",
                         String(row.minutes)]
            if hasMoney {
                cells += [MinutesTableDocument.minutes(row.billableMinutes),
                          rate.map { "\(currency) \(Self.money($0.perHour))" } ?? "",
                          row.amount.map { "\(currency) \(Self.money($0))" } ?? ""]
            }
            cells.append(row.reconciliation.statementNote)
            return cells
        }
        var total = ["Total", "\(self.rows.count) job\(self.rows.count == 1 ? "" : "s")", String(totalMinutes)]
        if hasMoney {
            total += [MinutesTableDocument.minutes(totalBillableMinutes), "",
                      totalAmount.map { "\(currency) \(Self.money($0))" } ?? ""]
        }
        total.append(differences == 0 ? "" : "\(differences) to check")
        return MinutesTableDocument(
            title: "Expert statement — \(expertName), \(month.title)", lede: lede, columns: columns, rows: rows,
            total: total, notes: hasMoney ? [Self.paymentNote] : ["The app never takes or sends a payment."])
    }

    var fileStem: String { MinutesTableDocument.fileStem(["statement", expertName, month.id]) }
}

/// Writes a statement into protected staging for the device owner's own share (Plan KM P4). The
/// Field Assist export family, released when the share ends, as the job's own files are.
@MainActor
enum ExpertStatementExport {
    enum Format: String, CaseIterable, Identifiable {
        case csv, pdf
        var id: String { rawValue }
    }

    static func stage(_ statement: ExpertStatement, format: Format, calendar: Calendar = .current,
                      coordinator: StagedExportCoordinator = .fieldSession) throws -> StagedExportLease {
        let document = statement.document(calendar: calendar)
        let data = format == .csv ? document.csvData : document.pdfData()
        do {
            let lease = try coordinator.makeLease(data: data, fileExtension: format.rawValue,
                                                  displayName: statement.fileStem + "." + format.rawValue,
                                                  fallbackName: "expert-statement." + format.rawValue)
            PrivacyLog.transfer(.fieldSessionExport, .exported, count: statement.rows.count)
            return lease
        } catch {
            PrivacyLog.transfer(.fieldSessionExport, .fileFailed, error: SafeErrorSummary(error))
            throw error
        }
    }
}
