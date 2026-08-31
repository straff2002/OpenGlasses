import SwiftUI

/// Arranges the dock panel's one grid: every control and every content action, in one ordered list.
/// Reached from Settings → Quick Actions → Bar Layout — the roomy alternative to the panel's own
/// edit page, with drag-to-reorder and a full screen to do it on.
///
/// It used to be two editors — a Bar Layout list for the controls and a Home Grid list for the
/// actions — which meant the one thing a user actually wanted to do, put a tile next to a control,
/// was the one thing neither list could express.
///
/// Removing a tile takes it off the grid and nothing else. Speed-dial actions keep living in
/// Settings, on the widget, on the watch and in the HUD launcher, so this view has no delete; and
/// controls cannot be removed at all, because a dock without its disconnect is a trap.
struct DockLayoutEditorView: View {
    /// The one arrangement both the dock and this view read.
    @AppStorage("homeGridArrangement") private var storedArrangement = ""
    /// The legacy control-only order, still honoured as the fallback ordering for controls an
    /// arrangement has not placed yet.
    @AppStorage("dockItemOrder") private var dockOrder = ""

    private var quickActions: [QuickAction] { Config.quickActions }
    private var controlOrder: [DockItem] { DockLayout.decode(dockOrder) }

    private var catalog: [DockSlot] {
        DockGridCatalog.available(controlOrder: controlOrder, quickActions: quickActions)
    }

    private var arrangement: HomeGridArrangement {
        HomeGridStore.decode(storedArrangement, available: catalog.map(\.id)).arrangement
    }

    /// The grid as the dock draws it with nothing yielding — the editor shows what the arrangement
    /// says, not what this moment's voice state happens to allow.
    private var onGrid: [DockSlot] {
        DockGridCatalog.slots(arrangement: arrangement,
                              controlOrder: controlOrder,
                              quickActions: quickActions,
                              showsActions: true)
    }

    private var available: [DockSlot] {
        let placed = Set(onGrid.map(\.id))
        return catalog.filter { !placed.contains($0.id) }
    }

    var body: some View {
        List {
            Section {
                ForEach(onGrid) { slot in
                    HStack(spacing: 12) {
                        Image(systemName: slot.editorIcon)
                            .font(.title3)
                            .foregroundStyle(Color(.label))
                            .frame(width: 28)
                        Text(slot.editorLabel)
                            .foregroundStyle(Color(.label))
                        Spacer()
                        if case .control = slot {
                            Text("control")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color(.tertiarySystemFill), in: Capsule())
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(slot.isHideable ? slot.editorLabel
                                                        : "\(slot.editorLabel), control")
                    // A swipe that does nothing is worse than no swipe at all, so the row says why
                    // before the user tries it.
                    .accessibilityHint(slot.isHideable
                                       ? "Swipe to take this off the grid."
                                       : "Controls stay on the grid and can only be reordered.")
                    .deleteDisabled(!slot.isHideable)
                }
                .onMove(perform: move)
                .onDelete(perform: remove)
            } header: {
                Text("On the Bar")
            } footer: {
                Text("Controls and actions in one grid, wrapping into rows of four and scrolling if it outgrows the bar. Drag to reorder; swipe to take an action off. Taking a tile off never deletes the action behind it, and controls always stay.")
            }

            if !available.isEmpty {
                Section {
                    ForEach(available) { slot in
                        Button {
                            add(slot)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: slot.editorIcon)
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 28)
                                Text(slot.editorLabel)
                                    .foregroundStyle(Color(.label))
                                Spacer()
                                Image(systemName: "plus.circle")
                                    .foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Add \(slot.editorLabel)")
                        .accessibilityHint("Double-tap to put this on the bar.")
                    }
                } header: {
                    Text("Available")
                } footer: {
                    Text("Built-in actions and every speed-dial action you've configured. Edit the speed dial itself in Settings → Quick Actions.")
                }
            }

            Section {
                Button("Reset to Default", role: .destructive) {
                    storedArrangement = ""
                }
            } footer: {
                Text("Puts the bar back to the shipped order with nothing hidden. Your speed-dial actions are untouched.")
            }
        }
        .navigationTitle("Bar Layout")
        .navigationBarTitleDisplayMode(.inline)
        .ogFormStyle()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { EditButton() }
        }
    }

    // MARK: - Mutations

    /// What an edit *means* is `DockArrangementEditor`'s, shared with the in-panel edit page. This
    /// view only decides how the edit is driven.
    private func move(from: IndexSet, to: Int) {
        storedArrangement = HomeGridStore.encode(
            DockArrangementEditor.moving(arrangement, resolved: onGrid,
                                         fromOffsets: from, toOffset: to))
    }

    private func remove(_ offsets: IndexSet) {
        let resolved = onGrid
        storedArrangement = HomeGridStore.encode(
            DockArrangementEditor.removing(arrangement, resolved: resolved,
                                           ids: offsets.map { resolved[$0].id }))
    }

    private func add(_ slot: DockSlot) {
        storedArrangement = HomeGridStore.encode(
            DockArrangementEditor.adding(arrangement, resolved: onGrid, id: slot.id))
    }
}
