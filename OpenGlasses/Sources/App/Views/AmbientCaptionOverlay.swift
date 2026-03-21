import SwiftUI

/// Floating overlay that displays real-time ambient captions.
/// Shows the current live caption and recent history, auto-fading old entries.
struct AmbientCaptionOverlay: View {
    @ObservedObject var captionService: AmbientCaptionService

    var body: some View {
        VStack(spacing: 4) {
            // Recent history (faded)
            ForEach(captionService.captionHistory.prefix(3).reversed()) { entry in
                Text(entry.text)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }

            // Current live caption
            if !captionService.currentCaption.isEmpty {
                Text(captionService.currentCaption)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.black.opacity(0.7))
                    )
                    .animation(.easeOut(duration: 0.15), value: captionService.currentCaption)
                    .accessibilityLabel(captionService.currentCaption)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .padding(.horizontal, 20)
        .transition(.opacity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Live captions")
    }
}
