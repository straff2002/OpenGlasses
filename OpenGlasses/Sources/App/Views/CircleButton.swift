import SwiftUI

/// A translucent glass-morphism circular button — the session surface's round control primitive,
/// drawn for chrome laid over a media ground rather than over the canvas.
///
/// Currently unreferenced: the control dock absorbed its call sites into `BarButton`. Brought onto
/// the tokens with the rest of the surface (DG P4) rather than left as an un-audited idiom for
/// someone to reach for; whether it survives at all is a question for the long-tail pass.
struct CircleButton: View {
    let icon: String
    var size: CGFloat = 52
    var isActive: Bool = false
    var isDisabled: Bool = false
    var badge: String? = nil
    var label: String? = nil
    let action: () -> Void

    @Environment(\.appAccent) private var accent

    private var foreground: Color {
        // The disabled state is the audited quiet role, not a quarter-opacity
        // white — the same correction the dock's tiles took.
        if isDisabled { return OGTheme.onMedia.opacity(OGTheme.Opacity.onMediaQuiet) }
        if isActive { return OGTheme.onMedia }
        return OGTheme.onMedia.opacity(OGTheme.Opacity.onMediaSecondary)
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Image(systemName: icon)
                    .font(.system(size: size * 0.36, weight: .medium))
                    .foregroundStyle(foreground)

                if let badge {
                    Text(badge)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(OGTheme.onAccentLabel(accent))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(accent, in: Capsule())
                        .offset(x: size * 0.3, y: -size * 0.3)
                }
            }
            .frame(width: size, height: size)
            .background(isActive ? accent.opacity(OGTheme.Opacity.accentFill) : Color.clear)
            .glassEffect(in: .circle)
        }
        .disabled(isDisabled)
        .accessibilityLabel(label ?? icon.replacingOccurrences(of: ".fill", with: "").replacingOccurrences(of: ".", with: " "))
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}
