import SwiftUI

/// A secret-entry field for API keys and tokens (Plan BH hardening). Plain `SecureField`s fight
/// iOS paste for long random strings; this pairs one with an explicit paste button and a
/// reveal toggle so users can paste a key and verify it landed intact.
struct SecretInputField: View {
    let placeholder: String
    @Binding var text: String
    @State private var revealed = false

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if revealed {
                    TextField(placeholder, text: $text)
                } else {
                    SecureField(placeholder, text: $text)
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
}
