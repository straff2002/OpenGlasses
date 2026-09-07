import SwiftUI

/// Generic viewer/editor for any registered vault's markdown files.
///
/// When the vault is unlocked, files are editable (edits write to the Documents overlay; the
/// read-only baseline is never mutated). When the vault is **locked**, the same screen becomes a
/// read-only **preview** so a prospective buyer can browse the reference content before unlocking.
@MainActor
struct VaultFilesEditorView: View {
    let vaultId: String
    let title: String

    private var store: VaultStore? { VaultRegistry.shared.store(forId: vaultId) }
    private var unlocked: Bool { VaultRegistry.shared.isUnlocked(vaultId) }

    var body: some View {
        Group {
            if let store {
                List {
                    if !unlocked {
                        Section {
                            OGNotice(text: "Preview only — unlock to edit", systemImage: "lock")
                                .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                                .listRowBackground(Color.clear)
                        }
                    }
                    Section {
                        ForEach(store.manifest.files, id: \.self) { filename in
                            NavigationLink {
                                VaultSingleFileEditor(store: store, filename: filename, readOnly: !unlocked)
                            } label: {
                                Label(displayName(filename), systemImage: "doc.text")
                            }
                        }
                    }
                }
            } else {
                ContentUnavailableView("Unavailable", systemImage: "lock")
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .ogFormStyle()
    }

    private func displayName(_ filename: String) -> String {
        filename.replacingOccurrences(of: ".md", with: "").replacingOccurrences(of: "_", with: " ").capitalized
    }
}

/// One core file: read first — headings, lists and tables rendered the way they read in the book —
/// and edited on demand when the vault is unlocked.
///
/// `section` is the `##` heading a citation named (Plan EK P3). The view scrolls to it and marks it,
/// so a technician checking an answer lands on the paragraph rather than at the top of a fault-code
/// table, and an author can correct it on the spot.
@MainActor
struct VaultSingleFileEditor: View {
    let store: VaultStore
    let filename: String
    var readOnly: Bool = false
    var section: String? = nil
    @State private var text = ""
    @State private var editing = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAccent) private var accent

    private var displayName: String {
        filename.replacingOccurrences(of: ".md", with: "").replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// The file split at its `##` headings, so one of them can be marked and scrolled to.
    private var sections: [VaultFileSection] { VaultFileSection.split(text) }

    var body: some View {
        Group {
            if editing && !readOnly {
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .padding(8)
            } else if text.isEmpty {
                ContentUnavailableView("Empty file", systemImage: "doc")
            } else {
                rendered
            }
        }
        .navigationTitle(displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !readOnly {
                ToolbarItem(placement: .confirmationAction) {
                    if editing {
                        Button("Save") { _ = try? store.write(filename, contents: text); editing = false }
                    } else {
                        Button("Edit") { editing = true }
                    }
                }
            }
        }
        .onAppear { text = store.read(filename) ?? "" }
    }

    private var rendered: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(sections) { part in
                        MessageContentView(text: part.text)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                highlights(part) ? accent.opacity(OGTheme.Opacity.accentNoticeFill) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                            )
                            .id(part.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onAppear {
                guard let target = sections.first(where: highlights)?.id else { return }
                DispatchQueue.main.async { proxy.scrollTo(target, anchor: .top) }
            }
        }
    }

    private func highlights(_ part: VaultFileSection) -> Bool {
        guard let section, !section.isEmpty, let heading = part.heading else { return false }
        return heading.lowercased() == section.lowercased()
    }
}

/// A core file cut at its `##` headings. Pure, so "which part does this citation name" is provable
/// without a screen.
struct VaultFileSection: Identifiable, Equatable {
    let index: Int
    /// The heading this part sits under, or nil for the preamble above the first one.
    let heading: String?
    let text: String

    var id: Int { index }

    static func split(_ markdown: String) -> [VaultFileSection] {
        var parts: [VaultFileSection] = []
        var heading: String?
        var lines: [String] = []

        func flush() {
            let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            defer { lines.removeAll() }
            guard !body.isEmpty else { return }
            parts.append(VaultFileSection(index: parts.count, heading: heading, text: body))
        }

        for line in markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") && !trimmed.hasPrefix("### ") {
                flush()
                heading = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            }
            lines.append(line)
        }
        flush()
        return parts
    }
}

/// The core file behind a citation, presented as a sheet from wherever the answer was read.
@MainActor
struct VaultFileCitationSheet: View {
    let vaultId: String
    let filename: String
    var section: String? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let store = VaultRegistry.shared.store(forId: vaultId) {
                    VaultSingleFileEditor(store: store, filename: filename,
                                          readOnly: !VaultRegistry.shared.isUnlocked(vaultId),
                                          section: section)
                } else {
                    ContentUnavailableView("Unavailable", systemImage: "lock")
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
