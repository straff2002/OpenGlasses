import SwiftUI

/// How a surface opens a citation, injected rather than reached for, so a chat bubble does not
/// have to know what a vault is (Plan EK P3).
///
/// The default opens nothing and offers nothing, which is exactly right outside a Field Assist
/// session: a citation is only a door when there is a vault behind it.
struct CitationOpener {
    var canOpen: (Citation) -> Bool = { _ in false }
    var open: (Citation) -> Void = { _ in }

    static let none = CitationOpener()
}

private struct CitationOpenerKey: EnvironmentKey {
    static let defaultValue = CitationOpener.none
}

extension EnvironmentValues {
    var citationOpener: CitationOpener {
        get { self[CitationOpenerKey.self] }
        set { self[CitationOpenerKey.self] = newValue }
    }
}

/// The chips under an answer: one per `Source:` line, each opening the page it names.
///
/// The words are the citation's own, because the technician is checking the chip against the
/// sentence above it. Only citations this vault can actually open are drawn — a chip that leads
/// nowhere is worse than no chip.
struct CitationChipsView: View {
    let citations: [Citation]
    @Environment(\.citationOpener) private var opener

    private var openable: [Citation] { citations.filter(opener.canOpen) }

    var body: some View {
        if !openable.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(openable) { citation in
                        Button { opener.open(citation) } label: {
                            CitationChip(citation: citation)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(verbatim: Self.spokenLabel(citation)))
                        .accessibilityHint("Opens the page this answer cites")
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 1)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    /// Pure, so the wording is covered by the suite. VoiceOver hears what the chip does, not only
    /// what it says.
    static func spokenLabel(_ citation: Citation) -> String {
        citation.kind == .coreFile
            ? "Open \(citation.title)"
            : "Open \(citation.label)"
    }
}

/// One citation, drawn like the design kit's capability chip with the icon of what it opens: a
/// page of a manual, or a file of the vault's own core.
private struct CitationChip: View {
    let citation: Citation
    @Environment(\.appAccent) private var accent

    private var icon: String {
        if citation.kind == .coreFile { return "doc.text" }
        return citation.figure != nil || citation.isDiagram ? "square.grid.3x3.topleft.filled" : "book.pages"
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption2.weight(.semibold))
            Text(verbatim: citation.chipLabel)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(OGTheme.tintedAccentLabel(accent))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(accent.opacity(OGTheme.Opacity.accentFill),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
