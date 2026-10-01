import SwiftUI

/// Settings → AI & Personality → Memory: every fact Avenkin keeps about the wearer, grouped the way
/// people think about them, each with where it came from, Correct and Forget.
struct MemoryView: View {
    @StateObject private var model: MemoryScreenModel

    init(model: @autoclosure @escaping () -> MemoryScreenModel) {
        _model = StateObject(wrappedValue: model())
    }

    var body: some View {
        Form {
            if !model.statusMessages.isEmpty {
                Section {
                    ForEach(model.statusMessages, id: \.self) { message in
                        OGNotice(text: message, systemImage: "lock")
                            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    }
                }
            }

            if model.showsEmptyState {
                ContentUnavailableView {
                    Label("Nothing saved yet", systemImage: "brain.head.profile")
                } description: {
                    Text("Say \u{201C}remember that…\u{201D} and Avenkin will keep it here, where you can correct or forget it.")
                }
            } else if model.sections.isEmpty {
                ContentUnavailableView.search(text: model.query)
            }

            ForEach(model.sections) { section in
                if section.collapsedByDefault {
                    Section {
                        DisclosureGroup(isExpanded: $model.healthExpanded) {
                            rows(section.facts)
                        } label: {
                            Text(verbatim: "\(MemoryScreenModel.title(for: section.group)) (\(section.facts.count))")
                        }
                    }
                } else {
                    Section {
                        rows(section.facts)
                    } header: {
                        Text(verbatim: MemoryScreenModel.title(for: section.group))
                    }
                }
            }

            Section {
                EmptyView()
            } footer: {
                Text("Stored on this iPhone. Forgetting removes a fact from every place Avenkin keeps it and says where a copy may remain. Conversations are kept separately in History.")
            }
        }
        .navigationTitle("Memory")
        .searchable(text: $model.query, prompt: Text("Search memory"))
        .ogFormStyle()
        .onAppear { model.reload() }
        .refreshable { model.reload() }
        .sheet(item: Binding(get: { model.pendingForget.map(ForgetSheetItem.init) },
                             set: { if $0 == nil { model.cancelForget() } })) { item in
            MemoryForgetSheet(plan: item.plan, removeNoteLines: $model.removeNoteLines,
                              onCancel: { model.cancelForget() },
                              onConfirm: { Task { await model.confirmForget() } })
        }
        .alert(model.lastForget?.verified == false ? Text("Not forgotten") : Text("Forgotten"),
               isPresented: Binding(get: { model.lastForget != nil },
                                    set: { if !$0 { model.lastForget = nil } }),
               presenting: model.lastForget) { result in
            if result.conversationThreadID != nil {
                Button("Delete that conversation", role: .destructive) {
                    Task { await model.deleteOriginatingConversation() }
                }
                Button("Keep the conversation", role: .cancel) { model.lastForget = nil }
            } else {
                Button("OK", role: .cancel) { model.lastForget = nil }
            }
        } message: { result in
            Text(verbatim: result.summary)
        }
    }

    @ViewBuilder
    private func rows(_ facts: [MemoryFact]) -> some View {
        ForEach(facts) { fact in
            NavigationLink {
                MemoryFactDetailView(model: model, factID: fact.id)
            } label: {
                MemoryFactRow(fact: fact)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if fact.capabilities.contains(.forget) {
                    Button(role: .destructive) {
                        model.requestForget(fact)
                    } label: {
                        Label("Forget", systemImage: "trash")
                    }
                }
            }
        }
    }
}

private struct ForgetSheetItem: Identifiable {
    let plan: MemoryForgetPlan
    var id: MemoryFactID { plan.fact.id }
}

/// One fact: its text, then where it came from and when. The "inferred" badge marks what the
/// assistant decided on its own.
struct MemoryFactRow: View {
    let fact: MemoryFact

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: fact.text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                if fact.origin.isInferred {
                    OGBadge(text: "Inferred")
                }
                OGChip(text: MemoryScreenModel.storeLabel(fact.id.store))
                if fact.createdAt > .distantPast {
                    Text(fact.createdAt, format: .dateTime.day().month(.abbreviated).year())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(MemoryScreenModel.accessibilityLabel(for: fact))
    }
}

/// A fact in full: where it came from, when, and the actions its store supports.
struct MemoryFactDetailView: View {
    @ObservedObject var model: MemoryScreenModel
    @State private var factID: MemoryFactID
    @State private var draft = ""
    @Environment(\.dismiss) private var dismiss

    init(model: MemoryScreenModel, factID: MemoryFactID) {
        self.model = model
        _factID = State(initialValue: factID)
    }

    var body: some View {
        Form {
            if let fact = model.fact(factID) {
                Section {
                    Text(verbatim: fact.text)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Section {
                    LabeledContent("Came from") {
                        Text(verbatim: MemoryScreenModel.originLabel(fact.origin))
                    }
                    LabeledContent("Kind") {
                        Text(verbatim: MemoryScreenModel.storeLabel(fact.id.store))
                    }
                    if fact.createdAt > .distantPast {
                        LabeledContent("Saved") {
                            Text(fact.createdAt, format: .dateTime.day().month().year())
                        }
                    }
                    if let persona = fact.persona {
                        LabeledContent("Persona") { Text(verbatim: persona) }
                    }
                } header: {
                    Text("Where it came from")
                }

                if fact.capabilities.contains(.correct) {
                    Section {
                        TextField("Correct value", text: $draft, axis: .vertical)
                            .onAppear { if draft.isEmpty { draft = fact.correctableValue } }
                        Button("Save correction") {
                            let result = model.correct(fact, to: draft)
                            if let newID = result.newID { factID = newID }
                        }
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || draft == fact.correctableValue)
                        if model.lastCorrectionFailed {
                            Text("That couldn't be saved. Nothing was changed.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("Correct")
                    } footer: {
                        Text("The old value is replaced, not kept as history.")
                    }
                }

                if fact.capabilities.contains(.forget) {
                    Section {
                        Button("Forget this", role: .destructive) {
                            model.requestForget(fact)
                        }
                    }
                }
            } else {
                ContentUnavailableView("Forgotten", systemImage: "checkmark.circle",
                                       description: Text("This is no longer in memory."))
            }
        }
        .navigationTitle("Memory")
        .navigationBarTitleDisplayMode(.inline)
        .ogFormStyle()
    }
}

/// Shown before a forget runs: the fact, the lines of the assistant's notes that mention it, and
/// where a copy may remain.
struct MemoryForgetSheet: View {
    let plan: MemoryForgetPlan
    @Binding var removeNoteLines: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(verbatim: plan.fact.text)
                } header: {
                    Text("Forget")
                }
                if !plan.noteLines.isEmpty {
                    Section {
                        ForEach(plan.noteLines, id: \.self) { line in
                            Text(verbatim: line).font(.callout)
                        }
                        Toggle("Also remove these lines", isOn: $removeNoteLines)
                    } header: {
                        Text("The assistant's notes mention it")
                    } footer: {
                        Text("These lines were found by matching words, so check them first.")
                    }
                }
                if plan.gatewayCopyPossible {
                    Section {
                        Text("A copy may have been sent to a connected gateway. Avenkin will ask it to delete that copy, but can't confirm it's gone.")
                            .font(.footnote)
                    }
                }
                if plan.conversationThreadID != nil {
                    Section {
                        Text("It's also in the conversation where you said it. You'll be offered the chance to delete that conversation afterwards.")
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("Forget this?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Forget", role: .destructive, action: onConfirm)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
