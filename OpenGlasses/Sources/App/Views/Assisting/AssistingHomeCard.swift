import SwiftUI

/// Assisting's one card on the Home screen (Plan KW §2–3): a clock running, jobs sent and not yet
/// taken, or an invite asking for the card. `AssistingPresence` decides which, and whether there
/// is one at all; this only draws it. A long press removes it from Home, as My Day's does, except
/// a running clock, which stays until it is paused or done.
struct AssistingHomeCard: View {
    @ObservedObject var service: AssistingService
    /// Opens Settings › Assisting, for several jobs at once.
    var onOpenAssisting: () -> Void

    init(service: AssistingService = .shared, onOpenAssisting: @escaping () -> Void) {
        self.service = service
        self.onOpenAssisting = onOpenAssisting
    }

    @Environment(\.appAccent) private var accent

    var body: some View {
        if let card = service.presence.homeCard {
            content(card)
                .padding(.horizontal, 16)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
        }
    }

    @ViewBuilder
    private func content(_ card: AssistingPresence.HomeCard) -> some View {
        let button = Button { open(card) } label: {
            OGCard {
                HStack(spacing: 12) {
                    Image(systemName: icon(card))
                        .font(.title3)
                        .foregroundStyle(OGTheme.tintedAccentLabel(accent))
                        .frame(width: 28)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            Text(verbatim: title(card, at: context.date))
                                .font(.headline)
                                .foregroundStyle(.primary)
                        }
                        Text(verbatim: subtitle(card))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("Opens Assisting"))

        if card.dismissalIds.isEmpty {
            button
        } else {
            button.contextMenu {
                Button(role: .destructive) {
                    withAnimation(DockGridMetrics.heightSettle) { service.dismissFromHome(card) }
                } label: {
                    Label("Remove from Home", systemImage: "minus.circle")
                }
            }
        }
    }

    private func icon(_ card: AssistingPresence.HomeCard) -> String {
        switch card {
        case .clock: return "clock.badge.checkmark"
        case .newJobs: return "person.2.wave.2"
        case .invite: return "person.text.rectangle"
        }
    }

    private func title(_ card: AssistingPresence.HomeCard, at date: Date) -> String {
        switch card {
        case .clock(let id, let organisation, let count):
            let minutes = service.clockMinutes(for: id, at: date) ?? 0
            if count > 1 { return String(localized: "\(count) clocks running") }
            return organisation.isEmpty
                ? String(localized: "On the clock: \(minutes) min")
                : String(localized: "On the clock: \(organisation), \(minutes) min")
        case .newJobs(let ids, let organisation):
            if ids.count == 1 {
                return organisation.isEmpty ? String(localized: "1 job sent to you")
                    : String(localized: "1 job from \(organisation)")
            }
            return organisation.isEmpty ? String(localized: "\(ids.count) jobs sent to you")
                : String(localized: "\(ids.count) jobs from \(organisation)")
        case .invite(_, let organisation):
            return organisation.isEmpty ? String(localized: "You're asked for your expert card")
                : String(localized: "\(organisation) asked for your expert card")
        }
    }

    private func subtitle(_ card: AssistingPresence.HomeCard) -> String {
        switch card {
        case .clock: return String(localized: "Pause or finish it in Assisting")
        case .newJobs: return String(localized: "Read the job, then take it to start your clock")
        case .invite: return String(localized: "Fill in your card once; it works for every company you help")
        }
    }

    private func open(_ card: AssistingPresence.HomeCard) {
        switch card {
        case .clock(let id, _, let count) where count == 1:
            service.show(handoverId: id)
        case .newJobs(let ids, _) where ids.count == 1:
            service.show(handoverId: ids[0])
        case .invite(let id, _):
            service.showInvite(id)
        default:
            onOpenAssisting()
        }
    }
}
