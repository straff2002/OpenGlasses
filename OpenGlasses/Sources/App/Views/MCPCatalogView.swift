import SwiftUI

/// Browsable curated catalogue of vetted MCP servers (Plan V). Tapping an entry opens a small
/// install screen that fills the server's URL template and produces an ordinary `MCPServerConfig`
/// on the safe `.redact` egress policy — the same config a manual add produces, so it flows through
/// the exact discovery → Plan R screen → router path. Convenience over the existing primitive.
struct MCPCatalogView: View {
    /// Called with the built config when the user installs an entry.
    let onInstall: (MCPServerConfig) -> Void

    private let catalog = MCPCatalog.bundled()

    /// Read the way the other Agent-Mode-gated screens read it.
    private var agentModeOn: Bool { Config.agentModeEnabled }

    var body: some View {
        Group {
            if let catalog, !catalog.entries.isEmpty {
                List {
                    Section {
                        ForEach(catalog.entries) { entry in
                            // A gated entry stays visible but unreachable: the wearer should be
                            // able to see what is on offer and why it isn't available, which a
                            // hidden row cannot say.
                            let gated = entry.requiresAgentMode && !agentModeOn
                            NavigationLink {
                                MCPCatalogInstallView(entry: entry, onInstall: onInstall)
                            } label: {
                                entryRow(entry, gated: gated)
                            }
                            .disabled(gated)
                        }
                    } footer: {
                        Text("Every install lands on the \"Redact\" data policy and is screened by the egress + tool-poisoning checks before the AI can use its tools. Open Safety & Trust to review or change a server's policy.")
                    }
                }
            } else {
                ContentUnavailableView(
                    "Catalogue unavailable",
                    systemImage: "square.grid.2x2",
                    description: Text("Add a server manually with ＋ on the previous screen.")
                )
            }
        }
        .navigationTitle("Catalogue")
        .navigationBarTitleDisplayMode(.inline)
        .ogFormStyle()
    }

    @ViewBuilder
    private func entryRow(_ entry: MCPCatalogEntry, gated: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.icon)
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(gated ? Color.secondary : Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.label)
                    .foregroundStyle(gated ? Color.secondary : Color(.label))
                Text(gated ? "Requires Agent Mode"
                           : "\(entry.transport.label) · \(entry.auth.kind.label)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(gated
            ? "\(entry.label), requires Agent Mode"
            : "\(entry.label), \(entry.transport.label), \(entry.auth.kind.label)")
    }
}

/// Install screen for a single catalogue entry: collects the entry's `fields` and (for bearer) a
/// token, then builds the safe-default `MCPServerConfig` and hands it back to the caller.
struct MCPCatalogInstallView: View {
    @Environment(\.dismiss) private var dismiss

    let entry: MCPCatalogEntry
    let onInstall: (MCPServerConfig) -> Void

    @State private var values: [String: String] = [:]
    @State private var token: String = ""

    /// Whether this entry wants Agent Mode the wearer hasn't turned on.
    private var blockedByAgentMode: Bool {
        entry.requiresAgentMode && !Config.agentModeEnabled
    }

    /// True once every URL placeholder has a non-blank value — and the entry is allowed to
    /// install at all.
    private var canInstall: Bool {
        !blockedByAgentMode && entry.resolvedURL(from: values) != nil
    }

    var body: some View {
        Form {
            if !entry.scopes.isEmpty {
                Section("What it can do") {
                    ForEach(entry.scopes, id: \.self) { scope in
                        Label(scope, systemImage: "checkmark.circle")
                            .font(.subheadline)
                    }
                }
            }

            if !entry.fields.isEmpty {
                Section {
                    ForEach(entry.fields) { field in
                        TextField(
                            field.placeholder.isEmpty ? field.label : field.placeholder,
                            text: Binding(
                                get: { values[field.key] ?? "" },
                                set: { values[field.key] = $0 }
                            )
                        )
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    }
                } header: {
                    Text("Connection")
                } footer: {
                    Text(resolvedURLPreview)
                        .font(.caption)
                }
            }

            if entry.auth.kind != .none {
                Section {
                    SecretInputField(placeholder: entry.auth.kind == .header ? "API key" : "Token", text: $token)
                } header: {
                    switch entry.auth.kind {
                    case .oauth:  Text("Access token (paste)")
                    case .header: Text("\(entry.auth.header) value")
                    default:      Text("Bearer token")
                    }
                } footer: {
                    if !entry.auth.hint.isEmpty {
                        Text(entry.auth.hint)
                    } else if entry.auth.kind == .header {
                        Text("Sent as the \(entry.auth.header) header.")
                    } else {
                        Text("Pasted as an Authorization: Bearer header.")
                    }
                }
            }

            if !entry.notes.isEmpty || !entry.transport.isLive {
                Section {
                    if !entry.transport.isLive {
                        Label("\(entry.transport.label) connections aren't wired for live calls yet — this server saves but won't connect until SSE support ships.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !entry.notes.isEmpty {
                        Text(entry.notes)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Button {
                    guard let config = entry.makeServerConfig(values: values, token: token) else { return }
                    onInstall(config)
                    dismiss()
                } label: {
                    Label("Install \(entry.label)", systemImage: "square.and.arrow.down")
                }
                .disabled(!canInstall)
            } footer: {
                if blockedByAgentMode {
                    Text("Requires Agent Mode. Enable Agent Mode first, then install this server.")
                } else {
                    Text("Installs on the safe \"Redact\" data policy. You can change it later under Safety & Trust.")
                }
            }
        }
        .navigationTitle(entry.label)
        .navigationBarTitleDisplayMode(.inline)
        .ogFormStyle()
    }

    private var resolvedURLPreview: String {
        if let url = entry.resolvedURL(from: values) {
            return url
        }
        return entry.urlTemplate
    }
}
