import SwiftUI
import UIKit

/// Plan MN P3 — one procedure on the authoring screen: each step's typed answer, each route's
/// sentence with its rule beside it, the validator's issues and warnings where they belong, and
/// whether the procedure runs with no assistant. A reply from the author's own AI (the
/// *conditions to rules* prompt kit) lands as suggestions beside the sentence each is for, accepted
/// or rejected one by one. Nothing reaches the vault until *Save*.
@MainActor
struct ProcedureRulesView: View {
    let vaultId: String
    let file: String
    var title: String = ""
    /// The screenshot launch's procedure and pasted reply, drawn without a vault.
    var fixture: Procedure? = nil
    var fixturePaste: String? = nil

    @StateObject private var model = ProcedureRulesModel()
    @State private var editingAnswer: AnswerTarget?
    @State private var editingRule: RuleTarget?

    struct AnswerTarget: Identifiable {
        let stepId: String
        var id: String { stepId }
    }

    struct RuleTarget: Identifiable {
        let stepId: String
        let branchId: String
        var id: String { "\(stepId)#\(branchId)" }
    }

    var body: some View {
        Form {
            if let review = model.review {
                ReadinessSection(editing: review.editing)
                if let message = model.message { Section { OGStatusLabel(message, kind: .ok) } }
                if let error = model.errorMessage { Section { OGStatusLabel(error, kind: .error) } }
                MessagesSection(messages: review.editing.procedureMessages)
                RuleKitSection(model: model, review: review)
                ForEach(Array(review.procedure.steps.enumerated()), id: \.element.id) { index, step in
                    StepSection(model: model, review: review, step: step, number: index + 1,
                                editingAnswer: $editingAnswer, editingRule: $editingRule)
                }
            } else {
                Section {
                    Text("This procedure couldn't be read from the vault.").foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(title.isEmpty ? Text("Procedure") : Text(verbatim: title))
        .navigationBarTitleDisplayMode(.inline)
        .ogFormStyle()
        .scrollDismissesKeyboard(.interactively)
        .onAppear {
            guard model.review == nil else { return }
            model.load(vaultId: vaultId, file: file, fixture: fixture)
            if let fixturePaste {
                model.pasteText = fixturePaste
                model.checkReply()
            }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { model.save() }
                    .disabled(!(model.review?.editing.canSave ?? false))
                    .accessibilityIdentifier("procedureRules.save")
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { hideKeyboard() }
            }
        }
        .sheet(item: $editingAnswer) { target in
            if let review = model.review, let step = review.editing.step(target.stepId) {
                StepAnswerEditor(editing: review.editing, step: step) { answer in
                    model.setAnswer(answer, onStep: target.stepId)
                }
            }
        }
        .sheet(item: $editingRule) { target in
            if let review = model.review, let step = review.editing.step(target.stepId),
               let branch = step.branches.first(where: { $0.id == target.branchId }) {
                BranchRuleEditor(editing: review.editing, step: step, branch: branch) { rule in
                    model.setRule(rule, branch: target.branchId, step: target.stepId)
                }
            }
        }
    }
}

@MainActor
private func hideKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

// MARK: - Runs with no assistant

private struct ReadinessSection: View {
    let editing: ProcedureEditing

    var body: some View {
        let blockers = editing.readiness
        Section {
            if blockers.isEmpty {
                OGStatusLabel("Runs with no assistant", kind: .ok)
                    .accessibilityIdentifier("procedureRules.readiness")
            } else {
                OGStatusLabel("Needs an assistant", kind: .warn)
                    .accessibilityIdentifier("procedureRules.readiness")
                ForEach(blockers, id: \.stepId) { blocker in
                    Text("Step \(blocker.stepNumber) \(blocker.kind.localized)")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text("Nothing changes in the vault until you save. Every edit is checked here as the importer checks it.")
        }
    }
}

/// The validator's issues and warnings, as it words them.
private struct MessagesSection: View {
    let messages: ProcedureEditing.Messages

    var body: some View {
        if !messages.isEmpty {
            Section { MessageLines(messages: messages) }
        }
    }
}

private struct MessageLines: View {
    let messages: ProcedureEditing.Messages

    var body: some View {
        ForEach(messages.issues, id: \.self) { OGStatusLabel($0, kind: .error).font(.caption) }
        ForEach(messages.warnings, id: \.self) { OGStatusLabel($0, kind: .warn).font(.caption) }
    }
}

// MARK: - The prompt kit

/// Paste and check, as the draft review screen does it: copy the prompt, run it in your own AI,
/// paste its reply back.
@MainActor
private struct RuleKitSection: View {
    @ObservedObject var model: ProcedureRulesModel
    let review: ProcedureRuleReview
    @FocusState private var pasteFocused: Bool

    var body: some View {
        Section {
            if review.hasStepsToRule {
                Text("Copy this prompt into your own AI. It turns each route's words into a rule the app can check. Paste its answer back here.")
                    .font(.footnote)
                Button {
                    model.copyPrompt()
                } label: {
                    if model.promptCopied {
                        Label("Prompt copied", systemImage: "checkmark")
                    } else {
                        Label("Copy prompt", systemImage: "doc.on.doc")
                    }
                }
                .accessibilityIdentifier("procedureRules.copyPrompt")
                ZStack(alignment: .topLeading) {
                    if model.pasteText.isEmpty {
                        Text("Paste the answer here")
                            .font(.footnote).foregroundStyle(.tertiary)
                            .padding(.top, 8).padding(.leading, 5)
                            .accessibilityHidden(true)
                    }
                    TextEditor(text: $model.pasteText)
                        .font(.system(.footnote, design: .monospaced))
                        // A reply can run to dozens of lines; the field scrolls rather than pushing
                        // the steps, where its suggestions land, off the screen.
                        .frame(minHeight: 100, maxHeight: 220)
                        .focused($pasteFocused)
                        .accessibilityLabel(Text("Pasted answer"))
                        .accessibilityIdentifier("procedureRules.paste")
                }
                Button("Check the answer") {
                    pasteFocused = false
                    model.checkReply()
                }
                .disabled(model.pasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("procedureRules.check")
            } else {
                Text("Every step that branches is decided by rules already.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if model.replyRead {
                let count = review.openSuggestionCount
                if count > 0 {
                    Group {
                        if count == 1 {
                            Text("1 suggestion, shown beside its step below.")
                        } else {
                            Text("\(count) suggestions, shown beside their steps below.")
                        }
                    }
                    .font(.subheadline)
                }
                ForEach(Array(review.rejected.enumerated()), id: \.offset) { _, rejection in
                    VStack(alignment: .leading, spacing: 2) {
                        if let stepId = rejection.stepId {
                            OGStatusLabel("Not used · step \(stepId)", kind: .warn)
                        } else {
                            OGStatusLabel("Not used", kind: .warn)
                        }
                        Text(verbatim: rejection.reason).font(.caption)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        } header: {
            Text("Rules from your own AI")
        } footer: {
            Text("The phone sends nothing anywhere. A suggestion changes nothing until you accept it and save.")
        }
    }
}

// MARK: - One step

@MainActor
private struct StepSection: View {
    @ObservedObject var model: ProcedureRulesModel
    let review: ProcedureRuleReview
    let step: Procedure.Step
    let number: Int
    @Binding var editingAnswer: ProcedureRulesView.AnswerTarget?
    @Binding var editingRule: ProcedureRulesView.RuleTarget?

    var body: some View {
        let editing = review.editing
        Section {
            Text(verbatim: step.instruction).font(.footnote).foregroundStyle(.secondary)
            answerRow
            if let suggestion = review.answerSuggestion(forStep: step.id) {
                SuggestionRow(model: model, review: review, suggestion: suggestion,
                              heading: String(localized: "Suggested answer"))
            }
            MessageLines(messages: editing.messages(forStep: step.id))
            if editing.isMixed(step.id) {
                OGStatusLabel("Some routes on this step have a rule and some don't. Give every route a rule, or remove them all.",
                              kind: .error).font(.caption)
            }
            ForEach(step.branches) { branch in
                BranchRow(model: model, review: review, step: step, branch: branch, editingRule: $editingRule)
            }
            if step.branches.contains(where: { $0.when != nil }) {
                Button("Remove the rules on this step", role: .destructive) { model.removeRules(onStep: step.id) }
                    .font(.caption).buttonStyle(.borderless)
            }
        } header: {
            Text("Step \(number) · \(step.title)")
        } footer: {
            if step.branches.count > 1 && !step.isAppDecided && !editing.isMixed(step.id) {
                Text("The person or the assistant chooses this step's route from its words. Give every route a rule and the app decides it.")
            }
        }
    }

    @ViewBuilder
    private var answerRow: some View {
        if let answer = step.answer {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: ProcedureRuleReview.describe(answer)).font(.subheadline)
                HStack(spacing: 16) {
                    Button("Edit answer") { editingAnswer = .init(stepId: step.id) }
                        .disabled(answer.kind == nil)
                    Button("Remove answer", role: .destructive) { model.setAnswer(nil, onStep: step.id) }
                }
                .font(.caption).buttonStyle(.borderless)
            }
        } else {
            Button {
                editingAnswer = .init(stepId: step.id)
            } label: {
                Label("Add an answer", systemImage: "plus.circle")
            }
            .font(.subheadline)
            .accessibilityIdentifier("procedureRules.addAnswer.\(step.id)")
        }
    }
}

/// A route: its sentence, where it goes, its rule in words, and a suggestion beside it.
@MainActor
private struct BranchRow: View {
    @ObservedObject var model: ProcedureRulesModel
    let review: ProcedureRuleReview
    let step: Procedure.Step
    let branch: Procedure.Branch
    @Binding var editingRule: ProcedureRulesView.RuleTarget?

    var body: some View {
        let editing = review.editing
        let target = editing.step(branch.next)?.title ?? branch.next
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: "“\(branch.condition)”").font(.subheadline)
            Text("Route \(branch.id) → \(target)").font(.caption).foregroundStyle(.secondary)
            if let words = editing.ruleWords(branch) {
                OGStatusLabel("Rule: \(words)", kind: .ok, systemImage: "function").font(.caption)
            } else {
                Text("Chosen from these words").font(.caption).foregroundStyle(.secondary)
            }
            MessageLines(messages: editing.messages(forBranch: branch.id, step: step.id))
            HStack(spacing: 16) {
                Button {
                    editingRule = .init(stepId: step.id, branchId: branch.id)
                } label: {
                    if branch.when == nil { Text("Add a rule") } else { Text("Edit rule") }
                }
                .accessibilityIdentifier("procedureRules.editRule.\(step.id).\(branch.id)")
                if branch.when != nil {
                    Button("Remove rule", role: .destructive) { model.setRule(nil, branch: branch.id, step: step.id) }
                }
            }
            .font(.caption).buttonStyle(.borderless)
            if let suggestion = review.ruleSuggestion(forBranch: branch.id, step: step.id) {
                SuggestionRow(model: model, review: review, suggestion: suggestion,
                              heading: String(localized: "Suggested rule"))
            }
        }
        .padding(.vertical, 2)
    }
}

/// A pending suggestion: what it proposes in words, the validator's warnings on it, Accept / Reject.
@MainActor
private struct SuggestionRow: View {
    @ObservedObject var model: ProcedureRulesModel
    let review: ProcedureRuleReview
    let suggestion: ProcedureRuleReview.Suggestion
    let heading: String

    var body: some View {
        let blocked = review.blockedReason(suggestion.id)
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(verbatim: "\(heading): \(review.words(suggestion))")
            } icon: {
                Image(systemName: "sparkles")
            }
            .font(.caption)
            .foregroundStyle(OGTheme.warnLabel)
            ForEach(suggestion.warnings, id: \.self) { OGStatusLabel($0, kind: .warn).font(.caption2) }
            if let blocked {
                Text(verbatim: blocked).font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                Button("Accept") { model.accept(suggestion.id) }
                    .disabled(blocked != nil)
                    .accessibilityIdentifier("procedureRules.accept.\(suggestion.id)")
                Button("Reject") { model.reject(suggestion.id) }
                    .accessibilityIdentifier("procedureRules.reject.\(suggestion.id)")
            }
            .font(.caption).buttonStyle(.borderless)
        }
        .padding(8)
        .background(OGTheme.warnLabel.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Editing an answer

/// The answer on one step: its kind, record name, label, whether it is required or critical, and
/// the fields of its kind. What it would do to the procedure is checked as it is typed.
@MainActor
private struct StepAnswerEditor: View {
    let editing: ProcedureEditing
    let step: Procedure.Step
    let onDone: (StepAnswer) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: AnswerDraft

    init(editing: ProcedureEditing, step: Procedure.Step, onDone: @escaping (StepAnswer) -> Void) {
        self.editing = editing
        self.step = step
        self.onDone = onDone
        _draft = State(initialValue: step.answer.flatMap { AnswerDraft($0) } ?? AnswerDraft(kind: .number))
    }

    var body: some View {
        let built = draft.build()
        NavigationStack {
            Form {
                Section {
                    Picker("Kind", selection: $draft.kind) {
                        Text("Number").tag(StepAnswer.Kind.number)
                        Text("Choice").tag(StepAnswer.Kind.choice)
                        Text("Yes or no").tag(StepAnswer.Kind.yesNo)
                        Text("Text").tag(StepAnswer.Kind.text)
                        Text("Photos").tag(StepAnswer.Kind.photo)
                        Text("Code").tag(StepAnswer.Kind.code)
                    }
                    TextField("Record name, like tank_ph", text: $draft.recordAs)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Label, like pH", text: $draft.label)
                    Toggle("Needed before the next step", isOn: $draft.required)
                    Toggle("Critical limit", isOn: $draft.critical)
                } footer: {
                    Text("The record name is what rules read and the record keeps: lowercase, with underscores. A critical answer spoken aloud is read back, and one out of spec needs a note.")
                }
                kindFields
                Section {
                    switch built {
                    case .failure(let problem):
                        OGStatusLabel(problem.message, kind: .error).font(.caption)
                    case .success(let answer):
                        let trial = trialMessages(answer)
                        if trial.isEmpty {
                            OGStatusLabel("Checks out", kind: .ok).font(.caption)
                        } else {
                            MessageLines(messages: trial)
                        }
                    }
                } header: {
                    Text("Check")
                }
            }
            .navigationTitle(step.answer == nil ? Text("Add an answer") : Text("Edit answer"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        if case .success(let answer) = built { onDone(answer); dismiss() }
                    }
                    .disabled({ if case .success = built { return false } else { return true } }())
                }
            }
        }
    }

    private func trialMessages(_ answer: StepAnswer) -> ProcedureEditing.Messages {
        var trial = editing
        trial.setAnswer(answer, onStep: step.id)
        return trial.messages(forStep: step.id)
    }

    @ViewBuilder
    private var kindFields: some View {
        switch draft.kind {
        case .number:
            Section("Number") {
                TextField("Unit, like psig", text: $draft.unit)
                Stepper("Decimal places: \(draft.decimals)", value: $draft.decimals, in: 0...3)
                RangeFields(title: String(localized: "Can be"), low: $draft.plausibleLow, high: $draft.plausibleHigh)
                RangeFields(title: String(localized: "Should be"), low: $draft.specLow, high: $draft.specHigh)
                Toggle("Show the spec on the step", isOn: $draft.showSpec)
                    .disabled(draft.specLow.isEmpty || draft.specHigh.isEmpty)
            }
        case .choice:
            Section {
                ForEach($draft.options) { $option in
                    VStack(alignment: .leading) {
                        TextField("Id, like damaged", text: $option.optionId)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("Label, like Damaged", text: $option.label)
                        TextField("Also said as, comma-separated", text: $option.says)
                    }
                }
                .onDelete { draft.options.remove(atOffsets: $0) }
                Button { draft.options.append(.init()) } label: { Label("Add an option", systemImage: "plus") }
                    .disabled(draft.options.count >= 12)
            } header: {
                Text("Options")
            } footer: {
                Text("2 to 12 options. Rules read the id; the label is what is printed and spoken.")
            }
        case .text:
            Section("Text") {
                TextField("Shortest, default 1", text: $draft.minLength).keyboardType(.numberPad)
                TextField("Longest, default 500", text: $draft.maxLength).keyboardType(.numberPad)
            }
        case .photo:
            Section("Photos") {
                TextField("Fewest, default 1", text: $draft.minPhotos).keyboardType(.numberPad)
                TextField("Most, up to 5", text: $draft.maxPhotos).keyboardType(.numberPad)
            }
        case .code:
            Section("Code") {
                Picker("Kind of code", selection: $draft.symbology) {
                    Text("Either").tag("")
                    Text("QR code").tag("qr")
                    Text("Barcode").tag("barcode")
                }
                TextField("Expected code, if one", text: $draft.expected)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
        case .yesNo:
            EmptyView()
        }
    }
}

private struct RangeFields: View {
    let title: String
    @Binding var low: String
    @Binding var high: String

    var body: some View {
        HStack {
            Text(verbatim: title)
            TextField("From", text: $low).keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing)
            Text("to")
            TextField("To", text: $high).keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing)
        }
    }
}

// MARK: - Editing a rule

/// The rule on one route: one or more tests on the procedure's answers, joined by *all* or *any*,
/// and optionally turned round with *not*. The route's sentence sits above it and the rule in words
/// below, so the two can be read against each other.
@MainActor
private struct BranchRuleEditor: View {
    let editing: ProcedureEditing
    let step: Procedure.Step
    let branch: Procedure.Branch
    let onDone: (BranchRule) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: RuleDraft?

    init(editing: ProcedureEditing, step: Procedure.Step, branch: Procedure.Branch,
         onDone: @escaping (BranchRule) -> Void) {
        self.editing = editing
        self.step = step
        self.branch = branch
        self.onDone = onDone
        let fallback = step.answer ?? editing.answers.values.sorted { $0.recordAs < $1.recordAs }.first
        // A rule shaped beyond this form starts with no draft: it is shown in words, kept as written.
        let initial: RuleDraft?
        if let rule = branch.when { initial = RuleDraft(rule) } else { initial = RuleDraft(answer: fallback) }
        _draft = State(initialValue: initial)
    }

    private var answers: [StepAnswer] {
        editing.answers.values.sorted { $0.recordAs < $1.recordAs }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(verbatim: "“\(branch.condition)”")
                    Text("Route \(branch.id)").font(.caption).foregroundStyle(.secondary)
                } header: {
                    Text("The route's words")
                }
                if answers.isEmpty {
                    Section {
                        Text("A rule reads an answer, and this procedure records none yet. Add an answer to this step first.")
                            .foregroundStyle(.secondary)
                    }
                } else if let draft {
                    ruleForm(draft)
                } else if let rule = branch.when {
                    Section {
                        Text(verbatim: BranchRuleEvaluator.words(rule, answers: editing.answers))
                        Button("Replace it with a new rule") {
                            self.draft = RuleDraft(answer: step.answer ?? answers.first)
                        }
                    } footer: {
                        Text("This rule nests more than this screen edits. It is kept as written unless you replace it.")
                    }
                }
            }
            .navigationTitle(branch.when == nil ? Text("Add a rule") : Text("Edit rule"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        if case .success(let rule)? = draft?.build(answers: editing.answers) { onDone(rule); dismiss() }
                    }
                    .disabled({ if case .success? = draft?.build(answers: editing.answers) { return false } else { return true } }())
                }
            }
        }
    }

    @ViewBuilder
    private func ruleForm(_ current: RuleDraft) -> some View {
        let binding = Binding<RuleDraft>(get: { draft ?? current }, set: { draft = $0 })
        if current.tests.count > 1 {
            Section {
                Picker("Take the route when", selection: binding.joining) {
                    Text("Every test holds").tag(RuleDraft.Joining.all)
                    Text("Any test holds").tag(RuleDraft.Joining.any)
                }
            }
        }
        ForEach(Array(current.tests.indices), id: \.self) { index in
            Section {
                TestFields(test: binding.tests[index], answers: answers)
                if current.tests.count > 1 {
                    Button("Remove this test", role: .destructive) { draft?.tests.remove(at: index) }
                        .font(.caption)
                }
            } header: {
                Text("Test \(index + 1)")
            }
        }
        Section {
            Button {
                draft?.tests.append(RuleDraft(answer: step.answer ?? answers.first).tests.first
                                    ?? .init(answer: answers.first?.recordAs ?? "", op: .present))
            } label: {
                Label("Add a test", systemImage: "plus")
            }
            .disabled(current.tests.count >= 6)
            Toggle("Take the route when this doesn't hold", isOn: binding.negated)
        }
        Section {
            switch current.build(answers: editing.answers) {
            case .failure(let problem):
                OGStatusLabel(problem.message, kind: .error).font(.caption)
            case .success(let rule):
                Text(verbatim: BranchRuleEvaluator.words(rule, answers: editing.answers))
                    .accessibilityIdentifier("procedureRules.ruleWords")
                MessageLines(messages: trialMessages(rule))
            }
        } header: {
            Text("The rule in words")
        }
    }

    private func trialMessages(_ rule: BranchRule) -> ProcedureEditing.Messages {
        var trial = editing
        trial.setRule(rule, branch: branch.id, step: step.id)
        var messages = trial.messages(forBranch: branch.id, step: step.id)
        let stepMessages = trial.messages(forStep: step.id)
        messages.issues += stepMessages.issues
        messages.warnings += stepMessages.warnings
        return messages
    }
}

/// One test: the answer it reads, the comparison, and the value in the shape the comparison takes.
private struct TestFields: View {
    @Binding var test: RuleDraft.TestDraft
    let answers: [StepAnswer]

    private var answer: StepAnswer? { answers.first { $0.recordAs == test.answer } }

    var body: some View {
        Picker("Answer", selection: $test.answer) {
            ForEach(answers, id: \.recordAs) { answer in
                Text(verbatim: "\(answer.displayLabel) (\(answer.recordAs))").tag(answer.recordAs)
            }
            if answer == nil { Text(verbatim: test.answer).tag(test.answer) }
        }
        .onChange(of: test.answer) { _, _ in
            let ops = RuleDraft.ops(for: answer)
            if !ops.contains(test.op), let first = ops.first { test.op = first }
        }
        Picker("Comparison", selection: $test.op) {
            ForEach(RuleDraft.ops(for: answer), id: \.self) { op in
                Text(Self.name(op)).tag(op)
            }
        }
        valueFields
    }

    @ViewBuilder
    private var valueFields: some View {
        switch test.op {
        case .between, .outside:
            HStack {
                TextField("From", text: $test.value).keyboardType(.numbersAndPunctuation)
                Text("to")
                TextField("To", text: $test.upper).keyboardType(.numbersAndPunctuation)
            }
        case .gt, .gte, .lt, .lte:
            TextField("Number", text: $test.value).keyboardType(.numbersAndPunctuation)
        case .eq, .ne:
            if let options = answer?.options, answer?.kind == .choice {
                Picker("Option", selection: $test.value) {
                    Text("Choose").tag("")
                    ForEach(options, id: \.id) { Text(verbatim: $0.label).tag($0.id) }
                }
            } else if answer?.kind == .number {
                TextField("Number", text: $test.value).keyboardType(.numbersAndPunctuation)
            } else {
                TextField("Value", text: $test.value)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
        case .inList:
            ForEach(answer?.options ?? [], id: \.id) { option in
                Toggle(isOn: Binding(get: { test.ids.contains(option.id) }, set: { on in
                    if on { if !test.ids.contains(option.id) { test.ids.append(option.id) } } else { test.ids.removeAll { $0 == option.id } }
                })) { Text(verbatim: option.label) }
            }
        case .isAnswer:
            Picker("Answered", selection: $test.value) {
                Text("Yes").tag("yes")
                Text("No").tag("no")
            }
            .pickerStyle(.segmented)
        case .outOfSpec:
            Toggle("Out of spec", isOn: $test.flag)
        case .present:
            Toggle("Recorded", isOn: $test.flag)
        }
    }

    static func name(_ op: BranchRule.Op) -> LocalizedStringKey {
        switch op {
        case .between: return "is between"
        case .outside: return "is outside"
        case .gt: return "is above"
        case .gte: return "is at least"
        case .lt: return "is below"
        case .lte: return "is at most"
        case .eq: return "is"
        case .ne: return "is not"
        case .inList: return "is one of"
        case .isAnswer: return "is answered"
        case .outOfSpec: return "spec"
        case .present: return "was recorded"
        }
    }
}
