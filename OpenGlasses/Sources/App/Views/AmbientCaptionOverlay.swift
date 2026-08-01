import SwiftUI

/// Floating overlay that displays real-time ambient captions.
/// Shows the current live caption and recent history, auto-fading old entries.
/// Diarized captions carry a tappable speaker chip (BM P7) — tap to name the speaker; names
/// persist through `SpeakerRegistry` and merge-on-same-name keeps colours consistent.
struct AmbientCaptionOverlay: View {
    @ObservedObject var captionService: AmbientCaptionService

    /// Bumped after a rename so chip labels re-resolve (the registry itself isn't observable).
    @State private var registryVersion = 0
    @State private var renameSpeakerId: Int?
    @State private var renameText = ""

    private var isRenaming: Binding<Bool> {
        Binding(get: { renameSpeakerId != nil }, set: { if !$0 { renameSpeakerId = nil } })
    }

    var body: some View {
        VStack(spacing: 4) {
            // Recent history (faded)
            ForEach(captionService.captionHistory.prefix(3).reversed()) { entry in
                historyRow(entry)
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
        .id(registryVersion)
        .padding(.horizontal, 20)
        .transition(.opacity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Live captions")
        .alert("Name this speaker", isPresented: isRenaming) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let id = renameSpeakerId {
                    captionService.speakerRegistry.setName(renameText, for: id)
                    registryVersion += 1
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Captions from this voice will show this name. Give two chips the same name to merge them.")
        }
    }

    @ViewBuilder
    private func historyRow(_ entry: AmbientCaptionService.CaptionEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let chip = SpeakerChipModel.chip(speaker: entry.speaker, registry: captionService.speakerRegistry) {
                SpeakerChipView(chip: chip) {
                    renameText = captionService.speakerRegistry.name(for: chip.speakerId) ?? ""
                    renameSpeakerId = chip.speakerId
                }
            }
            VStack(spacing: 1) {
                Text(entry.text)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                // Show-original ribbon (BY P2): the source-language words under the translation.
                if Config.translationShowOriginal, let original = entry.original {
                    Text(original)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.white.opacity(0.35))
                        .lineLimit(1)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }
}

/// Small tappable capsule naming the diarized speaker of a caption row (Plan AQ visibility).
/// The palette has `SpeakerRegistry.paletteSize` slots; `chip.colorIndex` is already in range.
private struct SpeakerChipView: View {
    static let palette: [Color] = [.gray, .blue, .green, .orange, .purple, .pink, .teal, .indigo]

    let chip: SpeakerChip
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text(chip.label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Self.palette[chip.colorIndex % Self.palette.count].opacity(0.85)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Speaker \(chip.label). Tap to name.")
    }
}
