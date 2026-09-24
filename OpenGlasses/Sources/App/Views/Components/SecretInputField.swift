import SwiftUI

/// A secret-entry field for API keys and tokens (Plan BH hardening). Plain `SecureField`s fight
/// iOS paste for long random strings; this pairs one with an explicit paste button and a
/// reveal toggle so users can paste a key and verify it landed intact.
struct SecretInputField: View {
    let placeholder: String
    @Binding var text: String
    @State private var revealed = false
    @FocusState private var secureFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if revealed {
                    TextField(placeholder, text: $text)
                } else {
                    // A SecureField handed an existing long key has been seen drawing nothing on iOS 26
                    // (no dots, no placeholder), so a saved key read as missing. While it isn't
                    // being edited, a stored key shows as a masked summary instead; tapping it
                    // focuses the real field underneath.
                    ZStack(alignment: .leading) {
                        SecureField(placeholder, text: $text)
                            .focused($secureFocused)
                            .opacity(showsSavedSummary ? 0 : 1)
                            .accessibilityHidden(showsSavedSummary)
                        if showsSavedSummary {
                            Text(Self.maskedSummary(of: text))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(.rect)
                                .onTapGesture { secureFocused = true }
                                .accessibilityLabel("Key saved")
                                .accessibilityAddTraits(.isButton)
                                .accessibilityHint("Double-tap to replace it")
                        }
                    }
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.body.monospaced())

            Button {
                if let pasted = UIPasteboard.general.string {
                    text = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } label: {
                // Drawn as a bare glyph, which measured about 26×17 — under the 44pt floor on a
                // field a user has to operate to get the app working at all. The target grows;
                // the glyph stays exactly where it was drawn.
                Image(systemName: "doc.on.clipboard")
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Paste")

            Button {
                revealed.toggle()
            } label: {
                Image(systemName: revealed ? "eye.slash" : "eye")
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(revealed ? "Hide" : "Reveal")
        }
    }

    private var showsSavedSummary: Bool { !secureFocused && !text.isEmpty }

    /// Bullets plus the last four characters, the way provider consoles list a key — enough to
    /// tell which key is stored without putting the secret on screen.
    static func maskedSummary(of key: String) -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 8 else { return "••••••••" }
        return "••••••••" + String(trimmed.suffix(4))
    }
}
