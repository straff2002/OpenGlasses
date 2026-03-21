import SwiftUI

/// Shows the full assembled system prompt and all injected context.
/// Transparency tool — lets users see exactly what data goes to the LLM.
struct PromptInspectorView: View {
    @ObservedObject var appState: AppState

    @State private var tokenEstimate: Int = 0
    @State private var sections: [PromptSection] = []

    struct PromptSection: Identifiable {
        let id = UUID()
        let name: String
        let icon: String
        let content: String
        let isPresent: Bool
    }

    var body: some View {
        List {
            // MARK: Overview
            Section {
                LabeledContent("Active Model", value: Config.activeModel?.name ?? "None")
                LabeledContent("Provider", value: Config.activeModel?.llmProvider.displayName ?? "—")
                LabeledContent("Estimated Tokens", value: "~\(tokenEstimate)")
            } header: {
                Text("Summary")
            } footer: {
                Text("Token estimate is approximate (~4 characters per token).")
            }

            // MARK: Sections breakdown
            Section {
                ForEach(sections) { section in
                    DisclosureGroup {
                        Text(section.content)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    } label: {
                        HStack {
                            Image(systemName: section.isPresent ? section.icon : "circle.dashed")
                                .foregroundStyle(section.isPresent ? Color.green : Color.secondary)
                                .font(.body)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(section.name)
                                    .lineLimit(1)
                                if section.isPresent {
                                    Text("\(section.content.count) characters")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("Not active")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
            } header: {
                Text("What's Sent to the AI")
            } footer: {
                Text("Expand each section to see exactly what data is included. Green items are active in the current request.")
            }
        }
        .navigationTitle("Prompt Inspector")
        .onAppear { buildSections() }
        .refreshable { buildSections() }
    }

    private func buildSections() {
        let basePrompt = Config.systemPrompt
        let toolNames = appState.nativeToolRouter.registry.toolNames
        let hasOpenClaw = Config.isOpenClawConfigured
        let locationContext = appState.locationService.locationContext
        let memoryContext = Config.userMemoryEnabled ? appState.userMemory.systemPromptContext() : nil

        var secs: [PromptSection] = []

        secs.append(PromptSection(
            name: "System Prompt",
            icon: "text.bubble.fill",
            content: basePrompt,
            isPresent: true
        ))

        let visionAutoInjected = !basePrompt.lowercased().contains("vision") && !basePrompt.lowercased().contains("camera")
        secs.append(PromptSection(
            name: "Vision & Camera",
            icon: "eye.fill",
            content: visionAutoInjected
                ? "Auto-injected: tells the AI it can see images from the glasses camera, handle OCR, translation, and object identification."
                : "Already covered in your system prompt.",
            isPresent: visionAutoInjected
        ))

        secs.append(PromptSection(
            name: "Native Tools (\(toolNames.count))",
            icon: "wrench.and.screwdriver.fill",
            content: toolNames.isEmpty
                ? "No tools registered."
                : toolNames.joined(separator: ", "),
            isPresent: !toolNames.isEmpty
        ))

        secs.append(PromptSection(
            name: "OpenClaw Gateway",
            icon: "network",
            content: hasOpenClaw
                ? "Adds the 'execute' tool for external integrations — messaging, web search, smart home, and more via your Mac."
                : "Not configured. Enable in Settings → Services & Integrations.",
            isPresent: hasOpenClaw
        ))

        secs.append(PromptSection(
            name: "Tool Usage Rules",
            icon: "list.bullet.rectangle.fill",
            content: "Contact name resolution, multi-step tool chains, calendar proactive alerts, acknowledgment-before-action rules.",
            isPresent: !toolNames.isEmpty || hasOpenClaw
        ))

        let memoryEnabled = Config.userMemoryEnabled
        let hasMemories = memoryContext != nil && !(memoryContext?.isEmpty ?? true)
        secs.append(PromptSection(
            name: "User Memory",
            icon: "brain.head.profile.fill",
            content: hasMemories
                ? memoryContext!
                : memoryEnabled
                    ? "Enabled — no memories stored yet. Tell the AI facts about yourself and it will remember them."
                    : "Disabled. Turn on in Settings → Intelligence.",
            isPresent: memoryEnabled
        ))

        secs.append(PromptSection(
            name: "Location",
            icon: "location.fill",
            content: locationContext ?? "Location unavailable. Grant location permission in iOS Settings.",
            isPresent: locationContext != nil
        ))

        sections = secs
        tokenEstimate = secs.filter(\.isPresent).reduce(0) { $0 + $1.content.count } / 4
    }
}
