import SwiftUI

/// Settings view for managing guided task playbooks.
struct PlaybooksSettingsView: View {
    @ObservedObject var store: PlaybookStore
    @State private var showingEditor = false
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
                        Button("Stop") {
                            _ = store.finishPlaybook()
                        }
                        .foregroundStyle(.red)
                    }
                } header: {
                    Text("Active Playbook")
                }
            }

            Section {
                ForEach(store.playbooks) { playbook in
                    Button {
                        editingPlaybook = playbook
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: playbook.icon)
                                .font(.title3)
                                .foregroundStyle(.primary)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(playbook.name)
                                    .foregroundStyle(.primary)
                                HStack(spacing: 8) {
                                    Text("\(playbook.steps.count) steps")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if !playbook.referenceText.isEmpty {
                                        Text("has reference")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(.quaternary, in: Capsule())
                                    }
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    for idx in offsets {
                        store.delete(id: store.playbooks[idx].id)
                    }
                }
            } header: {
                Text("Playbooks")
            } footer: {
                Text("Say \"start [playbook name]\" to begin a guided workflow. The agent walks you through each step and can reference attached materials.")
            }

            Section {
                Button {
                    editingPlaybook = Playbook(name: "", steps: [])
                    showingEditor = true
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

// MARK: - Editor

struct PlaybookEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: PlaybookStore
    let playbook: Playbook

    @State private var name: String = ""
    @State private var icon: String = "list.clipboard"
    @State private var steps: [PlaybookStep] = []
    @State private var referenceText: String = ""

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
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("Step \(index + 1) title", text: $steps[index].title)
                                .font(.body.weight(.medium))
                            TextField("Detail (optional)", text: $steps[index].detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { offsets in
                        steps.remove(atOffsets: offsets)
                    }
                    .onMove { from, to in
                        steps.move(fromOffsets: from, toOffset: to)
                    }

                    Button {
                        steps.append(PlaybookStep(title: ""))
                    } label: {
                        Label("Add Step", systemImage: "plus")
                    }
                } header: {
                    Text("Steps")
                }

                Section {
                    TextEditor(text: $referenceText)
                        .frame(minHeight: 100)
                        .font(.system(.caption, design: .monospaced))
                } header: {
                    Text("Reference Material")
                } footer: {
                    Text("Paste manual text, procedures, or specs. The agent uses this as context when answering questions during the playbook.")
                }
            }
            .navigationTitle(isNew ? "New Playbook" : "Edit Playbook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        savePlaybook()
                        dismiss()
                    }
                    .disabled(name.isEmpty || steps.filter({ !$0.title.isEmpty }).isEmpty)
                }
            }
            .onAppear {
                name = playbook.name
                icon = playbook.icon
                steps = playbook.steps.isEmpty ? [PlaybookStep(title: "")] : playbook.steps
                referenceText = playbook.referenceText
            }
        }
    }

    private func savePlaybook() {
        let cleanSteps = steps.filter { !$0.title.isEmpty }
        var pb = playbook
        pb.name = name
        pb.icon = icon
        pb.steps = cleanSteps
        pb.referenceText = referenceText

        if isNew {
            pb = Playbook(name: name, icon: icon, steps: cleanSteps, referenceText: referenceText)
            store.add(pb)
        } else {
            store.update(pb)
        }
    }
}
