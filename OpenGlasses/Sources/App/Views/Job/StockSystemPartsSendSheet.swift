import SwiftUI

/// The parts step (Plan MM P4): the parts noted for a business's own stock system on one job, or
/// on a premises day's list, read back with a stepper per line and one Send for the batch. A tap
/// on Send is the person's yes (`StockUseConfirmation.person(.screen)`); Not now keeps them on the
/// job, unsent. Lines already on their way, sent or kept on the phone are shown with where they
/// stand. Vendor-neutral: the system's name comes from the connection.
struct StockSystemPartsSendSheet: View {
    @ObservedObject var parts: StockSystemPartsUsed
    let scope: StagedStockUseEntry.Scope
    let jobNumber: String?
    /// The sheet closed: sent, kept for later, or nothing to do.
    let onDone: () -> Void

    @State private var result: String?

    private var waiting: [StagedStockUseEntry] { parts.awaiting(in: scope) }
    private var others: [StagedStockUseEntry] { parts.entries(in: scope).filter { !$0.isAwaitingConfirmation } }
    private var system: String { parts.system }

    var body: some View {
        NavigationStack {
            List {
                if let question = parts.question(for: scope) {
                    Section {
                        Text(question).font(.headline)
                    }
                } else if case .notOffered(let reason) = parts.offer(for: scope), !waiting.isEmpty {
                    Section {
                        Label(reason.sentence(system: system), systemImage: "tray.and.arrow.up")
                    }
                }
                if !waiting.isEmpty {
                    Section {
                        ForEach(waiting) { entry in
                            PartsStepRow(parts: parts, entry: entry)
                                .swipeActions {
                                    Button(role: .destructive) {
                                        parts.discard([entry.id])
                                    } label: {
                                        Label("Discard", systemImage: "trash")
                                    }
                                }
                        }
                    } header: {
                        Text("Waiting to send")
                    } footer: {
                        Text("\(system)'s figures don't change until these are sent. Swipe a line to discard it: it stays on the job's record as not sent.")
                    }
                }
                if !others.isEmpty {
                    Section {
                        ForEach(others) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.use.name)
                                Text(Self.stateLine(entry, system: system)).font(.caption).foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    } header: {
                        Text("Already handled")
                    }
                }
                let lines = parts.rowLines(for: scope)
                if !lines.isEmpty {
                    Section {
                        ForEach(lines, id: \.self) { Text($0).font(.footnote) }
                    }
                }
                if let result {
                    Section { Text(result).font(.footnote) }
                }
            }
            .ogFormStyle()
            .navigationTitle("Parts used")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now") { onDone() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send to \(system)") {
                        let outcome = parts.confirm(scope, by: .person(.screen), jobNumber: jobNumber)
                        result = outcome.sentence
                        if outcome.queued > 0 || waiting.isEmpty { onDone() }
                    }
                    .disabled(waiting.isEmpty || !parts.offer(for: scope).isOffered)
                }
            }
        }
    }

    static func stateLine(_ entry: StagedStockUseEntry, system: String) -> String {
        switch entry.delivery.state {
        case .staged: return String(localized: "Waiting to send")
        case .queued: return String(localized: "Waiting for a connection")
        case .sent: return String(localized: "Sent to \(system)")
        case .notSent, .needsAttention: return entry.delivery.sentence ?? String(localized: "Not sent")
        }
    }
}

/// One line waiting to send, with its stepper. The stepper moves by what the item takes, never to
/// an amount the system would refuse, and never to nothing: Discard takes a line off.
private struct PartsStepRow: View {
    @ObservedObject var parts: StockSystemPartsUsed
    let entry: StagedStockUseEntry

    var body: some View {
        let stepper = parts.stepper(for: entry)
        let quantity = entry.use.quantity
        Stepper {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.use.name)
                    if entry.reason != nil {
                        Text("Written off as damaged").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 12)
                Text(verbatim: VanStockRow.figure(quantity, unit: entry.use.unit)).monospacedDigit()
            }
        } onIncrement: {
            parts.setQuantity(stepper.up(quantity), for: entry)
        } onDecrement: {
            parts.setQuantity(stepper.down(quantity), for: entry)
        }
        .frame(minHeight: OGMetrics.minTouchTarget)
    }
}

/// Where a job's parts for the system stand, on its page (Plan MM P4): the row's lines, and the
/// parts step for any still waiting. Nothing while the job noted none.
struct StockSystemJobPartsCard: View {
    @ObservedObject var parts: StockSystemPartsUsed
    let sessionID: String
    let jobNumber: String?
    @State private var reviewing = false

    var body: some View {
        let lines = parts.rowLines(for: .job(sessionID))
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(lines, id: \.self) { Text($0).font(.footnote) }
                Button(parts.awaiting(in: .job(sessionID)).isEmpty ? "Show parts" : "Review and send…") {
                    reviewing = true
                }
                .frame(minHeight: OGMetrics.minTouchTarget)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
            .sheet(isPresented: $reviewing) {
                StockSystemPartsSendSheet(parts: parts, scope: .job(sessionID), jobNumber: jobNumber) {
                    reviewing = false
                }
            }
        }
    }
}
