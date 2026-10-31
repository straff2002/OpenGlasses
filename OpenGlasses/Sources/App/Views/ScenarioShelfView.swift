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
                    card(entry)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .leading)))
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Things to try")
        }
    }

    private func card(_ entry: ScenarioEntry) -> some View {
        HStack(spacing: 8) {
            Button { open(entry) } label: {
                HStack(spacing: 10) {
                    Image(systemName: entry.scenario.icon)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 24)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: entry.scenario.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(verbatim: entry.detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(runningID != nil)
            .accessibilityElement(children: .combine)
            .accessibilityHint(hint(for: entry))

            Button {
                let change = { store.dismiss(entry.id) }
                if reduceMotion { change() } else { withAnimation(.easeInOut(duration: 0.2), change) }
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Dismiss \(entry.scenario.title)"))
        }
        .padding(.leading, 12)
        .padding(.vertical, 4)
    }

    private func hint(for entry: ScenarioEntry) -> String {
        switch entry.readiness {
        case .needsSetup: return String(localized: "Opens Settings.")
        case .ready, .hidden:
            return entry.scenario.kind == .photoPrompt
                ? String(localized: "Takes a photo, then asks about it.")
                : String(localized: "Double-tap to ask.")
        }
    }

    private func open(_ entry: ScenarioEntry) {
        if case .needsSetup(let step) = entry.readiness {
            if let destination = step.destination { appState.openSettings(destination) }
            return
        }
        // Busy, a turn sent now is dropped without a word. The card stays and nothing is marked.
        guard runningID == nil, appState.acceptsTypedTurn else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        runningID = entry.id
        store.markTried(entry.id)
        Task {
            await HomeGridDispatcher.run(.builtIn(entry.scenario.action), on: appState)
            runningID = nil
        }
    }
}
