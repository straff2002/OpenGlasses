import SwiftUI
import UIKit

/// Plan LW §4 and §4a — one screen for both ways a vault's three layers get drafted, per manual:
/// the phone's own proposals (cards, *Keep / Edit / Skip*, *Keep all checked* per card) and a reply
/// pasted from the author's own AI (*Copy prompt*, paste, check). Every row shows its check against
/// the manual and the page; nothing is written to the vault without a tap.
@MainActor
struct DraftReviewView: View {
    @EnvironmentObject private var appState: AppState
    let vaultId: String
    let file: String
    var title: String = ""
    /// The UI test's manual, drawn without indexing.
    var fixture: LiveDraftPageText.Manual? = nil
    /// The UI test's pasted reply, put in the fault-code paste field as a paste would.
    var fixturePaste: String? = nil

    @StateObject private var model = DraftReviewModel()
    @State private var layer: DraftLayer = .faultCodes
    @State private var editing: EditTarget?

    struct EditTarget: Identifiable {
        let item: DraftReviewItem
        let layer: DraftLayer
        var id: UUID { item.id }
    }

    var body: some View {
        Form {
            if model.manual == nil {
                Section {
                    Text("This manual isn't indexed yet. When it is, the phone reads its pages here.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    Picker("Layer", selection: $layer) {
                        Text("Fault codes").tag(DraftLayer.faultCodes)
                        Text("Equipment models").tag(DraftLayer.modelMap)
                        Text("Symptoms").tag(DraftLayer.symptoms)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("draftReview.layer")
                } footer: {
                    Text("Nothing is added to the vault until you keep it. Each row is checked against this manual's pages on this phone.")
                }
                if let message = model.message {
                    Section { OGStatusLabel(message, kind: .error) }
                }
                DraftProposalSection(model: model, layer: layer, editing: $editing)
                DraftPasteSection(model: model, layer: layer, editing: $editing)
            }
        }
        .navigationTitle(title.isEmpty ? Text("Drafts") : Text(verbatim: title))
        .navigationBarTitleDisplayMode(.inline)
        .ogFormStyle()
        .onAppear {
            if model.manual == nil {
                model.load(vaultId: vaultId, file: file, documentStore: appState.documentStore, fixture: fixture)
                if let fixturePaste { model.pasteText[.faultCodes] = fixturePaste }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { hideKeyboard() }
                    .accessibilityIdentifier("draftReview.keyboardDone")
            }
        }
        .sheet(item: $editing) { target in
            DraftRowEditor(row: target.item.row) { row in
                model.edit(target.item.id, layer: target.layer, to: row)
            }
        }
    }
}

@MainActor
private func hideKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

/// The phone's proposals for one layer, as one card.
@MainActor
private struct DraftProposalSection: View {
    @ObservedObject var model: DraftReviewModel
    let layer: DraftLayer
    @Binding var editing: DraftReviewView.EditTarget?

    var body: some View {
        let items = model.items(layer, .proposal)
        Section {
            if items.isEmpty {
                Text("The phone found nothing for this layer in the manual's tables and pages. You can paste rows from your own AI below.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                if let summary = model.summary(layer) { Text(summary).font(.subheadline) }
                KeepAllCheckedButton(items: items) { model.keepAllChecked(layer, .proposal) }
                ForEach(items) { item in
                    DraftItemRow(model: model, item: item, layer: layer, editing: $editing)
                }
            }
        } header: {
            Text("Found in this manual")
        }
    }
}

/// Paste and check: the prompt kit, the paste field, and the rows it read.
@MainActor
private struct DraftPasteSection: View {
    @ObservedObject var model: DraftReviewModel
    let layer: DraftLayer
    @Binding var editing: DraftReviewView.EditTarget?
    @FocusState private var pasteFocused: Bool

    var body: some View {
        let items = model.items(layer, .pasted)
        let unparsed = model.unparsed[layer] ?? []
        Section {
            Text("Paste this into your own AI with the manual, then paste its answer back here.")
                .font(.footnote)
            Button {
                model.copyPrompt(layer)
            } label: {
                if model.promptCopied == layer {
                    Label("Prompt copied", systemImage: "checkmark")
                } else {
                    Label("Copy prompt", systemImage: "doc.on.doc")
                }
            }
            .accessibilityIdentifier("draftReview.copyPrompt")
            ZStack(alignment: .topLeading) {
                if (model.pasteText[layer] ?? "").isEmpty {
                    Text("Paste the answer here")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8).padding(.leading, 5)
                        .accessibilityHidden(true)
                }
                TextEditor(text: Binding(get: { model.pasteText[layer] ?? "" }, set: { model.pasteText[layer] = $0 }))
                    .font(.system(.footnote, design: .monospaced))
                    .frame(minHeight: 120)
                    .focused($pasteFocused)
                    .accessibilityLabel(Text("Pasted answer"))
                    .accessibilityIdentifier("draftReview.paste")
            }
            Button("Check pasted rows") {
                pasteFocused = false
                model.checkPaste(layer)
            }
                .disabled((model.pasteText[layer] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("draftReview.check")
            if !items.isEmpty {
                KeepAllCheckedButton(items: items) { model.keepAllChecked(layer, .pasted) }
                ForEach(items) { item in
                    DraftItemRow(model: model, item: item, layer: layer, editing: $editing)
                }
            }
            ForEach(unparsed, id: \.line) { line in
                UnparsedLineRow(line: line)
            }
        } header: {
            Text("Paste from your own AI")
        } footer: {
            Text("The phone sends nothing anywhere. Lines that don't fit the format are shown as they are, never dropped.")
        }
    }
}

private struct KeepAllCheckedButton: View {
    let items: [DraftReviewItem]
    let action: () -> Void

    var body: some View {
        let count = DraftReview.keepAllChecked(items).count
        Button(action: action) {
            if count == 0 {
                Label("Keep all checked", systemImage: "checkmark.circle")
            } else {
                Label("Keep all checked (\(count))", systemImage: "checkmark.circle")
            }
        }
        .disabled(count == 0)
    }
}

/// A line of the pasted answer the parser could not read as a row.
private struct UnparsedLineRow: View {
    let line: ParsedDraft.Unparsed

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            OGStatusLabel("Not read as a row · line \(line.line)", kind: .warn)
            Text(verbatim: line.text).font(.system(.caption, design: .monospaced))
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("draftReview.unparsed.\(line.line)")
    }
}

/// One row, its check, and what can be done with it.
@MainActor
private struct DraftItemRow: View {
    @ObservedObject var model: DraftReviewModel
    let item: DraftReviewItem
    let layer: DraftLayer
    @Binding var editing: DraftReviewView.EditTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: DraftRowText.summary(item.row))
                .font(.subheadline)
                .strikethrough(item.state == .skipped)
            DraftMarkLabel(item: item, labels: model.manual?.pageText.labels ?? PageLabelMap([]))
            actions
        }
        // No identifier on the row itself: on a stack it would replace its buttons' own.
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var actions: some View {
        switch item.state {
        case .kept:
            if let kept = item.kept {
                OGStatusLabel("Kept in \(kept.file)", kind: .ok)
                    .accessibilityIdentifier("draftReview.kept.\(DraftRowText.identifier(item.row))")
            }
        case .skipped:
            Button("Undo skip") { model.reopen(item.id, layer: layer) }
                .font(.caption).buttonStyle(.borderless)
        case .open:
            HStack(spacing: 16) {
                if case .foundOnAnotherPage(let page) = item.outcome.mark {
                    Button("Use page \(page)") { model.takeFoundPage(item.id, layer: layer) }
                }
                Button("Keep") { model.keep(item.id, layer: layer) }
                    .disabled(item.keepPage == nil)
                    .accessibilityIdentifier("draftReview.keep.\(DraftRowText.identifier(item.row))")
                Button("Edit") { editing = .init(item: item, layer: layer) }
                Button("Skip") { model.skip(item.id, layer: layer) }
            }
            .font(.caption)
            .buttonStyle(.borderless)
        }
    }
}

/// The check's mark, with the page it is about.
private struct DraftMarkLabel: View {
    let item: DraftReviewItem
    let labels: PageLabelMap

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            OGStatusLabel(DraftRowText.mark(item.outcome, labels: labels), kind: kind)
            if item.inManualsWords {
                OGStatusLabel("In the manual's words · rewrite it before you publish", kind: .warn,
                              systemImage: "quote.opening")
            }
            if let once = item.outcome.mentionedOnce {
                Text("Mentioned once, \(DraftReview.pageText(once, labels: labels))").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var kind: OGStatusLabel.Kind {
        switch item.outcome.mark {
        case .checked: return .ok
        case .sectionChecked, .foundOnAnotherPage, .foundOnPages, .pageTextUnclear: return .warn
        case .notFound: return .error
        }
    }
}

/// How a row and its check read on the screen.
enum DraftRowText {

    static func summary(_ row: DraftRow) -> String {
        switch row {
        case .faultCode(let code):
            return "\(code.code) · \(code.label) · p. \(code.page.cited)"
        case .model(let model):
            let aliases = model.aliases.isEmpty ? "" : " (\(model.aliases.joined(separator: ", ")))"
            return model.model + aliases + (model.page.map { " · p. \($0.cited)" } ?? "")
        case .symptom(let symptom):
            return "\(symptom.symptom) · \(symptom.cause) · \(symptom.check) · p. \(symptom.page.cited)"
        }
    }

    /// A stable accessibility suffix: the row's code, model or symptom, letters and digits only.
    static func identifier(_ row: DraftRow) -> String {
        let text: String
        switch row {
        case .faultCode(let code): text = code.code
        case .model(let model): text = model.model
        case .symptom(let symptom): text = symptom.symptom
        }
        return VaultExpects.slug(text)
    }

    static func mark(_ outcome: DraftRowCheck.Outcome, labels: PageLabelMap) -> String {
        let page = outcome.page.map { DraftReview.pageText($0, labels: labels) }
        switch outcome.mark {
        case .checked:
            return page.map { String(localized: "Checked · \($0)") } ?? String(localized: "Checked")
        case .foundOnAnotherPage(let other):
            return String(localized: "Found on \(DraftReview.pageText(other, labels: labels)) · tap Use page \(other) to accept")
        case .foundOnPages(let pages):
            return String(localized: "Found on pages \(pages.map(String.init).joined(separator: ", ")) · edit the row to choose one")
        case .notFound:
            if !outcome.missingSpellings.isEmpty {
                return String(localized: "Not in this manual: \(outcome.missingSpellings.joined(separator: ", "))")
            }
            if !outcome.missingCodes.isEmpty {
                return String(localized: "Not in this manual: \(outcome.missingCodes.joined(separator: ", "))")
            }
            return String(localized: "Not found in this manual")
        case .sectionChecked:
            return page.map { String(localized: "Section checked · wording is yours · \($0)") }
                ?? String(localized: "Section checked · wording is yours")
        case .pageTextUnclear:
            return page.map { String(localized: "Page text unclear · \($0) · check it yourself") }
                ?? String(localized: "Page text unclear · check it yourself")
        }
    }
}

/// Editing one row: each of its fields, and its page.
@MainActor
private struct DraftRowEditor: View {
    let row: DraftRow
    let onSave: (DraftRow) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var first = ""
    @State private var second = ""
    @State private var third = ""
    @State private var page = ""

    var body: some View {
        NavigationStack {
            Form {
                switch row {
                case .faultCode:
                    TextField("Code", text: $first)
                    TextField("What it means, in your words", text: $second, axis: .vertical)
                case .model:
                    TextField("Model number", text: $first)
                    TextField("Other spellings, comma-separated", text: $second)
                case .symptom:
                    TextField("What the technician says", text: $first, axis: .vertical)
                    TextField("Likely cause", text: $second, axis: .vertical)
                    TextField("First check", text: $third, axis: .vertical)
                }
                TextField("Page", text: $page)
                    .keyboardType(.numbersAndPunctuation)
            }
            .diagnosticScreen()
            .navigationTitle("Edit row")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let edited { onSave(edited); dismiss() }
                    }
                    .disabled(edited == nil)
                }
            }
            .onAppear(perform: fill)
        }
    }

    private func fill() {
        switch row {
        case .faultCode(let code): first = code.code; second = code.label; page = code.page.cited
        case .model(let model): first = model.model; second = model.aliases.joined(separator: ", "); page = model.page?.cited ?? ""
        case .symptom(let symptom): first = symptom.symptom; second = symptom.cause; third = symptom.check; page = symptom.page.cited
        }
    }

    /// The edited row, or nil while a field it needs is empty or the page is not a page.
    private var edited: DraftRow? {
        let one = first.trimmingCharacters(in: .whitespacesAndNewlines)
        let two = second.trimmingCharacters(in: .whitespacesAndNewlines)
        let three = third.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedPage = DraftPage.parse(page)
        switch row {
        case .faultCode:
            guard !one.isEmpty, !two.isEmpty, let parsedPage else { return nil }
            return .faultCode(FaultCodeRow(code: one, label: two, page: parsedPage))
        case .model:
            guard !one.isEmpty else { return nil }
            let aliases = two.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return .model(ModelRow(model: one, aliases: aliases, page: page.isEmpty ? nil : parsedPage))
        case .symptom:
            guard !one.isEmpty, !two.isEmpty, !three.isEmpty, let parsedPage else { return nil }
            return .symptom(SymptomRow(symptom: one, cause: two, check: three, page: parsedPage))
        }
    }
}
