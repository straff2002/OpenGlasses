import SwiftUI

// MARK: - Settings List

struct PlaybooksSettingsView: View {
    @ObservedObject var store: PlaybookStore
    @State private var editingPlaybook: Playbook?

    var body: some View {
        List {
            if let session = store.activeSession, let pb = store.playbook(byId: session.playbookId) {
                Section {
                    HStack {
                        Image(systemName: pb.icon)
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pb.name)
                                .font(.headline)
                            Text("Step \(session.currentStepIndex + 1) of \(pb.steps.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Stop") { _ = store.finishPlaybook() }
                            .foregroundStyle(.red)
                    }

                    ForEach(Array(pb.steps.enumerated()), id: \.element.id) { offset, step in
                        HStack(spacing: 8) {
                            Image(systemName: stepStatusIcon(step.status, isCurrent: offset == session.currentStepIndex))
                                .foregroundStyle(stepStatusColor(step.status, isCurrent: offset == session.currentStepIndex))
                                .font(.footnote)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(step.title)
                                    .font(.subheadline)
                                    .foregroundStyle(offset == session.currentStepIndex ? .primary : .secondary)
                                if let result = step.stepResult, !result.isEmpty {
                                    Text(result)
                                        .font(.caption2)
                                        .foregroundStyle(step.status == .failed ? .red : Color(.tertiaryLabel))
                                        .lineLimit(2)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Active Playbook")
                }
            }

            Section {
                ForEach(store.playbooks) { playbook in
                    Button { editingPlaybook = playbook } label: {
                        HStack(spacing: 12) {
                            Image(systemName: playbook.icon)
                                .font(.title3)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(playbook.name)
                                HStack(spacing: 8) {
                                    Text("\(playbook.steps.count) steps")
                                        .font(.caption)
                                        .foregroundStyle(Color(.secondaryLabel))
                                    let varCount = playbook.steps.filter { !$0.outputVar.isEmpty }.count
                                    if varCount > 0 {
                                        Text("\(varCount) variable\(varCount == 1 ? "" : "s")")
                                            .font(.caption2)
                                            .foregroundStyle(Color(.secondaryLabel))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color(.tertiarySystemFill), in: Capsule())
                                    }
                                    if !playbook.referenceText.isEmpty {
                                        Text("has reference")
                                            .font(.caption2)
                                            .foregroundStyle(Color(.secondaryLabel))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color(.tertiarySystemFill), in: Capsule())
                                    }
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote)
                                .foregroundStyle(Color(.tertiaryLabel))
                        }
                    }
                    .foregroundStyle(Color(.label))
                }
                .onDelete { offsets in
                    for idx in offsets { store.delete(id: store.playbooks[idx].id) }
                }
            } header: {
                Text("Playbooks")
            } footer: {
                Text("Say \"start [playbook name]\" to begin a guided workflow. Use steps, conditions, HTTP requests, and variables to build powerful SOPs.")
            }

            Section {
                Button {
                    editingPlaybook = Playbook(name: "", steps: [])
                } label: {
                    Label("Create Playbook", systemImage: "plus.circle")
                }
            }
        }
        .navigationTitle("Playbooks")
        .sheet(item: $editingPlaybook) { playbook in
            PlaybookEditorView(store: store, playbook: playbook)
        }
    }
}

// MARK: - Step Status Helpers

private func stepStatusIcon(_ status: StepStatus, isCurrent: Bool) -> String {
    if isCurrent && status == .pending { return "arrow.right.circle.fill" }
    switch status {
    case .pending:   return "circle"
    case .completed: return "checkmark.circle.fill"
    case .failed:    return "xmark.circle.fill"
    case .skipped:   return "slash.circle"
    }
}

private func stepStatusColor(_ status: StepStatus, isCurrent: Bool) -> Color {
    if isCurrent && status == .pending { return .blue }
    switch status {
    case .pending:   return Color(.tertiaryLabel)
    case .completed: return .green
    case .failed:    return .red
    case .skipped:   return .orange
    }
}

// MARK: - Playbook Editor

struct PlaybookEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: PlaybookStore
    let playbook: Playbook

    @State private var name: String = ""
    @State private var icon: String = "list.clipboard"
    @State private var steps: [PlaybookStep] = []
    @State private var referenceText: String = ""
    @State private var showReferenceEditor = false
    @State private var showStepEditor = false
    @State private var editingStepIndex = 0

    private let iconOptions = [
        "list.clipboard", "checklist", "wrench.and.screwdriver", "fork.knife",
        "car", "airplane", "cross.case", "book", "person.3", "house",
        "camera", "music.note", "sportscourt", "leaf", "bolt"
    ]

    var isNew: Bool { playbook.name.isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section("Details") {
                    TextField("Name", text: $name)
                    Picker("Icon", selection: $icon) {
                        ForEach(iconOptions, id: \.self) { ic in
                            Label(ic, systemImage: ic).tag(ic)
                        }
                    }
                }

                Section {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                        Button {
                            editingStepIndex = index
                            showStepEditor = true
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: step.type.icon)
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(step.title.isEmpty ? "Untitled Step" : step.title)
                                        .foregroundStyle(step.title.isEmpty ? .secondary : .primary)
                                    Text(step.type.displayName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if !step.outputVar.isEmpty {
                                    Text("{{\(step.outputVar)}}")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color(.tertiarySystemFill), in: Capsule())
                                }
                                Image(systemName: "chevron.right")
                                    .font(.footnote)
                                    .foregroundStyle(Color(.tertiaryLabel))
                            }
                        }
                        .foregroundStyle(Color(.label))
                    }
                    .onDelete { offsets in steps.remove(atOffsets: offsets) }
                    .onMove { from, to in steps.move(fromOffsets: from, toOffset: to) }

                    Button {
                        steps.append(PlaybookStep(title: ""))
                        editingStepIndex = steps.count - 1
                        showStepEditor = true
                    } label: {
                        Label("Add Step", systemImage: "plus")
                    }
                } header: {
                    Text("Steps")
                } footer: {
                    Text("Tap a step to configure its type, prompts, conditions, or HTTP requests. Drag to reorder.")
                }

                Section {
                    Button {
                        showReferenceEditor = true
                    } label: {
                        HStack {
                            Text("Reference Material")
                            Spacer()
                            Text(referenceText.isEmpty ? "None" : "\(referenceText.count) chars")
                                .foregroundStyle(Color(.secondaryLabel))
                            Image(systemName: "chevron.right")
                                .font(.footnote)
                                .foregroundStyle(Color(.tertiaryLabel))
                        }
                    }
                    .foregroundStyle(Color(.label))
                } footer: {
                    Text("Paste manuals, procedures, or specs. The agent references this material during the playbook.")
                }
            }
            .navigationTitle(isNew ? "New Playbook" : "Edit Playbook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { savePlaybook(); dismiss() }
                        .disabled(name.isEmpty || steps.filter({ !$0.title.isEmpty }).isEmpty)
                }
            }
            .onAppear {
                name = playbook.name
                icon = playbook.icon
                steps = playbook.steps.isEmpty ? [PlaybookStep(title: "")] : playbook.steps
                referenceText = playbook.referenceText
            }
            .sheet(isPresented: $showStepEditor) {
                if editingStepIndex < steps.count {
                    StepEditorSheet(
                        step: $steps[editingStepIndex],
                        stepIndex: editingStepIndex,
                        allSteps: steps
                    )
                }
            }
            .sheet(isPresented: $showReferenceEditor) {
                ReferenceTextEditor(text: $referenceText)
            }
        }
    }

    private func savePlaybook() {
        let cleanSteps = steps.filter { !$0.title.isEmpty }
        if isNew {
            store.add(Playbook(name: name, icon: icon, steps: cleanSteps, referenceText: referenceText))
        } else {
            var pb = playbook
            pb.name = name
            pb.icon = icon
            pb.steps = cleanSteps
            pb.referenceText = referenceText
            store.update(pb)
        }
    }
}

// MARK: - Step Editor Sheet

struct StepEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var step: PlaybookStep
    let stepIndex: Int
    let allSteps: [PlaybookStep]

    @State private var showVarPicker = false
    @State private var varInsertBinding: WritableKeyPath<PlaybookStep, String>?

    /// Variables available from steps before this one.
    private var availableVars: [(name: String, stepTitle: String)] {
        allSteps.prefix(stepIndex).compactMap { s in
            s.outputVar.isEmpty ? nil : (name: s.outputVar, stepTitle: s.title)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Step") {
                    TextField("Title", text: $step.title)
                    Picker("Type", selection: $step.type) {
                        ForEach(StepType.allCases, id: \.self) { t in
                            Label(t.displayName, systemImage: t.icon).tag(t)
                        }
                    }
                }

                typeConfigSection

                if step.type != .condition && step.type != .wait {
                    outputVarSection
                }
            }
            .navigationTitle("Edit Step")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $showVarPicker) {
            if let keyPath = varInsertBinding {
                VariablePickerSheet(variables: availableVars) { varName in
                    step[keyPath: keyPath] += "{{\(varName)}}"
                }
            }
        }
    }

    // MARK: - Type Configuration

    @ViewBuilder
    private var typeConfigSection: some View {
        switch step.type {
        case .prompt:
            promptSection
        case .photo:
            photoSection
        case .quickAction:
            quickActionSection
        case .http:
            httpSection
        case .condition:
            conditionSection
        case .wait:
            waitSection
        }
    }

    @ViewBuilder
    private var promptSection: some View {
        Section {
            textFieldWithVarButton(text: $step.detail, keyPath: \.detail, placeholder: "What should the AI do?")
        } header: {
            Text("Prompt")
        } footer: {
            Text("The AI receives this message. Tap {{ }} to insert a variable from a previous step.")
        }
    }

    @ViewBuilder
    private var photoSection: some View {
        Section {
            textFieldWithVarButton(text: $step.detail, keyPath: \.detail, placeholder: "What should the AI do with the photo?")
        } header: {
            Text("Prompt After Photo (optional)")
        } footer: {
            Text("A photo is captured first, then this prompt is sent to the AI along with the image.")
        }
    }

    @ViewBuilder
    private var quickActionSection: some View {
        let actions = Config.quickActions
        Section("Quick Action") {
            if actions.isEmpty {
                Text("No quick actions configured")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(actions) { action in
                    Button {
                        step.quickActionId = action.id
                    } label: {
                        HStack {
                            Image(systemName: action.icon)
                                .frame(width: 24)
                                .foregroundStyle(.secondary)
                            Text(action.label)
                            Spacer()
                            if step.quickActionId == action.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                    .foregroundStyle(Color(.label))
                }
            }
        }
    }

    @ViewBuilder
    private var httpSection: some View {
        Section("Request") {
            Picker("Method", selection: $step.httpMethod) {
                ForEach(["GET", "POST", "PUT", "PATCH", "DELETE"], id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.segmented)

            HStack {
                TextField("https://api.example.com/path", text: $step.httpURL)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                varInsertButton(keyPath: \.httpURL)
            }
        }

        if step.httpMethod != "GET" && step.httpMethod != "DELETE" {
            Section {
                textFieldWithVarButton(text: $step.httpBody, keyPath: \.httpBody, placeholder: "{ \"key\": \"{{variable}}\" }")
            } header: {
                Text("Body")
            } footer: {
                Text("JSON body. Use {{variable}} to insert values from previous steps.")
            }
        }
    }

    @ViewBuilder
    private var conditionSection: some View {
        Section {
            // Variable
            HStack {
                Text("If")
                    .foregroundStyle(.secondary)
                    .frame(width: 24, alignment: .leading)
                TextField("variable", text: $step.conditionVariable)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if !availableVars.isEmpty {
                    Menu {
                        ForEach(availableVars, id: \.name) { v in
                            Button {
                                step.conditionVariable = v.name
                            } label: {
                                Label("{{\(v.name)}} — \(v.stepTitle)", systemImage: "curlybraces")
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.up.chevron.down")
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }

            // Operator
            Picker("Operator", selection: $step.conditionOperator) {
                ForEach(ConditionOperator.allCases, id: \.self) { op in
                    Text(op.displayName).tag(op)
                }
            }

            // Value
            if step.conditionOperator.needsValue {
                TextField("value to compare", text: $step.conditionValue)
                    .autocorrectionDisabled()
            }
        } header: {
            Text("Condition")
        } footer: {
            Text("Evaluated automatically. Enter the variable name without braces.")
        }

        Section("Branches") {
            stepJumpRow(label: "If true →", selection: $step.conditionThenStep)
            stepJumpRow(label: "If false →", selection: $step.conditionElseStep)
        }
    }

    @ViewBuilder
    private var waitSection: some View {
        Section("Wait") {
            Stepper(
                "\(step.waitSeconds) second\(step.waitSeconds == 1 ? "" : "s")",
                value: $step.waitSeconds,
                in: 1...3600
            )
        }
    }

    // MARK: - Output Variable

    @ViewBuilder
    private var outputVarSection: some View {
        Section {
            HStack {
                Text("{{")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                TextField("variable_name", text: $step.outputVar)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Text("}}")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Save Result As")
        } footer: {
            if step.outputVar.isEmpty {
                Text("Optional. Name this step's output so later steps can use it with {{variable_name}}.")
            } else {
                Text("Later steps can reference this result with {{\(step.outputVar)}}.")
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func textFieldWithVarButton(text: Binding<String>, keyPath: WritableKeyPath<PlaybookStep, String>, placeholder: String) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            TextEditor(text: text)
                .frame(minHeight: 80)
                .font(.body)
                .scrollContentBackground(.hidden)
            varInsertButton(keyPath: keyPath)
        }
    }

    @ViewBuilder
    private func varInsertButton(keyPath: WritableKeyPath<PlaybookStep, String>) -> some View {
        if !availableVars.isEmpty {
            Button {
                varInsertBinding = keyPath
                showVarPicker = true
            } label: {
                Label("Insert Variable", systemImage: "curlybraces")
                    .font(.caption)
            }
        }
    }

    @ViewBuilder
    private func stepJumpRow(label: String, selection: Binding<Int>) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Menu {
                Button("Next step (default)") { selection.wrappedValue = -1 }
                if allSteps.count > 1 { Divider() }
                ForEach(Array(allSteps.enumerated()), id: \.offset) { idx, s in
                    if idx != stepIndex {
                        Button("Step \(idx + 1): \(s.title.isEmpty ? "Untitled" : s.title)") {
                            selection.wrappedValue = idx
                        }
                    }
                }
            } label: {
                if selection.wrappedValue == -1 {
                    Text("Next step")
                        .foregroundStyle(.secondary)
                } else if selection.wrappedValue < allSteps.count {
                    Text("Step \(selection.wrappedValue + 1): \(allSteps[selection.wrappedValue].title)")
                        .foregroundStyle(Color.accentColor)
                } else {
                    Text("Next step")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Variable Picker Sheet

struct VariablePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let variables: [(name: String, stepTitle: String)]
    let onSelect: (String) -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(variables, id: \.name) { v in
                    Button {
                        onSelect(v.name)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("{{\(v.name)}}")
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.primary)
                            Text("from: \(v.stepTitle)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(Color(.label))
                }
            }
            .navigationTitle("Insert Variable")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Reference Text Editor

struct ReferenceTextEditor: View {
    @Binding var text: String
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .font(.body)
                .padding(.horizontal, 4)
                .focused($isFocused)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        if !text.isEmpty {
                            Button(role: .destructive) { text = "" } label: {
                                Label("Clear", systemImage: "trash")
                            }
                        }
                    }
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") { isFocused = false }
                    }
                }
                .navigationTitle("Reference Material")
                .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear { isFocused = true }
    }
}
