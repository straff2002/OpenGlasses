import SwiftUI

/// Floating overlay that displays real-time ambient captions.
/// Shows the current live caption and recent history, auto-fading old entries.
/// Diarized captions carry a tappable speaker chip (BM P7) — tap to name the speaker; names
/// persist through `SpeakerRegistry` and merge-on-same-name keeps colours consistent.
///
/// **Accessibility (Plan DF P2, decided).** This surface is a *readable history*, never a live
/// region. Captions are speech that already happened in the room: a blind user heard it, and
/// pushing every new line at them through VoiceOver would narrate a conversation back at them a
/// beat late while burying the app's own state announcements. The people this overlay serves —
/// deaf and hard-of-hearing users — read it with their eyes, which is why the work here is
/// Dynamic Type and per-row focusability instead. So: no `.announcement` posts, rows individually
/// focusable so the last few lines can be swiped back through, and `.updatesFrequently` on the
/// live line so it re-reads only for a user who has chosen to hold focus there.
struct AmbientCaptionOverlay: View {
    @ObservedObject var captionService: AmbientCaptionService

    /// Bumped after a rename so chip labels re-resolve (the registry itself isn't observable).
    @State private var registryVersion = 0
    @State private var renameSpeakerId: Int?
    @State private var renameText = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Captions are the one surface in the app whose *entire* job is to be read, so the type has
    /// to grow with the reader. Fixed point sizes held the caption at 16pt however large the
    /// system text was set — which fails exactly the deaf or hard-of-hearing user this overlay
    /// exists for. `@ScaledMetric` keeps the shipped look at the default size and scales from
    /// there. DG P4 finished the job the caps were still blocking — see `capsLines`.
    @ScaledMetric(relativeTo: .body) private var captionSize: CGFloat = 16
    @ScaledMetric(relativeTo: .subheadline) private var historySize: CGFloat = 14
    @ScaledMetric(relativeTo: .caption) private var originalSize: CGFloat = 11
    @ScaledMetric(relativeTo: .caption2) private var legLabelSize: CGFloat = 10
    @ScaledMetric(relativeTo: .caption) private var legPlaceholderSize: CGFloat = 12
    @Environment(\.dynamicTypeSize) private var typeSize

    /// The line caps that keep the stack a fixed number of lines are a density
    /// choice, and density stops being the right trade at accessibility sizes:
    /// a reader who has asked for larger text is the reader this overlay exists
    /// for, and a caption they can only read half of is worse than a taller
    /// panel. So above the threshold every cap here comes off.
    private var capsLines: Bool { !typeSize.isAccessibilitySize }

    private var isRenaming: Binding<Bool> {
        Binding(get: { renameSpeakerId != nil }, set: { if !$0 { renameSpeakerId = nil } })
    }

    var body: some View {
        VStack(spacing: 4) {
            if Config.translationTwoWayEnabled, captionService.translationActive {
                // Two-way conversation split (BY P3): the interlocutor's leg on top (their
                // language), the wearer's leg below — each side reads their own half.
                twoWayLeg(wearer: false)
                Divider()
                    .overlay(OGTheme.onMedia.opacity(OGTheme.Opacity.onMediaHairline))
                    .padding(.horizontal, 40)
                twoWayLeg(wearer: true)
            } else {
                // Recent history (faded)
                ForEach(captionService.captionHistory.prefix(3).reversed()) { entry in
                    historyRow(entry)
                }
            }

            // Current live caption
            if !captionService.currentCaption.isEmpty {
                Text(captionService.currentCaption)
                    .font(.system(size: captionSize, weight: .medium))
                    .foregroundStyle(OGTheme.onMedia)
                    .lineLimit(capsLines ? 3 : nil)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.15),
                               value: captionService.currentCaption)
                    .accessibilityLabel("Now: \(captionService.currentCaption)")
                    // `.updatesFrequently` is deliberately as far as this goes: it re-reads the
                    // line while a user holds focus here, and says nothing when they don't.
                    // See the header note on why nothing here is *pushed* at anyone.
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .id(registryVersion)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        // **One ground for the whole stack, and an opaque one.** Until now only
        // the live line had a backing; the history and the translation legs sat
        // directly on whatever the session surface happened to be drawing, which
        // made their contrast not thin but *undefined* — there was nothing to
        // measure against.
        //
        // Opaque rather than a wash, for two reasons that point the same way. It
        // is the media ground the palette already measures, so the caption roles
        // are covered by the `media …` pairs P3 established instead of needing a
        // scrim token of their own; and a translucent ground is one the audit
        // cannot measure either — a 0.8 wash was tried, and the contrast check
        // reported failures on a stack whose rendered pixels measure 8.8:1,
        // because it samples the declared background rather than the composite.
        // A ground that is only *nearly* opaque buys nothing at this darkness:
        // the two differ by about 0.03 in relative luminance.
        //
        // One block behind the whole stack also reads as a caption panel rather
        // than as four separately-floating lines with one of them boxed.
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(OGTheme.media)
        )
        .padding(.horizontal, 20)
        .transition(.opacity)
        // `children: .contain` is the whole decision: the rows stay individually focusable, so a
        // VoiceOver user can swipe back through what was said instead of being read at.
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

    /// One leg of the two-way split: entries whose *render* language belongs to this side.
    /// Wearer leg = entries translated into the wearer's language (leg A).
    @ViewBuilder
    private func twoWayLeg(wearer: Bool) -> some View {
        let direction = TranslationRouting.currentDirection()
        let entries = captionService.captionHistory.prefix(6).reversed().filter { entry in
            TranslationRouting.isWearerLeg(detected: entry.language, direction: direction,
                                           wearerLanguage: Config.translationWearerLanguage) == wearer
        }
        let legLanguage = wearer ? Config.translationLanguageA : Config.translationLanguageB
        VStack(spacing: 2) {
            Text("→ \(TranslationLanguages.displayName(for: legLanguage))")
                .font(.system(size: legLabelSize, weight: .semibold))
                .foregroundStyle(OGTheme.onMedia.opacity(OGTheme.Opacity.onMediaTertiary))
                // The arrow is drawn punctuation; VoiceOver reads it as "right arrow".
                .accessibilityLabel("Translated into \(TranslationLanguages.displayName(for: legLanguage))")
                .accessibilityAddTraits(.isHeader)
            if entries.isEmpty {
                Text("…")
                    .font(.system(size: legPlaceholderSize))
                    .foregroundStyle(OGTheme.onMedia.opacity(OGTheme.Opacity.onMediaTertiary))
                    .accessibilityLabel("Nothing said yet")
            } else {
                ForEach(entries.suffix(2)) { entry in
                    historyRow(entry)
                }
            }
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
                // Each line steps down one role rather than two: on the scrim's
                // worst-case ground the quiet role is within rounding of AA, so
                // the caption stack now runs full → secondary → tertiary and
                // leaves the quiet floor to the surfaces that sit on real black.
                Text(entry.text)
                    .font(.system(size: historySize, weight: .regular))
                    .foregroundStyle(OGTheme.onMedia.opacity(OGTheme.Opacity.onMediaSecondary))
                    .lineLimit(capsLines ? 2 : nil)
                    .multilineTextAlignment(.center)
                // Show-original ribbon (BY P2): the source-language words under the translation.
                if Config.translationShowOriginal, let original = entry.original {
                    Text(original)
                        .font(.system(size: originalSize, weight: .regular))
                        .foregroundStyle(OGTheme.onMedia.opacity(OGTheme.Opacity.onMediaTertiary))
                        .lineLimit(capsLines ? 1 : nil)
                        .multilineTextAlignment(.center)
                }
            }
            // One past line, one stop — read back as a sentence rather than as a translation
            // and its original arriving as two unrelated fragments. The speaker chip beside it
            // stays its own element: it is a button, and a rename has to remain reachable.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spokenHistoryLabel(entry))
        }
    }

    /// A past caption as it should be heard: who said it, what they said, and — only when the
    /// original is on screen — what it was before translation.
    private func spokenHistoryLabel(_ entry: AmbientCaptionService.CaptionEntry) -> String {
        var line = entry.text
        if let chip = SpeakerChipModel.chip(speaker: entry.speaker, registry: captionService.speakerRegistry) {
            line = "\(chip.label): \(entry.text)"
        }
        if Config.translationShowOriginal, let original = entry.original, !original.isEmpty {
            line += ". Original: \(original)"
        }
        return line
    }
}

/// Small tappable capsule naming the diarized speaker of a caption row (Plan AQ visibility).
/// The palette has `SpeakerRegistry.paletteSize` slots; `chip.colorIndex` is already in range.
private struct SpeakerChipView: View {
    static let palette: [Color] = [.gray, .blue, .green, .orange, .purple, .pink, .teal, .indigo]

    let chip: SpeakerChip
    let onTap: () -> Void

    private var chipColor: Color { Self.palette[chip.colorIndex % Self.palette.count] }

    @ScaledMetric(relativeTo: .caption) private var chipSize: CGFloat = 11

    var body: some View {
        Button(action: onTap) {
            Text(chip.label)
                .font(.system(size: chipSize, weight: .semibold))
                // The chip's hue is the *ground*, so the label is whichever pole
                // reads on it — always-white lost the pale slots outright.
                .foregroundStyle(OGTheme.onAccentLabel(chipColor))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(chipColor))
                // **The chip's target, decided.** It was drawn at about 20pt and
                // the earlier phases would not grow it, because a 44pt floor
                // reflows the caption stack — which was true, and was their call
                // to defer rather than to make. Made here: the target grows, the
                // drawn capsule does not, and the row grows with it.
                //
                // The alternatives were worse. An overlay target that overhangs
                // its row without taking layout space is 44pt of tappable area
                // across rows that sit ~20pt apart, so three chips overlap and a
                // tap near a boundary names the wrong speaker — a control that
                // is easier to hit and easier to get wrong. Making the whole
                // caption row the rename control would give the target for free,
                // but it makes reading text a rename gesture, which is new
                // behaviour on a surface this phase is not allowed to change.
                //
                // The cost is bounded by the thing that causes it: a row only
                // pays the extra height when it actually *has* a chip, so a
                // single-speaker stack — the default, with diarization off —
                // keeps exactly the density it ships with today.
                .frame(minWidth: OGMetrics.minTouchTarget,
                       minHeight: OGMetrics.minTouchTarget)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // The gesture instruction belongs in the hint, and the gesture is a double-tap.
        .accessibilityLabel("Speaker \(chip.label)")
        .accessibilityHint("Double-tap to name this speaker.")
    }
}
