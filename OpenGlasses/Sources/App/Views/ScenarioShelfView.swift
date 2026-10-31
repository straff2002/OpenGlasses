import SwiftUI

/// Up to three things to try, in the transcript's empty state (Plan KH P1).
///
/// Drawn only when nothing has been said, so it never competes with a conversation, and only in
/// Direct mode, on the grid's own rule: the realtime modes run their own turn spine. Each card
/// leaves when tried or dismissed, and the shelf ends for good after three (`ScenarioShelfPolicy`).
/// Cards are flat, because the panel is the glass, the same rule its tiles and transcript follow.
struct ScenarioShelfView<Fallback: View>: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var store = ScenarioProgressStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var runningID: String?
    @ViewBuilder var fallback: () -> Fallback

    var body: some View {
        let cards = appState.scenarioShelfCards(progress: store.progress)
        if cards.isEmpty {
            fallback()
        } else {
            VStack(spacing: 6) {
                ForEach(cards) { entry in
                    ScenarioCardRow(entry: entry, isDisabled: runningID != nil,
                                    open: { open(entry) }, dismiss: { store.dismiss(entry.id) })
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .leading)))
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Things to try")
        }
    }

    private func open(_ entry: ScenarioEntry) {
        guard runningID == nil else { return }
        // Busy, a turn sent now is dropped without a word. The card stays and nothing is marked.
        switch store.begin(entry, acceptsTurn: appState.acceptsTypedTurn) {
        case .openSettings(let destination):
            appState.openSettings(destination)
        case .nothing:
            return
        case .run:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            runningID = entry.id
            Task {
                await HomeGridDispatcher.run(.builtIn(entry.scenario.action), on: appState)
                runningID = nil
            }
        }
    }
}

/// One card: the thing to open, and an X that takes it away. The shelf draws these, and so do the
/// Voice tab's "Things to try" card and its sheet, so all three behave alike.
struct ScenarioCardRow: View {
    let icon: String
    let title: String
    let detail: String
    let hint: String
    let dismissLabel: Text
    var isDisabled = false
    let open: () -> Void
    let dismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            Button(action: open) {
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 24)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(verbatim: detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: OGMetrics.minTouchTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
            .accessibilityElement(children: .combine)
            .accessibilityHint(hint)

            Button {
                if reduceMotion { dismiss() } else { withAnimation(.easeInOut(duration: 0.2), dismiss) }
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: OGMetrics.minTouchTarget, minHeight: OGMetrics.minTouchTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(dismissLabel)
        }
        .padding(.leading, 12)
        .padding(.vertical, 4)
    }
}

extension ScenarioCardRow {
    /// A scenario's own card.
    init(entry: ScenarioEntry, isDisabled: Bool, open: @escaping () -> Void, dismiss: @escaping () -> Void) {
        self.init(icon: entry.scenario.icon, title: entry.scenario.title, detail: entry.detail,
                  hint: Self.hint(for: entry), dismissLabel: Text("Dismiss \(entry.scenario.title)"),
                  isDisabled: isDisabled, open: open, dismiss: dismiss)
    }

    private static func hint(for entry: ScenarioEntry) -> String {
        switch entry.readiness {
        case .needsSetup: return String(localized: "Opens Settings.")
        case .ready, .hidden:
            return entry.scenario.kind == .photoPrompt
                ? String(localized: "Takes a photo, then asks about it.")
                : String(localized: "Double-tap to ask.")
        }
    }
}
