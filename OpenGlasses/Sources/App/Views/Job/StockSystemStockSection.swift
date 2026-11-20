import SwiftUI

/// Reads who holds the count from the connected stock system and redraws when it changes (Plan MM
/// P3): a connection made, its locations chosen, removed, or the office route arriving.
struct StockAuthorityReader<Content: View>: View {
    @ObservedObject var service: StockSystemService
    @ViewBuilder let content: (_ systemHolds: Bool) -> Content

    var body: some View {
        content(service.authority.isSystem)
    }
}

/// The connected system's figures and the uses noted for it, read-only (Plan MM P3): what the
/// Stock screen shows in place of the phone's own list while the system holds the count. P4 adds
/// confirming and sending the noted uses.
struct StockSystemHeldSections: View {
    @ObservedObject var service: StockSystemService
    let search: String
    let kind: StockPlace.Kind
    /// The open job: its session id and the number people use for it.
    let job: (sessionID: String, reference: String?)?

    var body: some View {
        let model = self.model
        if let stale = model.staleLine {
            Section {
                Label(stale, systemImage: "clock.badge.exclamationmark")
                    .font(.footnote)
            }
        }
        if !model.noted.isEmpty, let title = model.notedTitle {
            Section {
                ForEach(model.noted) { noted in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(noted.name)
                            if noted.writtenOff {
                                Text("Written off as damaged").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 12)
                        Text(verbatim: noted.amount).monospacedDigit()
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text(title)
            } footer: {
                Text("These go to \(model.system) when the parts are confirmed. \(model.system)'s figures don't change until then.")
            }
        }
        Section {
            if !model.hasFigures {
                Text("No figures from \(model.system) on this phone yet. Pull down to read them.")
                    .foregroundStyle(.secondary)
            } else if model.rows.isEmpty {
                Text(search.isEmpty ? "No tracked lines here in \(model.system)." : "Nothing matches that.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.rows) { row in
                StockSystemRowLabel(row: row)
            }
        } header: {
            Text("In \(model.system)")
        } footer: {
            Text("Stock is kept in \(model.system). Receiving and counting are done there; what is used is noted here and sent once confirmed.")
        }
    }

    private var model: StockSystemScreenModel {
        let here = service.authority.locationIDs
        let scope: StagedStockUseEntry.Scope? = job.map { .job($0.sessionID) }
            ?? (kind.family == .premises ? .day(StagedStockUseStore.dayKey(Date(), calendar: .current)) : nil)
        return StockSystemScreenModel(snapshot: service.snapshot, system: service.displayName, here: here,
                                      noted: service.staged.entries, scope: scope, jobReference: job?.reference,
                                      now: Date(), query: search)
    }
}

/// One of the system's lines: what it is and its figure, or why there is none. Read-only.
private struct StockSystemRowLabel: View {
    let row: StockSystemScreenModel.Row

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                if let detail = row.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                if row.isLow {
                    Label("Low", systemImage: "arrow.down.circle").font(.caption)
                }
            }
            Spacer(minLength: 12)
            if let figure = row.figure {
                Text(verbatim: figure).font(.title3.monospacedDigit())
            } else {
                Text(row.unknownReason ?? String(localized: "Unknown"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        }
        .frame(minHeight: OGMetrics.minTouchTarget)
        .accessibilityElement(children: .combine)
    }
}
