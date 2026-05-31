import SwiftUI
import UniformTypeIdentifiers

/// Lists voice-taught skills (trigger → instruction) and lets the user move the library between
/// devices via export/import. Voice skills are local-only, so — unlike the ClawHub library — there's
/// no gateway gate. Authoring still happens by voice through the `voice_skills` tool.
@MainActor
struct VoiceSkillsManagerView: View {
    @State private var skills: [VoiceSkill] = VoiceSkillStore.shared.all()
    @State private var shareItem: ShareItem?
    @State private var importing = false
    @State private var message: String?

    var body: some View {
        Form {
            if skills.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No Voice Skills",
                        systemImage: "waveform",
                        description: Text("Teach skills by voice, e.g. “learn that when I say ‘expense this’, create a note tagged EXPENSE.” Then export them here to move to another device.")
                    )
                }
            } else {
                Section {
                    ForEach(skills) { skill in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("“\(skill.trigger)”").font(.body.weight(.medium))
                            Text(skill.instruction).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .onDelete(perform: delete)
                } header: {
                    Text("\(skills.count) Skill\(skills.count == 1 ? "" : "s")")
                } footer: {
                    Text("Swipe to delete. Export writes a JSON library you can AirDrop or save to Files; import merges by trigger phrase.")
                }
            }
        }
        .navigationTitle("Voice Skills")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        exportLibrary()
                    } label: {
                        Label("Export Library", systemImage: "square.and.arrow.up")
                    }
                    .disabled(skills.isEmpty)

                    Button {
                        importing = true
                    } label: {
                        Label("Import Library", systemImage: "square.and.arrow.down")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: item.items)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            handleImport(result)
        }
        .alert("Voice Skills", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button("OK") { message = nil }
        } message: {
            Text(message ?? "")
        }
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            _ = VoiceSkillStore.shared.delete(trigger: skills[index].trigger)
        }
        skills = VoiceSkillStore.shared.all()
    }

    private func exportLibrary() {
        do {
            let data = try VoiceSkillStore.shared.exportLibraryData()
            let url = try SkillsLibraryIO.writeTempFile(data, named: "voice-skills.json")
            shareItem = ShareItem(items: [url])
        } catch {
            message = "Export failed: \(error.localizedDescription)"
        }
    }

    private func handleImport(_ result: Swift.Result<URL, Error>) {
        switch result {
        case .failure(let error):
            message = "Import failed: \(error.localizedDescription)"
        case .success(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let count = try VoiceSkillStore.shared.importLibrary(data)
                skills = VoiceSkillStore.shared.all()
                message = count == 0 ? "That file contains no skills." : "Imported \(count) skill\(count == 1 ? "" : "s")."
            } catch {
                message = "Couldn't read that file: \(error.localizedDescription)"
            }
        }
    }
}

#Preview {
    NavigationStack {
        VoiceSkillsManagerView()
    }
}
