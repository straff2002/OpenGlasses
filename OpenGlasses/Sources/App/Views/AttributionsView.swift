import SwiftUI

/// Third-party model and library attributions, linked from Settings › About. Each entry
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
            name: "Fingerspelling recognition model",
            role: "On-device ASL fingerspelling recognition (Plan CK). Trained on the Google ASL Fingerspelling corpus by Google and the Deaf Professional Arts Network.",
            license: "Model Apache 2.0 · corpus CC BY 4.0"),
        Attribution(
            name: "MediaPipe holistic landmarker",
            role: "Hand, pose, and face landmark extraction feeding the fingerspelling recognizer (Google MediaPipe).",
            license: "Apache 2.0"),
        Attribution(
            name: "Kokoro TTS",
            role: "On-device neural text-to-speech voice tier.",
            license: "Apache 2.0"),
        Attribution(
            name: "SenseVoice ASR",
            role: "On-device speech recognition tier.",
            license: "Apache 2.0"),
    ]

    private let libraries: [Attribution] = [
        Attribution(
            name: "MediaPipe Tasks",
            role: "Vision task runtime for the landmark pipeline (Google).",
            license: "Apache 2.0"),
        Attribution(
            name: "sherpa-onnx",
            role: "On-device speech runtime behind the Kokoro and SenseVoice tiers (k2-fsa).",
            license: "Apache 2.0"),
        Attribution(
            name: "ONNX Runtime",
            role: "Inference engine backing sherpa-onnx (Microsoft).",
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
