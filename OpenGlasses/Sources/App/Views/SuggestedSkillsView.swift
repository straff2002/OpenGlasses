import SwiftUI

/// The review inbox for self-proposed skills (Plan AW). The evolution loop *proposes* a skill from
/// recurring tool failures; the user **approves** (→ becomes a voice skill, injected like any other) or
/// **dismisses** (recorded so it's never re-proposed). Nothing self-authored enters the prompt without
/// an explicit approval here — this view is the human-in-the-loop boundary.
@MainActor
struct SuggestedSkillsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var pending: [EvolvedSkillStore.EvolvedSkill] = EvolvedSkillStore.shared.pending()
    @State private var buildMessage: String?

    var body: some View {
        Form {
            if pending.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No Suggestions",
                        systemImage: "lightbulb.max",
                        description: Text("When the assistant repeatedly stumbles on the same kind of task (with Agent Mode on), it proposes a skill to fix it here for you to approve. Nothing is applied without your review.")
                    )
                }
            } else {
                ForEach(pending) { item in
                    if let goal = item.addOnGoal {
                        addOnIdeaRow(item, goal: goal)
                    } else {
                        voiceSkillRow(item)
                    }
                }
            }
        }
        .navigationTitle("Suggested Skills")
        .navigationBarTitleDisplayMode(.inline)
        .ogFormStyle()
        .onAppear(perform: reload)
        .alert("Add-on", isPresented: Binding(get: { buildMessage != nil }, set: { if !$0 { buildMessage = nil } })) {
            Button("OK") { buildMessage = nil }
        } message: {
            Text(buildMessage ?? "")
        }
    }

    /// "Build an add-on for: …?" — nothing is looked up or fetched until Build it.
    @ViewBuilder private func addOnIdeaRow(_ item: EvolvedSkillStore.EvolvedSkill, goal: String) -> some View {
        Section {
            Text("Build an add-on for: \(goal)?").font(.body.weight(.medium))
            Text("Your assistant would look for a free public service, ask you before testing it, and show it to you before anything is installed.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button {
                    buildMessage = SkillEvolutionService.shared.buildAddOn(id: item.id, with: appState.addOnAuthoring)
                    reload()
                } label: {
                    Label("Build It", systemImage: "hammer")
                }
                .tint(OGTheme.okLabel)
                Spacer()
                Button(role: .destructive) {
                    SkillEvolutionService.shared.dismiss(id: item.id)
                    reload()
                } label: {
                    Label("Dismiss", systemImage: "xmark.circle")
                }
            }
            .buttonStyle(.borderless)
        }
    }

    @ViewBuilder private func voiceSkillRow(_ item: EvolvedSkillStore.EvolvedSkill) -> some View {
                    Section {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("“\(item.draft.trigger)”").font(.body.weight(.medium))
                            Text(item.draft.instruction).font(.callout).foregroundStyle(.secondary)
                            Text(item.draft.name).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                        }
                        HStack {
                            Button {
                                SkillEvolutionService.shared.approve(id: item.id)
                                reload()
                            } label: {
                                Label("Approve", systemImage: "checkmark.circle.fill")
                            }
                            .tint(OGTheme.okLabel)
                            Spacer()
                            Button(role: .destructive) {
                                SkillEvolutionService.shared.dismiss(id: item.id)
                                reload()
                            } label: {
                                Label("Dismiss", systemImage: "xmark.circle")
                            }
                        }
                        .buttonStyle(.borderless)
                    }
    }

    private func reload() { pending = EvolvedSkillStore.shared.pending() }
}
