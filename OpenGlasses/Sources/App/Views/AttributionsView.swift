import SwiftUI

/// Third-party model, library and data attributions, linked from Settings › About. Each entry
/// names the component, its role in the app, and its licence; adding a row here is part
/// of shipping any new bundled or downloaded model (the CK plan's About-attribution
/// requirement established the pattern).
@MainActor
struct AttributionsView: View {

    private struct Attribution: Identifiable {
        let id = UUID()
        let name: String
        let role: String
        let license: String
    }

    private let models: [Attribution] = [
        Attribution(
            name: String(localized: "Fingerspelling recognition model"),
            role: String(localized: "On-device ASL fingerspelling recognition. Trained on the Google ASL Fingerspelling corpus by Google and the Deaf Professional Arts Network."),
            license: String(localized: "Model Apache 2.0 · corpus CC BY 4.0")),
        Attribution(
            name: "MediaPipe holistic landmarker",
            role: String(localized: "Hand, pose, and face landmark extraction feeding the fingerspelling recognizer (Google MediaPipe)."),
            license: "Apache 2.0"),
        Attribution(
            name: "Kokoro TTS",
            role: String(localized: "On-device neural text-to-speech voice tier."),
            license: "Apache 2.0"),
        Attribution(
            name: "SenseVoice ASR",
            role: String(localized: "On-device speech recognition tier."),
            license: "Apache 2.0"),
    ]

    private let libraries: [Attribution] = [
        Attribution(
            name: "MediaPipe Tasks",
            role: String(localized: "Vision task runtime for the landmark pipeline (Google)."),
            license: "Apache 2.0"),
        Attribution(
            name: "sherpa-onnx",
            role: String(localized: "On-device speech runtime behind the Kokoro and SenseVoice tiers (k2-fsa)."),
            license: "Apache 2.0"),
        Attribution(
            name: "ONNX Runtime",
            role: String(localized: "Inference engine backing sherpa-onnx (Microsoft)."),
            license: "MIT"),
    ]

    /// Data generated offline from an open library and bundled — not linked code. The version
    /// matches every bundled table's `libraryVersion` (SaturationTableNoticeTests).
    private let referenceData: [Attribution] = [
        Attribution(
            name: "CoolProp 8.0.0",
            role: String(localized: "Refrigerant saturation (pressure–temperature) tables, generated offline. Copyright (c) 2012-2018 Ian H. Bell and other CoolProp developers."),
            license: "MIT"),
    ]

    var body: some View {
        OGScrollPage {
            OGSection(
                header: "Models",
                footer: "Downloaded models run entirely on this device; camera frames and audio never leave it for these features."
            ) {
                rows(models)
            }

            OGSection(header: "Libraries") {
                rows(libraries)
            }

            OGSection(header: "Reference data") {
                rows(referenceData)
            }
        }
        .navigationTitle("Attributions")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func rows(_ attributions: [Attribution]) -> some View {
        ForEach(Array(attributions.enumerated()), id: \.element.id) { index, entry in
            if index > 0 { OGDivider() }
            OGRow(entry.name, subtitle: entry.role, showsChevron: false) {
                Text(entry.license)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 120, alignment: .trailing)
            }
        }
    }
}

#Preview {
    NavigationStack {
        AttributionsView()
    }
}
