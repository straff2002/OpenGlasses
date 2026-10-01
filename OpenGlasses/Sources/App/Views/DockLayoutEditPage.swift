import SwiftUI

/// The home screen's editor: what is on the home screen, and the grid's one order.
///
/// Reached only from the cog on the dock's page-dots row (or the long press on the grid's gaps,
/// which goes to the same place) and presented as a sheet. It used to be a third page of the dock's
/// pager, one swipe onward from the grid — which is how wearers landed in it by accident — and at a
/// one-row panel it would not have had the room to be usable anyway.
///
/// The same arrangement and the same rules as the full-screen `DockLayoutEditorView` — both drive
/// `DockArrangementEditor`, so an edit means the same thing wherever it is made. It edits the
/// **order**, never pages: the grid cuts that order into pages to fit the screen
/// (`HomeGridPaging`), so moving a tile never depends on how tall the screen is. Reordering is a
/// pair of buttons rather than a drag, because buttons are the only form of reordering VoiceOver
/// can drive; Settings → Quick Actions → Bar Layout keeps the drag.
struct DockLayoutEditPage: View {
    /// The one arrangement the dock, this page and the full editor all read.
    @AppStorage("homeGridArrangement") private var storedArrangement = ""
    /// The legacy control-only order, still honoured as the fallback ordering for controls an
    /// arrangement has not placed yet.
    @AppStorage("dockItemOrder") private var dockOrder = ""
    /// Not read for its value — `Config.quickActions` owns that, with its merges and its
    /// per-read injection. This is the republish: the speed dial is a plain `UserDefaults` blob,
    /// so without observing the key a tile created on this page would not appear until something
    /// else redrew the panel.
    @AppStorage("quickActions") private var quickActionsBeacon = Data()

    @Environment(\.appAccent) private var accent

    /// My Day's two facts — on at all, and placed on the home screen (`MyDayHomePlacement`). The
    /// same keys Settings and the card's own "Remove from Home" write.
    @AppStorage(MyDayHomePlacement.enabledKey) private var myDayEnabled = false
    @AppStorage(MyDayHomePlacement.onHomeKey) private var myDayOnHome
        = MyDayHomePlacement.onHomeDefault

    @State private var editing: EditorTarget?

    /// What the creation sheet is doing. `Identifiable` so one `.sheet(item:)` serves both, and
    /// the sheet is never presented against a stale action.
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

    /// What the arrangement says, not what this moment's mode allows — an editor that hid rows
    /// because of the session state would be an editor you could not trust.
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
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 6) {
                sectionHeader("Cards")
                myDayRow

                sectionHeader("Tiles")
                    .padding(.top, 6)
                addRow

                let slots = onGrid
                ForEach(Array(slots.enumerated()), id: \.element.id) { index, slot in
                    row(slot, index: index, count: slots.count)
                }

                if !available.isEmpty {
                    sectionHeader("Available")
                        .padding(.top, 6)

                    ForEach(available) { slot in
                        availableRow(slot)
                    }
                }

                Button("Reset to Default") { storedArrangement = "" }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(OGTheme.errorLabel)
                    .frame(maxWidth: .infinity, minHeight: OGMetrics.minTouchTarget)
                    .accessibilityHint("Puts the bar back to the shipped order. Your actions are kept.")
            }
            .padding(.horizontal, 2)
        }
        .scrollBounceBehavior(.basedOnSize)
        .sheet(item: $editing) { target in
            HomeActionEditorSheet(
                existing: target.action,
                onSave: SpeedDialWriter.save,
                onDelete: target.action.map { _ in SpeedDialWriter.delete })
        }
    }

    // MARK: - Cards

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }

    /// My Day on the home screen. Turning it on here is the opt-in the old set-up card was — My Day
    /// on, and its card placed. Turning it off only takes the card away: the briefings keep their
    /// own settings.
    private var myDayRow: some View {
        Toggle(isOn: Binding(
            get: { MyDayHomePlacement.isShown(enabled: myDayEnabled, onHome: myDayOnHome) },
            set: { Config.setMyDayShownOnHome($0) }
        )) {
            HStack(spacing: 8) {
                Image(systemName: "sun.max.fill")
                    .font(.footnote)
                    .foregroundStyle(Color(.label))
                    .frame(width: 22)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("My Day")
                        .font(.footnote)
                        .foregroundStyle(Color(.label))
                    Text(myDayEnabled
                         ? "Briefings keep their own settings."
                         : "Uses Calendar, Reminders and Weather once you turn it on.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .tint(accent)
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .frame(minHeight: OGMetrics.minTouchTarget)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(OGTheme.card)
        )
    }

    // MARK: - Creating and editing

    private var addRow: some View {
        Button {
            editing = EditorTarget(action: nil)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(accent)
                    .frame(width: 22)
                    .accessibilityHidden(true)
                Text("New Action")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(.label))
                Spacer(minLength: 4)
            }
            .padding(.leading, 8)
            .frame(minHeight: OGMetrics.minTouchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(OGTheme.card)
        )
        .accessibilityLabel("New action")
        .accessibilityHint("Double-tap to make an action: a name, an icon, and what to ask.")
    }

    // MARK: - Rows

    private func row(_ slot: DockSlot, index: Int, count: Int) -> some View {
        HStack(spacing: 8) {
            // The name is the edit control — a fourth button would not fit the panel's width, and
            // a row that opens what it names is the idiom the rest of the app uses. Built-ins are
            // shipped in code, so theirs opens nothing and says why.
            Button {
                if let action = editableAction(slot) { editing = EditorTarget(action: action) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: slot.editorIcon)
                        .font(.footnote)
                        .foregroundStyle(Color(.label))
                        .frame(width: 22)
                        .accessibilityHidden(true)

                    Text(slot.editorLabel)
                        .font(.footnote)
                        .foregroundStyle(Color(.label))
                        .lineLimit(1)
                }
                .frame(minHeight: OGMetrics.minTouchTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(editableAction(slot) == nil)
            .accessibilityLabel(slot.editorLabel)
            .accessibilityHint(editableAction(slot) != nil
                               ? "Double-tap to edit or delete this action."
                               : "Built in. It can be moved or taken off the bar, but not changed.")

            Spacer(minLength: 4)

            nudge(slot, by: -1, symbol: "chevron.up", name: "Move up", enabled: index > 0)
            nudge(slot, by: 1, symbol: "chevron.down", name: "Move down",
                  enabled: index < count - 1)

            Button {
                storedArrangement = HomeGridStore.encode(
                    DockArrangementEditor.removing(arrangement, resolved: onGrid, ids: [slot.id]))
            } label: {
                Image(systemName: "minus.circle")
                    .font(.footnote)
                    .frame(width: OGMetrics.minTouchTarget, height: OGMetrics.minTouchTarget)
            }
            .buttonStyle(.plain)
            .foregroundStyle(slot.isHideable ? OGTheme.errorLabel : OGTheme.secondaryLabel)
            .disabled(!slot.isHideable)
            .accessibilityLabel("Take \(slot.editorLabel) off the bar")
            // Dimmed and unexplained is not an answer. A control cannot be removed, and the
            // reason has to be said rather than left as a dead button.
            .accessibilityHint(slot.isHideable
                               ? "Removes the tile. The action itself is kept."
                               : "Controls stay on the bar and can only be reordered.")
        }
        .padding(.leading, 8)
        .frame(minHeight: OGMetrics.minTouchTarget)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(OGTheme.card)
        )
    }

    /// The speed-dial action behind a slot, when this editor is allowed to rewrite it. Controls
    /// and the shipped grid actions have none.
    private func editableAction(_ slot: DockSlot) -> QuickAction? {
        guard case .action(let entry) = slot else { return nil }
        return SpeedDialEditor.editableAction(for: entry)
    }

    private func nudge(_ slot: DockSlot, by delta: Int, symbol: String,
                       name: String, enabled: Bool) -> some View {
        Button {
            storedArrangement = HomeGridStore.encode(
                DockArrangementEditor.moving(arrangement, resolved: onGrid,
                                             id: slot.id, by: delta))
        } label: {
            Image(systemName: symbol)
                .font(.footnote)
                .frame(width: OGMetrics.minTouchTarget, height: OGMetrics.minTouchTarget)
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? accent : OGTheme.secondaryLabel)
        .disabled(!enabled)
        .accessibilityLabel("\(name): \(slot.editorLabel)")
    }

    private func availableRow(_ slot: DockSlot) -> some View {
        Button {
            storedArrangement = HomeGridStore.encode(
                DockArrangementEditor.adding(arrangement, resolved: onGrid, id: slot.id))
        } label: {
            HStack(spacing: 8) {
                Image(systemName: slot.editorIcon)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                Text(slot.editorLabel)
                    .font(.footnote)
                    .foregroundStyle(Color(.label))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "plus.circle")
                    .font(.footnote)
                    .foregroundStyle(accent)
                    .frame(width: OGMetrics.minTouchTarget, height: OGMetrics.minTouchTarget)
            }
            .padding(.leading, 8)
            .frame(minHeight: OGMetrics.minTouchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add \(slot.editorLabel)")
        .accessibilityHint("Double-tap to put this on the bar.")
    }
}
