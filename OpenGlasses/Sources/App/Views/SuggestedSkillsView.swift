import SwiftUI

/// The review inbox for self-proposed skills (Plan AW). The evolution loop *proposes* a skill from
/// recurring tool failures; the user **approves** (→ becomes a voice skill, injected like any other) or
/// **dismisses** (recorded so it's never re-proposed). Nothing self-authored enters the prompt without
/// an explicit approval here — this view is the human-in-the-loop boundary.
@MainActor
struct SuggestedSkillsView: View {
    @State private var pending: [EvolvedSkillStore.EvolvedSkill] = EvolvedSkillStore.shared.pending()

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
            }
        }
        .navigationTitle("Suggested Skills")
        .navigationBarTitleDisplayMode(.inline)
        .ogFormStyle()
        .onAppear(perform: reload)
    }

    private func reload() { pending = EvolvedSkillStore.shared.pending() }
}
