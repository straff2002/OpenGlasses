import SwiftUI

/// Shows the full assembled system prompt and all injected context.
/// Transparency tool — lets users see exactly what data goes to the LLM.
struct PromptInspectorView: View {
    @ObservedObject var appState: AppState
    @Environment(\.appAccent) private var accent

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
                LabeledContent("Active Model", value: Config.activeModel?.name ?? String(localized: "None"))
                LabeledContent("Provider", value: Config.activeModel?.llmProvider.displayName ?? "—")
                LabeledContent("Estimated Tokens", value: "~\(tokenEstimate)")
            } header: {
                Text("Summary")
            } footer: {
                Text("Token estimate is approximate (~4 characters per token).")
            }

            // MARK: Last Reasoning
            if let reasoning = appState.llmService.lastReasoning {
                Section {
                    Text(reasoning)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } header: {
                    Label("Last Reasoning", systemImage: "brain")
                } footer: {
                    Text("The AI's private chain-of-thought from its most recent response. This is never spoken aloud.")
                }
            }

            // MARK: Earlier in this conversation (Plan KK P3)
            // The conversation timeline as the last cloud request carried it. On-device only, as
            // the memory section is: this is the one place its text is shown.
            Section {
                let decision = appState.llmService.lastTimelineDecision
                Text(Self.timelineStatus(decision))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let block = decision?.text {
                    DisclosureGroup {
                        Text(block)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    } label: {
                        Label {
                            Text("Notes sent (\(decision?.renderedCount ?? 0))")
                        } icon: {
                            Image(systemName: "text.badge.checkmark")
                                .foregroundStyle(OGTheme.tintedAccentLabel(accent))
                        }
                    }
                }
            } header: {
                Label("Earlier in This Conversation", systemImage: "clock.arrow.circlepath")
            } footer: {
                Text("Notes about older messages that no longer fit in a request. Written by the same AI as the conversation, kept with the conversation on this phone.")
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
                                .foregroundStyle(section.isPresent ? OGTheme.tintedAccentLabel(accent) : Color.secondary)
                                .font(.body)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(section.name)
                                    .foregroundStyle(section.isPresent ? OGTheme.tintedAccentLabel(accent) : Color.secondary)
                                    .lineLimit(1)
                                if section.isPresent {
                                    Text("\(section.content.count) characters")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("Not active")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
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
        .ogFormStyle()
        .onAppear { buildSections() }
        .refreshable { buildSections() }
    }

    /// What the last cloud request did with the conversation's notes, in the wearer's words.
    static func timelineStatus(_ decision: TimelineRequestBlock.Decision?) -> String {
        guard let decision else {
            return String(localized: "No request has been sent in this session yet.")
        }
        guard let skip = decision.skip else {
            return decision.replacesNote
                ? String(localized: "Sent with the last request in place of the line saying older messages were left out. They cover everything that was left out.")
                : String(localized: "Sent with the last request after the line saying older messages were left out. Some of those messages are not in these notes yet.")
        }
        switch skip {
        case .settingOff:
            return String(localized: "Off. Turn on Remember Earlier in Long Conversations in Settings › Everyday › Memory.")
        case .hipaaMode:
            return String(localized: "Off in Medical Compliance mode.")
        case .onDeviceModel:
            return String(localized: "Not used with on-device models.")
        case .routeCarriesNoBlock:
            return String(localized: "Not used with this model: it is sent only a short recent history.")
        case .noThread:
            return String(localized: "No saved conversation is open.")
        case .noEntries:
            return String(localized: "No notes yet. They are written once older messages no longer fit in a request.")
        case .nothingOmitted:
            return String(localized: "The last request carried the whole conversation, so no notes were needed.")
        case .nothingCovered:
            return String(localized: "Older messages were left out of the last request and no notes cover them yet. The line saying so was sent.")
        case .noRoom:
            return String(localized: "The current question left no room for the notes. The line saying older messages were left out was sent instead.")
        }
    }

    private func buildSections() {
        // The same device a turn would be composed for right now (Plan FY F3).
        let basePrompt = Config.systemPrompt(device: LLMService.deviceInUse())
        let toolNames = appState.nativeToolRouter.registry.toolNames
        // BK P0: the prompt preview must match the real gated prompt — the OpenClaw block is only
        // present when the gateway is an active agentic capability.
        let hasOpenClaw = Config.isOpenClawAgentActive
        let locationContext = appState.locationService.locationContext
        // Plan FC P3: the inspector previews a prompt rather than sending one, so it renders
        // through the same entry point but does not record a turn snapshot — a preview that
        // claimed to be a turn would put a memory block on the ledger no backend ever received.
        let memoryContext = appState.userMemory.renderedContext(enabled: Config.userMemoryEnabled).text

        var secs: [PromptSection] = []

        secs.append(PromptSection(
            name: "System Prompt",
            icon: "text.bubble.fill",
            content: basePrompt,
            isPresent: true
        ))

        // Vision is always part of the prompt — the only question is whether this section's copy
        // was auto-injected or is already written into the wearer's own system prompt. Both are
        // "on", so both render as present: an inactive-looking row here was read as "vision is
        // off" by someone whose prompt simply already covered it.
        let visionAutoInjected = !basePrompt.lowercased().contains("vision") && !basePrompt.lowercased().contains("camera")
        secs.append(PromptSection(
            name: "Vision & Camera",
            icon: "eye.fill",
            content: visionAutoInjected
                ? "Auto-injected: tells the AI it can see images from the camera, handle OCR, translation, and object identification."
                : "Included in your system prompt. A camera frame is attached when a question needs one and a camera is available.",
            isPresent: true
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
                : "Not configured. Set up OpenClaw in Settings → Connections → Gateways.",
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
                    : "Disabled. Turn on User Memory in Settings → Everyday.",
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
