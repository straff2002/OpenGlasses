import SwiftUI
import UniformTypeIdentifiers

/// Browse, search, and install skills from ClawHub.ai — the public skill registry.
struct ClawHubBrowserView: View {
    @Environment(\.appAccent) private var accent
    @StateObject private var skillStore = InstalledSkillStore.shared
    @State private var skills: [ClawHubSkill] = []
    @State private var searchText = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedSkill: ClawHubSkill?
    @State private var installingSlug: String?
    @State private var selectedSort: SkillSort = .trending
    @State private var canLoadMore = true

    // Library export / import (Plan Q — gated behind agent mode).
    @State private var shareItem: ShareItem?
    @State private var importingLibrary = false
    @State private var pendingImportData: Data?
    @State private var pendingImportCount = 0
    @State private var libraryMessage: String?

    enum SkillSort: String, CaseIterable, Identifiable {
        case trending = "trending"
        case newest = "newest"
        case mostDownloaded = "most_downloaded"
        case starred = "starred"
        case recentlyUpdated = "updated"

        var id: String { rawValue }
        var label: String {
            switch self {
            case .trending: return "Trending"
            case .newest: return "Newest"
            case .mostDownloaded: return "Most Downloaded"
            case .starred: return "Starred"
            case .recentlyUpdated: return "Recently Updated"
            }
        }
        var icon: String {
            switch self {
            case .trending: return "flame"
            case .newest: return "sparkles"
            case .mostDownloaded: return "arrow.down.circle"
            case .starred: return "star"
            case .recentlyUpdated: return "clock.arrow.circlepath"
            }
        }
    }

    var body: some View {
        List {
            // MARK: Sort Tabs
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(SkillSort.allCases) { sort in
                            Button {
                                selectedSort = sort
                                Task { await loadSkills() }
                            } label: {
                                Label(sort.label, systemImage: sort.icon)
                                    .font(.subheadline.weight(selectedSort == sort ? .semibold : .regular))
                                    .foregroundStyle(selectedSort == sort ? Color(.label) : .secondary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(
                                        selectedSort == sort
                                            ? Color(.tertiarySystemFill)
                                            : Color.clear,
                                        in: Capsule()
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))

            // MARK: Installed Skills
            if !skillStore.installedSkills.isEmpty {
                Section {
                    ForEach(skillStore.installedSkills) { skill in
                        HStack(spacing: 12) {
                            Image(systemName: compatibilityIcon(skill.compatibility))
                                .font(.title3)
                                .foregroundStyle(compatibilityColor(skill.compatibility))
                                .frame(width: 32)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(skill.name)
                                    .font(.body.weight(.medium))
                                Text(skill.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }

                            Spacer()

                            Toggle("", isOn: Binding(
                                get: { skill.enabled },
                                set: { skillStore.setEnabled(skill.slug, enabled: $0) }
                            ))
                            .labelsHidden()
                            .tint(accent)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                skillStore.uninstall(slug: skill.slug)
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text("Installed Skills")
                } footer: {
                    Text("Enabled skills are injected into the system prompt so the AI knows how to use them.")
                }
            }

            // MARK: Browse / Search Results
            if isLoading {
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                            .padding(.vertical, 20)
                        Spacer()
                    }
                }
            } else if let error = errorMessage {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Retry") { Task { await loadSkills() } }
                            .font(.caption)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
            } else if skills.isEmpty {
                Section {
                    ContentUnavailableView(
                        searchText.isEmpty ? "No Skills Available" : "No Results",
                        systemImage: searchText.isEmpty ? "square.stack.3d.up" : "magnifyingglass",
                        description: Text(searchText.isEmpty
                            ? "Could not load skills from ClawHub. Check your connection and try again."
                            : "No skills found for \"\(searchText)\".")
                    )
                    Button("Retry") { Task { await loadSkills() } }
                        .frame(maxWidth: .infinity)
                }
            } else {
                Section {
                    ForEach(skills) { skill in
                        Button {
                            selectedSkill = skill
                        } label: {
                            skillRow(skill)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text(searchText.isEmpty ? selectedSort.label : "Search Results")
                } footer: {
                    if !skills.isEmpty {
                        Text("\(skills.count) skills from ClawHub.ai")
                    }
                }

                // Load More
                if canLoadMore && !skills.isEmpty && searchText.isEmpty {
                    Section {
                        Button {
                            Task { await loadMore() }
                        } label: {
                            if isLoading {
                                HStack {
                                    Spacer()
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Loading…")
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                }
                            } else {
                                HStack {
                                    Spacer()
                                    Label("Load More", systemImage: "arrow.down.circle")
                                    Spacer()
                                }
                            }
                        }
                        .disabled(isLoading)
                    }
                }
            }
        }
        .navigationTitle("Skill Store")
        .searchable(text: $searchText, prompt: "Search skills...")
        .onSubmit(of: .search) {
            Task { await searchSkills() }
        }
        .onChange(of: searchText) { _, newValue in
            if newValue.isEmpty {
                Task { await loadSkills() }
            }
        }
        .task { await loadSkills() }
        .toolbar {
            if Config.agentModeEnabled {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            exportLibrary()
                        } label: {
                            Label("Export Library", systemImage: "square.and.arrow.up")
                        }
                        .disabled(skillStore.installedSkills.isEmpty)

                        Button {
                            importingLibrary = true
                        } label: {
                            Label("Import Library", systemImage: "square.and.arrow.down")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .sheet(item: $selectedSkill) { skill in
            SkillDetailSheet(
                skill: skill,
                skillStore: skillStore,
                installingSlug: $installingSlug
            )
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: item.items)
        }
        .fileImporter(isPresented: $importingLibrary, allowedContentTypes: [.json]) { result in
            stageImport(result)
        }
        .alert("Import skills?", isPresented: Binding(
            get: { pendingImportData != nil },
            set: { if !$0 { pendingImportData = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingImportData = nil }
            Button("Import") { commitImport() }
        } message: {
            Text("\(pendingImportCount) skill\(pendingImportCount == 1 ? "" : "s") will be added **disabled**. Each injects its prompt into the AI's context, so review and enable them individually before use.")
        }
        .alert("Skill Library", isPresented: Binding(
            get: { libraryMessage != nil },
            set: { if !$0 { libraryMessage = nil } }
        )) {
            Button("OK") { libraryMessage = nil }
        } message: {
            Text(libraryMessage ?? "")
        }
    }

    // MARK: - Library export / import (Plan Q)

    private func exportLibrary() {
        do {
            let data = try skillStore.exportLibraryData()
            let url = try SkillsLibraryIO.writeTempFile(data, named: "clawhub-skills.json")
            shareItem = ShareItem(items: [url])
        } catch {
            libraryMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    private func stageImport(_ result: Swift.Result<URL, Error>) {
        switch result {
        case .failure(let error):
            libraryMessage = "Import failed: \(error.localizedDescription)"
        case .success(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let preview = try skillStore.previewImport(data)
                guard !preview.isEmpty else {
                    libraryMessage = "That file contains no skills."
                    return
                }
                pendingImportCount = preview.count
                pendingImportData = data   // triggers the confirm alert
            } catch {
                libraryMessage = "Couldn't read that file: \(error.localizedDescription)"
            }
        }
    }

    private func commitImport() {
        guard let data = pendingImportData else { return }
        pendingImportData = nil
        do {
            let count = try skillStore.importLibrary(data)
            libraryMessage = "Imported \(count) skill\(count == 1 ? "" : "s"), disabled. Enable the ones you want from “Installed Skills”."
        } catch {
            libraryMessage = "Import failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Skill Row

    private func skillRow(_ skill: ClawHubSkill) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if let emoji = skill.metadata?.emoji {
                        Text(emoji)
                    }
                    Text(skill.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(Color(.label))

                    if skillStore.isInstalled(skill.slug) {
                        Text("Installed")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(.tertiarySystemFill), in: Capsule())
                    }
                }

                Text(skill.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    if let compat = skill.compatibility {
                        HStack(spacing: 3) {
                            Image(systemName: compat.icon)
                                .font(.system(size: 9))
                            Text(compat.label)
                                .font(.system(size: 10))
                        }
                        .foregroundStyle(compatibilityColor(compat))
                    }

                    if let downloads = skill.downloads, downloads > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: 9))
                            Text("\(downloads)")
                                .font(.system(size: 10))
                        }
                        .foregroundStyle(.secondary)
                    }

                    if let owner = skill.owner {
                        Text(owner)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Loading

    private func loadSkills() async {
        isLoading = true
        errorMessage = nil
        canLoadMore = true
        do {
            skills = try await ClawHubService.shared.browse(sort: selectedSort.rawValue)
            isLoading = false
            canLoadMore = skills.count >= 30
            await checkCompatibilityInBackground()
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    private func loadMore() async {
        guard !isLoading else { return }
        isLoading = true
        do {
            let more = try await ClawHubService.shared.browse(
                sort: selectedSort.rawValue,
                limit: 30,
                offset: skills.count
            )
            if more.isEmpty {
                canLoadMore = false
            } else {
                let existingSlugs = Set(skills.map(\.slug))
                let newSkills = more.filter { !existingSlugs.contains($0.slug) }
                skills.append(contentsOf: newSkills)
                canLoadMore = more.count >= 30
            }
            isLoading = false
            await checkCompatibilityInBackground()
        } catch {
            isLoading = false
        }
    }

    private func searchSkills() async {
        guard !searchText.isEmpty else { return }
        isLoading = true
        errorMessage = nil
        do {
            skills = try await ClawHubService.shared.search(query: searchText)
            isLoading = false
            await checkCompatibilityInBackground()
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    /// Check compatibility lazily — updates each skill as its metadata loads.
    private func checkCompatibilityInBackground() async {
        let checker = SkillCompatibilityChecker(
            nativeToolNames: Set(InstalledSkillStore.shared.installedSkills.map(\.slug))
        )
        // Process in parallel batches of 5 to avoid hammering the API
        for batchStart in stride(from: 0, to: skills.count, by: 5) {
            let batchEnd = min(batchStart + 5, skills.count)
            await withTaskGroup(of: (Int, ClawHubSkillMetadata?, SkillCompatibility).self) { group in
                for i in batchStart..<batchEnd {
                    let skill = skills[i]
                    group.addTask {
                        do {
                            let content = try await ClawHubService.shared.readFile(slug: skill.slug)
                            let meta = ClawHubService.shared.parseMetadata(from: content)
                            let compat = checker.check(skill: skill, content: content)
                            return (i, meta, compat)
                        } catch {
                            return (i, nil, .openclawRequired)
                        }
                    }
                }
                for await (index, meta, compat) in group {
                    if index < skills.count {
                        skills[index].metadata = meta
                        skills[index].compatibility = compat
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func compatibilityIcon(_ compat: SkillCompatibility) -> String {
        compat.icon
    }

    private func compatibilityColor(_ compat: SkillCompatibility) -> Color {
        switch compat {
        case .compatible: return .green
        case .partiallyCompatible: return .orange
        case .openclawRequired: return AppAccent.aiCoral
        }
    }
}

// MARK: - Skill Detail Sheet

struct SkillDetailSheet: View {
    let skill: ClawHubSkill
    @ObservedObject var skillStore: InstalledSkillStore
    @Binding var installingSlug: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAccent) private var accent
    @State private var content: String?
    @State private var isLoadingContent = false
    @State private var installError: String?

    private var isInstalled: Bool { skillStore.isInstalled(skill.slug) }
    private var isInstalling: Bool { installingSlug == skill.slug }

    var body: some View {
        NavigationStack {
            List {
                // MARK: Overview
                Section {
                    if let emoji = skill.metadata?.emoji {
                        LabeledContent("Icon", value: emoji)
                    }
                    if let owner = skill.owner {
                        LabeledContent("Author", value: owner)
                    }
                    if let version = skill.version {
                        LabeledContent("Version", value: version)
                    }
                    if let downloads = skill.downloads {
                        LabeledContent("Downloads", value: "\(downloads)")
                    }
                } header: {
                    Text(skill.name)
                        .font(.title3.weight(.semibold))
                }

                // MARK: Description
                Section {
                    Text(skill.description)
                        .font(.body)
                        .foregroundStyle(Color(.label))
                }

                // MARK: Compatibility
                if let compat = skill.compatibility {
                    Section {
                        HStack(spacing: 8) {
                            Image(systemName: compat.icon)
                                .foregroundStyle(compatColor(compat))
                            Text(compat.label)
                                .font(.body)
                                .foregroundStyle(Color(.label))
                        }

                        if compat == .openclawRequired {
                            Text("This skill requires an OpenClaw gateway to run. It uses shell commands or binaries not available on iOS.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if compat == .partiallyCompatible {
                            Text("Some features of this skill can run on-device with native tools. Full functionality requires OpenClaw.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("This skill runs fully on-device using native tools and configured API keys.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("Compatibility")
                    }
                }

                // MARK: Skill Content Preview
                Section {
                    if isLoadingContent {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .padding(.vertical, 8)
                    } else if let content {
                        Text(stripFrontmatter(content).prefix(600) + (content.count > 600 ? "..." : ""))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                } header: {
                    Text("Skill Prompt")
                }

                // MARK: Requirements
                if let meta = skill.metadata {
                    Section {
                        if let env = meta.requiredEnv, !env.isEmpty {
                            LabeledContent("API Keys", value: env.joined(separator: ", "))
                        }
                        if let bins = meta.requiredBins, !bins.isEmpty {
                            LabeledContent("Binaries", value: bins.joined(separator: ", "))
                        }
                        if let os = meta.os, !os.isEmpty {
                            LabeledContent("OS", value: os.joined(separator: ", "))
                        }
                    } header: {
                        Text("Requirements")
                    }
                }

                // MARK: Install / Uninstall
                Section {
                    if let error = installError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    if isInstalled {
                        Button(role: .destructive) {
                            skillStore.uninstall(slug: skill.slug)
                            dismiss()
                        } label: {
                            Label("Remove Skill", systemImage: "trash")
                        }
                    } else {
                        Button {
                            Task { await installSkill() }
                        } label: {
                            HStack {
                                if isInstalling {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                } else {
                                    Image(systemName: "arrow.down.circle.fill")
                                }
                                Text(isInstalling ? "Installing..." : "Install Skill")
                            }
                        }
                        .disabled(isInstalling)
                        .tint(accent)
                    }
                }
            }
            .navigationTitle("Skill Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await loadContent() }
        }
        .presentationDetents([.large])
    }

    private func loadContent() async {
        isLoadingContent = true
        do {
            content = try await ClawHubService.shared.downloadSkillContent(slug: skill.slug)
        } catch {
            content = "Failed to load: \(error.localizedDescription)"
        }
        isLoadingContent = false
    }

    private func installSkill() async {
        installingSlug = skill.slug
        installError = nil
        do {
            let skillContent: String
            if let existing = content {
                skillContent = existing
            } else {
                skillContent = try await ClawHubService.shared.downloadSkillContent(slug: skill.slug)
            }
            let compat = skill.compatibility ?? .openclawRequired
            skillStore.install(skill: skill, content: skillContent, compatibility: compat)
            dismiss()
        } catch {
            installError = error.localizedDescription
        }
        installingSlug = nil
    }

    private func compatColor(_ compat: SkillCompatibility) -> Color {
        switch compat {
        case .compatible: return .green
        case .partiallyCompatible: return .orange
        case .openclawRequired: return AppAccent.aiCoral
        }
    }

    private func stripFrontmatter(_ content: String) -> String {
        let lines = content.components(separatedBy: "\n")
        guard let first = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return content
        }
        let after = lines.index(after: first)
        guard let second = lines[after...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return content
        }
        return lines[(second + 1)...].joined(separator: "\n")
    }
}
