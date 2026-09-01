import SwiftUI

/// Arranges the dock panel's one grid: every control and every content action, in one ordered list.
/// Reached from Settings → Quick Actions → Bar Layout — the roomy alternative to the panel's own
/// edit page, with drag-to-reorder and a full screen to do it on.
///
/// It used to be two editors — a Bar Layout list for the controls and a Home Grid list for the
/// actions — which meant the one thing a user actually wanted to do, put a tile next to a control,
/// was the one thing neither list could express.
///
/// Removing a tile takes it off the grid and nothing else — the action keeps living on the widget,
/// the watch and the HUD launcher — and controls cannot be removed at all, because a dock without
/// its disconnect is a trap. Deleting an action outright is a separate, confirmed act inside the
/// editor sheet, where the copy can say what it costs.
struct DockLayoutEditorView: View {
    /// The one arrangement both the dock and this view read.
    @AppStorage("homeGridArrangement") private var storedArrangement = ""
    /// The legacy control-only order, still honoured as the fallback ordering for controls an
    /// arrangement has not placed yet.
    @AppStorage("dockItemOrder") private var dockOrder = ""
    /// The republish beacon for the speed dial — see the note on the panel's edit page. The value
    /// is never read; `Config.quickActions` owns it.
    @AppStorage("quickActions") private var quickActionsBeacon = Data()

    @State private var editing: EditorTarget?

    private struct EditorTarget: Identifiable {
        let action: QuickAction?
        var id: String { action?.id ?? "new" }
    }

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
                Button {
                    editing = EditorTarget(action: nil)
                } label: {
                    Label("New Action", systemImage: "plus.circle.fill")
                }
                .accessibilityHint("Double-tap to make an action: a name, an icon, and what to ask.")
            } footer: {
                Text("A new action is a name, a glyph, and a prompt. It joins the grid at the end and is reachable everywhere your speed dial is.")
            }

            Section {
                ForEach(onGrid) { slot in
                    gridRow(slot)
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
                    Text("Built-in actions and every speed-dial action you've made. Tap one on the bar to edit it.")
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
        .sheet(item: $editing) { target in
            HomeActionEditorSheet(
                existing: target.action,
                onSave: SpeedDialWriter.save,
                onDelete: target.action.map { _ in SpeedDialWriter.delete })
        }
    }

    // MARK: - Rows

    /// One grid row. A row whose action the wearer authored opens the editor; a control and a
    /// shipped action do not, and say so rather than presenting a dead chevron.
    @ViewBuilder
    private func gridRow(_ slot: DockSlot) -> some View {
        let editable = editableAction(slot)
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
            } else if editable != nil {
                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let editable { editing = EditorTarget(action: editable) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(slot.isHideable ? slot.editorLabel : "\(slot.editorLabel), control")
        // A swipe that does nothing is worse than no swipe at all, so the row says why
        // before the user tries it.
        .accessibilityHint(slot.isHideable
                           ? "Swipe to take this off the grid."
                           : "Controls stay on the grid and can only be reordered.")
        .accessibilityActions {
            if let editable {
                Button("Edit action") { editing = EditorTarget(action: editable) }
            }
        }
        .deleteDisabled(!slot.isHideable)
    }

    /// The speed-dial action behind a slot, when this editor may rewrite it.
    private func editableAction(_ slot: DockSlot) -> QuickAction? {
        guard case .action(let entry) = slot else { return nil }
        return SpeedDialEditor.editableAction(for: entry)
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
