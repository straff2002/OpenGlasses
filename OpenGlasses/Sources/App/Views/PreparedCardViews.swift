import SwiftUI

// Plan KT §5 — a prepared card on the phone: the full card on the My Day page, the compact one on
// the home card and the job day's card, the Google calendar line and its "Show me how" sheet.
// Everything a card says is decided in `PreparedCardPresentation`; these only lay it out. The
// assistant-written draft wears the fixed AI accent (coral), as AI output does everywhere.

/// What a card's controls do, bound to the wearer's state for one card.
struct PreparedCardHandlers {
    var perform: (PreparedAction) -> Void = { _ in }
    var later: (PreparedCardLaterOption) -> Void = { _ in }
    var notUseful: () -> Void = {}
    var dismiss: () -> Void = {}
    var edit: (String) -> Void = { _ in }
    var updateDraft: () -> Void = {}
    var keepMine: () -> Void = {}
    var markDone: () -> Void = {}
    var notSent: () -> Void = {}
}

extension AppState {
    /// The handlers for `card` on any phone surface. An edit in progress is saved before a button
    /// runs, so a hand-off carries what the wearer can see.
    func cardHandlers(for card: PreparedCard) -> PreparedCardHandlers {
        let service = myDayService
        let id = card.id
        func current() -> PreparedCard { service.card(id) ?? card }
        return PreparedCardHandlers(
            perform: { [weak self] action in self?.performCardAction(action, on: current()) },
            later: { option in
                let now = Date()
                guard let until = option.until(now: now, calendar: .autoupdatingCurrent) else { return }
                service.changeCards(now: now) { $0.later(current(), until: until, now: now) }
            },
            notUseful: { service.changeCards { $0.notUseful(current(), now: Date()) } },
            dismiss: { service.changeCards { $0.dismiss(current(), now: Date()) } },
            edit: { text in service.changeCards { $0.edit(current(), text: text, now: Date()) } },
            updateDraft: { service.changeCards { $0.updateDraft(id, now: Date()) } },
            keepMine: {
                let newBase = service.preparedFeed.changedDrafts[id]
                service.changeCards { builder in
                    if let newBase { builder.keepEdit(id, newBase: newBase, now: Date()) }
                }
            },
            markDone: { service.changeCards { $0.handedOff(current(), result: .sent, now: Date()) } },
            notSent: { service.changeCards { $0.notSent(current(), now: Date()) } })
    }
}

/// The chips: the source's glyph and the reason, wrapping onto a second line rather than cutting
/// at large text sizes. One VoiceOver element, read as "because: …".
struct PreparedCardChips: View {
    let chips: [CardSignal]
    @Environment(\.appAccent) private var accent

    var body: some View {
        PillFlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                Label(chip.text, systemImage: Self.icon(chip.source))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(.tertiarySystemFill), in: Capsule())
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(PreparedCardModel.because(chips) ?? "")
    }

    static func icon(_ source: CardSource) -> String {
        switch source {
        case .calendar: "calendar"
        case .reminders: "checklist"
        case .travel: "car"
        case .weather: "cloud.rain"
        case .sleep: "bed.double"
        case .location: "location"
        case .meeting: "waveform"
        case .job: "wrench.and.screwdriver"
        }
    }
}

/// The small "Ready" mark a card carries. Not a feature name: the page stays My Day.
struct PreparedCardReadyMark: View {
    var body: some View {
        Text(PreparedCardModel.readyLabel)
            .font(.caption2.weight(.semibold))
            .textCase(.uppercase)
            .foregroundStyle(OGTheme.tintedAccentLabel(AppAccent.color(for: "violet")))
            .accessibilityHidden(true)
    }
}

/// One card on the My Day page (§5.1).
struct PreparedCardView: View {
    let model: PreparedCardModel
    let handlers: PreparedCardHandlers

    @Environment(\.appAccent) private var accent
    @State private var draftText: String
    @FocusState private var editing: Bool

    init(model: PreparedCardModel, handlers: PreparedCardHandlers) {
        self.model = model
        self.handlers = handlers
        _draftText = State(initialValue: model.draft?.text ?? "")
    }

    private var aiAccent: Color { AppAccent.color(for: "violet") }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                PreparedCardChips(chips: model.chips)
                Spacer(minLength: 4)
                PreparedCardReadyMark()
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(model.headline)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let subject = model.subject {
                    Text(subject)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(model.accessibilityLabel)
            .accessibilityAddTraits(.isHeader)

            if !model.facts.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(model.facts.enumerated()), id: \.offset) { _, fact in
                        HStack(alignment: .firstTextBaseline) {
                            Text(fact.label).foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            Text(fact.value).multilineTextAlignment(.trailing)
                        }
                        .font(.footnote)
                    }
                }
                // Already in the card's reading above.
                .accessibilityHidden(true)
            }

            if let draft = model.draft {
                draftBox(draft)
            }

            if let note = model.handedOffNote {
                handedOffRow(note)
            }

            actions
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text("Dismiss")) { handlers.dismiss() }
        .accessibilityAction(named: Text("Not useful")) { handlers.notUseful() }
        .onChange(of: model.draft?.text) { _, text in
            // A rebuild that changed the draft (Update, or a new card's text) shows it, unless the
            // wearer is mid-edit.
            if !editing, let text { draftText = text }
        }
        .onChange(of: editing) { _, isEditing in
            if !isEditing { commitEdit() }
        }
    }

    private func commitEdit() {
        guard let draft = model.draft, draftText != draft.text else { return }
        handlers.edit(draftText)
    }

    private func draftBox(_ draft: PreparedCardDraftModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(draft.recipientLine)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextEditor(text: $draftText)
                .font(.body)
                .frame(minHeight: 72)
                .scrollContentBackground(.hidden)
                .focused($editing)
                .accessibilityLabel(Text("Draft \(draft.recipientLine)"))
                .accessibilityIdentifier("preparedCard.draft")
            if let changed = model.changedDraft {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Times changed — update draft?")
                        .font(.footnote.weight(.semibold))
                    HStack(spacing: 12) {
                        Button("Update") {
                            draftText = changed
                            handlers.updateDraft()
                        }
                        Button("Keep mine") { handlers.keepMine() }
                    }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.bordered)
                }
            }
            HStack {
                Spacer()
                Text(draft.footer)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .leading) {
            // The coral edge: this text was written by the assistant.
            RoundedRectangle(cornerRadius: 2).fill(aiAccent).frame(width: 3).padding(.vertical, 8)
                .accessibilityHidden(true)
        }
    }

    private func handedOffRow(_ note: String) -> some View {
        HStack(spacing: 12) {
            Label(note, systemImage: "arrow.up.forward.app")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Done") { handlers.markDone() }
                .buttonStyle(.bordered)
            Button("Not sent") { handlers.notSent() }
                .buttonStyle(.bordered)
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                commitEdit()
                handlers.perform(model.primary.action)
            } label: {
                Label(model.primary.label, systemImage: model.primary.systemImage)
            }
            .buttonStyle(.ogProminentCompact)
            .accessibilityIdentifier("preparedCard.primary")

            ForEach(model.secondary) { button in
                Button {
                    commitEdit()
                    handlers.perform(button.action)
                } label: {
                    Text(button.label)
                        .font(.subheadline.weight(.semibold))
                        .frame(minHeight: OGMetrics.minTouchTarget)
                }
                .buttonStyle(.plain)
                .foregroundStyle(OGTheme.tintedAccentLabel(accent))
                .accessibilityIdentifier(button.isHandOff ? "preparedCard.handOff" : "preparedCard.secondary")
            }

            Spacer(minLength: 0)

            Menu {
                if !model.laterOptions.isEmpty {
                    Section("Later") {
                        ForEach(model.laterOptions, id: \.self) { option in
                            Button(option.label) { handlers.later(option) }
                        }
                    }
                }
                Button("Not useful") { handlers.notUseful() }
                Button("Dismiss", role: .destructive) { handlers.dismiss() }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: OGMetrics.minTouchTarget, height: OGMetrics.minTouchTarget)
            }
            .foregroundStyle(accent)
            .accessibilityLabel(Text("More for \(model.headline)"))
        }
    }
}

/// The top card on the home card (§5.2): chips, headline and the primary button, and "N more
/// ready" when there are more.
struct PreparedCardCompactView: View {
    let home: PreparedCardHomeModel
    let handlers: PreparedCardHandlers
    let onMore: () -> Void

    var body: some View {
        if let top = home.top {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    PreparedCardChips(chips: top.chips)
                    Spacer(minLength: 4)
                    PreparedCardReadyMark()
                }
                Text(top.headline)
                    .font(.body.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(top.accessibilityLabel)
                HStack(spacing: 12) {
                    Button {
                        handlers.perform(top.primary.action)
                    } label: {
                        Label(top.primary.label, systemImage: top.primary.systemImage)
                    }
                    .buttonStyle(.ogProminentCompact)
                    if let more = home.moreReadyText {
                        Button(more, action: onMore)
                            .font(.footnote.weight(.semibold))
                            .buttonStyle(.plain)
                            .frame(minHeight: OGMetrics.minTouchTarget)
                            .accessibilityHint(Text("Opens My Day."))
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityAction(named: Text("Dismiss")) { handlers.dismiss() }
        }
    }
}

/// "Use Google Calendar?" (§9.2): once, dismissible, with "Show me how".
struct GoogleCalendarLine: View {
    let onDismiss: () -> Void
    @State private var showingHelp = false
    @Environment(\.appAccent) private var accent

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            OGIconTile(systemName: "calendar.badge.plus")
            VStack(alignment: .leading, spacing: 6) {
                Text("Use Google Calendar? Add your Google account to iPhone's Calendar and it shows up here.")
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Show me how") { showingHelp = true }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(OGTheme.tintedAccentLabel(accent))
            }
            Spacer(minLength: 4)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .frame(width: OGMetrics.minTouchTarget, height: OGMetrics.minTouchTarget)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(Text("Close the Google Calendar tip"))
        }
        .padding(16)
        .sheet(isPresented: $showingHelp) { GoogleCalendarHelpSheet() }
    }
}

/// How to add a Google account to iOS Calendar. iOS gives apps no link into those settings, so
/// this explains rather than opens; no Google sign-in happens in this app.
struct GoogleCalendarHelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    static var steps: [String] {
        [
            String(localized: "Open the Settings app.", comment: "Google Calendar help: step 1."),
            String(localized: "Go to Apps, then Calendar, then Calendar Accounts.", comment: "Google Calendar help: step 2."),
            String(localized: "Tap Add Account, then Google, and sign in.", comment: "Google Calendar help: step 3."),
            String(localized: "Turn on Calendars.", comment: "Google Calendar help: step 4."),
        ]
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text("\(index + 1)").font(.headline).monospacedDigit()
                            Text(step)
                        }
                        .accessibilityElement(children: .combine)
                    }
                } footer: {
                    Text("Your Google events then appear in My Day like any other calendar. You sign in with Google in Settings, never in this app.")
                }
            }
            .navigationTitle("Add Google Calendar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

/// "Short night cards are off" after three "not useful" in two weeks, with Undo (§3.5). Once.
struct PreparedCardTurnedOffNotice: View {
    let kind: PreparedCardKind
    let onUndo: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("\(kind.settingsName) cards are off. You can turn them on again in My Day settings.")
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Undo", action: onUndo)
                .buttonStyle(.bordered)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .frame(width: OGMetrics.minTouchTarget, height: OGMetrics.minTouchTarget)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(Text("Close"))
        }
        .padding(16)
    }
}
