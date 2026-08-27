import SwiftUI

/// Renders a chat message as ordered inline-markdown prose + fenced code blocks.
/// Prose uses `AttributedString(markdown:)` (bold/italic/links/inline-code); code blocks
/// render in a monospaced, horizontally-scrollable card with a copy button.
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
                }
            }
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
