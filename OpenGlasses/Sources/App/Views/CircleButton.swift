import SwiftUI

/// A translucent glass-morphism circular button. OpenGlasses' own take — no VisionClaw clones.
struct CircleButton: View {
    let icon: String
    var size: CGFloat = 52
    var isActive: Bool = false
    var isDisabled: Bool = false
    var badge: String? = nil
    var label: String? = nil
    let action: () -> Void

    private var foreground: Color {
        if isDisabled { return .white.opacity(0.25) }
        if isActive { return .white }
        return .white.opacity(0.85)
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Circle()
                            .fill(isActive ? Color.accentColor.opacity(0.25) : Color.clear)
                    )
                    .overlay(
                        Circle()
                            .strokeBorder(
                                isActive ? Color.accentColor.opacity(0.6) : Color.white.opacity(0.12),
                                lineWidth: 1
                            )
                    )

                Image(systemName: icon)
                    .font(.system(size: size * 0.36, weight: .medium))
                    .foregroundStyle(foreground)

                if let badge {
                    Text(badge)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.accentColor, in: Capsule())
                        .offset(x: size * 0.3, y: -size * 0.3)
                }
            }
            .frame(width: size, height: size)
        }
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.4 : 1)
        .accessibilityLabel(label ?? icon.replacingOccurrences(of: ".fill", with: "").replacingOccurrences(of: ".", with: " "))
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}
