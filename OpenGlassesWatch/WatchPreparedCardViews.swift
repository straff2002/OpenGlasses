import SwiftUI
import WatchKit

// Plan KT §6.7 — the day's prepared cards on the wrist, above Today's calendar. The phone builds
// them (`WatchPreparedCardBuilder`) and decides what may show here: no health card ever comes, and
// a draft's text only when its sensitivity and Medical Compliance allow. A press goes back to the
// phone as `preparedCardAction`; **stage** puts the draft on the phone, where the wearer taps Send.
// Nothing on the wrist sends a message.

/// The cards, or nothing at all when there are none.
struct WatchPreparedCardList: View {
    let cards: [WatchPreparedCard]
    let connectivity: WatchConnectivityService?

    var body: some View {
        if !cards.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Ready")
                    .font(.caption2.bold())
                    .foregroundStyle(AccentColors.aiCoral)
                ForEach(cards) { card in
                    WatchPreparedCardView(card: card, connectivity: connectivity)
                }
            }
            .padding(.bottom, 4)
        }
    }
}

struct WatchPreparedCardView: View {
    let card: WatchPreparedCard
    let connectivity: WatchConnectivityService?

    /// The phone's answer to the last press.
    @State private var reply: String?
    @State private var sending = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !card.chips.isEmpty {
                Text(card.chips.map(\.text).joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Text(card.headline)
                .font(.headline)
                .lineLimit(3)
            ForEach(Array(card.facts.enumerated()), id: \.offset) { _, fact in
                Text("\(fact.label) \(fact.value)")
                    .font(.caption2)
                    .lineLimit(2)
            }
            draft
            buttons
            if let reply {
                Text(reply)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.15)))
    }

    @ViewBuilder
    private var draft: some View {
        if let to = card.draftTo {
            VStack(alignment: .leading, spacing: 2) {
                Text(to)
                    .font(.caption2.bold())
                if let text = card.draftText {
                    Text(text)
                        .font(.caption2)
                } else if card.draftWithheld {
                    Text("Read the message on your iPhone.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(6)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(AccentColors.aiCoral, lineWidth: 1))
        }
    }

    @ViewBuilder
    private var buttons: some View {
        if connectivity != nil {
            ForEach(card.buttons, id: \.self) { button in
                Button(button.action == .stage ? String(localized: "\(button.label) on iPhone") : button.label) {
                    press(button.action)
                }
                .tint(button.action == .stage ? AccentColors.aiCoral : nil)
                .disabled(sending)
            }
            HStack {
                Button("Later") { press(.later) }
                Button("Dismiss") { press(.dismiss) }
            }
            .font(.caption2)
            .disabled(sending)
        } else {
            Text(card.primaryLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func press(_ action: WatchPreparedCardAction) {
        guard let connectivity else { return }
        sending = true
        connectivity.sendPreparedCardAction(action, cardID: card.id) { message, done in
            sending = false
            reply = message
            WKInterfaceDevice.current().play(done ? .success : .failure)
        }
    }
}
