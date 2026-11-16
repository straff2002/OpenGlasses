import SwiftUI

/// Plan LW §6 — the vault check: the trade's starter questions and the author's own, each with the
/// manual and page that should answer it, asked of the vault's own retrieval on the phone. *"18 of 20
/// questions find the right page"*, with each miss and what was found instead. It runs when the
/// screen opens (so it reflects the manuals and files as they are now) and on *Run check*.
@MainActor
struct VaultCheckView: View {
    @EnvironmentObject private var appState: AppState
    let vaultId: String

    @State private var record: VaultAuthoringRecord?
    @State private var score: VaultCheck.Score?
    @State private var newText = ""
    @State private var newFile: String?
    @State private var newPage = ""

    private var manifest: VaultManifest? { VaultImporter.installedManifest(id: vaultId) }
    private var template: TradeTemplate { manifest.map(VaultAuthoring.template(for:)) ?? .general }

    var body: some View {
        Form {
            scoreSection
            if let score, !score.misses.isEmpty { missesSection(score) }
            starterSection
            ownSection
        }
        .navigationTitle("Vault check")
        .navigationBarTitleDisplayMode(.inline)
        .ogFormStyle()
        .onAppear {
            record = VaultAuthoringRecord.load(vaultId: vaultId) ?? VaultAuthoringRecord(template: template.id.rawValue)
            run()
        }
    }

    // MARK: - Sections

    private var scoreSection: some View {
        Section {
            if let score {
                if score.asked == 0 {
                    Text("Give a question the manual and page that answer it, and the check can score it.")
                } else {
                    Text("\(score.found) of \(score.asked) questions find the right page").font(.headline)
                        .accessibilityIdentifier("vaultCheck.score")
                }
                if !score.withoutPage.isEmpty {
                    Text("\(score.withoutPage.count) questions have no page yet and aren't scored.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Button("Run check") { run() }
            if let record {
                Stepper(value: Binding(get: { record.threshold }, set: { value in mutate(rerun: false) { $0.threshold = value } }),
                        in: 0.5...1, step: 0.05) {
                    Text("Publishing bar: \(Int((record.threshold * 100).rounded()))%")
                }
            }
        } footer: {
            Text("The check asks each question of this vault's own search on this phone, with no AI and no network, and looks for the expected page among the first passages it finds. Exports for publishing warn below your bar.")
        }
    }

    private func missesSection(_ score: VaultCheck.Score) -> some View {
        Section("Not finding the right page") {
            ForEach(Array(score.misses.enumerated()), id: \.offset) { _, miss in
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: miss.question.text).font(.subheadline)
                    Text("Expected \(pages(miss.question.expected.map { ($0.key, $0.page) }))")
                        .font(.caption).foregroundStyle(.secondary)
                    if miss.foundInstead.isEmpty {
                        Text("Found nothing").font(.caption).foregroundStyle(OGTheme.errorLabel)
                    } else {
                        Text("Found instead: \(pages(miss.foundInstead.compactMap { passage in passage.pages.first.map { (passage.key, $0) } }))")
                            .font(.caption).foregroundStyle(OGTheme.errorLabel)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var starterSection: some View {
        Section {
            ForEach(template.checkQuestions, id: \.text) { question in
                QuestionAnswerRow(text: question.text, documents: manifest?.documents ?? [], manifest: manifest,
                                  answer: Binding(get: { record?.starterAnswers[question.text] },
                                                  set: { value in mutate(rerun: false) { $0.starterAnswers[question.text] = value } }))
            }
        } header: {
            Text("Starter questions")
        } footer: {
            Text("For each, say which manual and page answer it in your manuals.")
        }
    }

    private var ownSection: some View {
        Section("Your questions") {
            ForEach(record?.questions ?? []) { question in
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: question.text)
                    Text(verbatim: "\(question.key) p. \(question.page)").font(.caption).foregroundStyle(.secondary)
                }
                .swipeActions {
                    Button("Delete", role: .destructive) {
                        mutate { record in record.questions.removeAll { $0.id == question.id } }
                    }
                }
            }
            TextField("A question a technician would ask", text: $newText, axis: .vertical)
            Picker("Manual", selection: $newFile) {
                Text("Choose a manual").tag(String?.none)
                ForEach(manifest?.documents ?? [], id: \.file) { document in
                    Text(verbatim: document.title).tag(String?.some(document.file))
                }
            }
            TextField("PDF page that answers it", text: $newPage).keyboardType(.numberPad)
            Button("Add question") { addQuestion() }
                .disabled(newText.trimmingCharacters(in: .whitespaces).isEmpty || newFile == nil || Int(newPage) == nil)
        }
    }

    // MARK: - Actions

    private func pages(_ refs: [(String, Int)]) -> String {
        refs.map { "\($0.0) p. \($0.1)" }.joined(separator: ", ")
    }

    /// Change the record, save it, and score again.
    private func mutate(rerun: Bool = true, _ change: (inout VaultAuthoringRecord) -> Void) {
        guard var current = record else { return }
        change(&current)
        record = current
        try? current.save(vaultId: vaultId)
        if rerun { run() }
    }

    private func addQuestion() {
        guard let manifest, let file = newFile, let page = Int(newPage),
              let document = manifest.documents.first(where: { $0.file == file }) else { return }
        let question = VaultAuthoringRecord.Question(text: newText.trimmingCharacters(in: .whitespacesAndNewlines),
                                                     key: VaultAuthoring.key(for: document, in: manifest), page: page)
        mutate { $0.questions.append(question) }
        newText = ""; newPage = ""
    }

    private func run() {
        guard let manifest else { return }
        let documentStore = appState.documentStore
        let questions = VaultCheckRunner.questions(template: template, record: record)
        let result = VaultCheckRunner.run(manifest: manifest, documentStore: documentStore, questions: questions)
        score = result
        if var current = record {
            current.lastCheck = result.asked == 0 ? nil : .init(asked: result.asked, found: result.found)
            record = current
            try? current.save(vaultId: vaultId)
        }
    }
}

/// One starter question and the manual and page the author says answer it.
private struct QuestionAnswerRow: View {
    let text: String
    let documents: [VaultDocument]
    let manifest: VaultManifest?
    @Binding var answer: VaultAuthoringRecord.PageAnswer?

    @State private var file: String?
    @State private var page = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: text).font(.subheadline)
            HStack {
                Picker("Manual", selection: $file) {
                    Text("No page yet").tag(String?.none)
                    ForEach(documents, id: \.file) { document in
                        Text(verbatim: document.title).tag(String?.some(document.file))
                    }
                }
                .labelsHidden()
                TextField("Page", text: $page)
                    .keyboardType(.numberPad)
                    .frame(maxWidth: 70)
                    .textFieldStyle(.roundedBorder)
            }
        }
        .onAppear {
            guard let answer, let manifest else { return }
            file = manifest.documents.first { VaultAuthoring.key(for: $0, in: manifest) == answer.key }?.file
            page = String(answer.page)
        }
        .onChange(of: file) { _, _ in commit() }
        .onChange(of: page) { _, _ in commit() }
    }

    private func commit() {
        guard let manifest, let file, let number = Int(page),
              let document = manifest.documents.first(where: { $0.file == file }) else {
            if file == nil, answer != nil { answer = nil }
            return
        }
        let next = VaultAuthoringRecord.PageAnswer(key: VaultAuthoring.key(for: document, in: manifest), page: number)
        if next != answer { answer = next }
    }
}
