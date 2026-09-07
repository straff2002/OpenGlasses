import SwiftUI

/// Renders a chat message or a vault document as ordered blocks: inline-markdown prose, headings,
/// bullet and numbered lists, pipe tables, and fenced code.
///
/// Prose uses `AttributedString(markdown:)` (bold/italic/links/inline-code); code blocks render in a
/// monospaced, horizontally-scrollable card with a copy button; a table is a `Grid` with row
/// separators, because the vault's fault-code tables lose the column that says what the code means
/// the moment they are read as a paragraph (Plan EK P3).
struct MessageContentView: View {
    let text: String

    private var blocks: [MarkdownBlock] { MarkdownBlockParser.parse(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .prose(let s):
                    Text(Self.proseAttributed(s))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .code(let language, let body):
                    CodeBlockView(language: language, code: body)
                case .heading(let level, let heading):
                    Text(Self.proseAttributed(heading))
                        .font(Self.headingFont(level))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, level == 1 ? 4 : 2)
                        .accessibilityAddTraits(.isHeader)
                case .bulletList(let items):
                    listBlock(items.map { (marker: "\u{2022}", text: $0) })
                case .numberedList(let items):
                    listBlock(items.map { (marker: "\($0.number).", text: $0.text) })
                case .table(let table):
                    MarkdownTableView(table: table)
                }
            }
        }
    }

    /// One list, drawn as marker-and-text rows so a wrapped item stays indented under its own text
    /// rather than under its bullet.
    private func listBlock(_ items: [(marker: String, text: String)]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: item.marker)
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(Self.proseAttributed(item.text))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The three heading sizes. A fourth level would be indistinguishable from body text, which is
    /// why the parser clamps at three.
    static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title3.weight(.semibold)
        case 2: return .headline
        default: return .subheadline.weight(.semibold)
        }
    }

    /// Parse inline markdown, preserving soft line breaks; fall back to plain text on failure.
    static func proseAttributed(_ s: String) -> AttributedString {
        (try? AttributedString(
            markdown: s,
            options: .init(
                allowsExtendedAttributes: false,
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        )) ?? AttributedString(s)
    }
}

/// A fenced code block: optional language label + copy button over monospaced, scrollable body.
private struct CodeBlockView: View {
    let language: String?
    let code: String

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if let language, !language.isEmpty {
                    Text(language)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: copy) {
                    Label(copied ? "Copied" : "Copy",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(copied ? "Copied code" : "Copy code")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(OGTheme.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(OGTheme.hairline)
        )
    }

    private func copy() {
        UIPasteboard.general.string = code
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }
}

// MARK: - Tables

/// A pipe table as a `Grid`: a header row in the design kit's caption weight, a hairline under it,
/// and a hairline between body rows. Scrolls horizontally on its own so a wide fault-code table
/// never widens the message around it.
private struct MarkdownTableView: View {
    let table: MarkdownTable

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    ForEach(Array(table.headers.enumerated()), id: \.offset) { column, header in
                        cell(header, column: column)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(Array(table.rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { column, value in
                            cell(value, column: column).font(.footnote)
                        }
                    }
                    if index < table.rows.count - 1 {
                        Divider().gridCellUnsizedAxes(.horizontal)
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func cell(_ value: String, column: Int) -> some View {
        Text(MessageContentView.proseAttributed(value))
            .multilineTextAlignment(alignment(column))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: frameAlignment(column))
    }

    private func alignment(_ column: Int) -> TextAlignment {
        switch table.alignment(column) {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    private func frameAlignment(_ column: Int) -> Alignment {
        switch table.alignment(column) {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}
