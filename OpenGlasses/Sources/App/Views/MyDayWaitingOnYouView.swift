import SwiftUI

/// My Day's **Waiting on you** section (Plan LE §8): the Evening Check-in's list, each row with its
/// own action and a swipe to clear it for tonight. Thin on purpose — the rules, the rows and what
/// each button reaches are `WaitingOnYouScreenModel`'s.
struct MyDayWaitingOnYouSection: View {
    @ObservedObject var model: WaitingOnYouScreenModel
    /// An action that leaves the page (`WaitingOnYouAction.leavesPage`): the page steps aside and
    /// takes it once it has gone, so the place it opens — or the confirmation card, drawn over the
    /// app's root — is not under the sheet.
    var onLeave: (WaitingOnYouAction) -> Void = { _ in }
    @Environment(\.appAccent) private var accent

    var body: some View {
        if model.isVisible {
            OGSection(header: "Waiting on you") {
                if model.rows.isEmpty {
                    Text(model.unavailable.isEmpty ? WaitingOnYouText.emptyNote : WaitingOnYouText.unreadableNote)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                } else {
                    ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { OGDivider() }
                        MyDaySwipeToClear(label: row.title) {
                            model.dismiss(row)
                        } content: {
                            rowView(row)
                        }
                    }
                    if !model.unavailable.isEmpty {
                        OGDivider()
                        Text(WaitingOnYouText.unreadableNote)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                }
            }
            .alert("My Day", isPresented: Binding(
                get: { model.notice != nil },
                set: { if !$0 { model.notice = nil } }
            )) {
                Button("OK") { model.notice = nil }
            } message: {
                Text(model.notice ?? "")
            }
        }
    }

    private func rowView(_ row: WaitingOnYouRow) -> some View {
        HStack(alignment: .top, spacing: 12) {
            OGIconTile(systemName: row.symbol)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = row.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if let secondary = row.secondary { button(secondary, row: row) }
            if let primary = row.primary { button(primary, row: row) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: OGMetrics.minTouchTarget)
    }

    private func button(_ action: WaitingOnYouAction, row: WaitingOnYouRow) -> some View {
        Button {
            if action.leavesPage {
                onLeave(action)
            } else {
                Task { await model.perform(action) }
            }
        } label: {
            Image(systemName: action.symbol)
                .frame(width: OGMetrics.minTouchTarget, height: OGMetrics.minTouchTarget)
        }
        .buttonStyle(.plain)
        .foregroundStyle(accent)
        .accessibilityLabel("\(action.label): \(row.title)")
    }
}
