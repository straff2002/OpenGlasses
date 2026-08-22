import SwiftUI

struct LLMImageSettingsView: View {
    @State private var preset = Config.llmImagePreset
    @State private var customMaxLongEdge = Double(Config.llmImageCustomMaxLongEdge)
    @State private var customMaxMegabytes = Double(Config.llmImageCustomMaxBytes) / 1_000_000
    @State private var customJPEGQuality = Double(Config.llmImageCustomJPEGQuality)
    @State private var lightweightPrompt = Config.llmImageLightweightPromptEnabled

    var body: some View {
        Form {
            Section {
                Toggle("Small context", isOn: $lightweightPrompt)
                    .onChange(of: lightweightPrompt) { _, value in
                        Config.setLLMImageLightweightPromptEnabled(value)
                    }
            } footer: {
                Text("Send a short spoken-style prompt, your last few lines, and the photo if any — no tool list or full system prompt. Off by default. Turn on for tight providers like Groq (8k token cap).")
            }

            Section {
                Picker("Preset", selection: $preset) {
                    ForEach(LLMImagePreset.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .onChange(of: preset) { _, value in
                    Config.setLLMImagePreset(value)
                }
            } footer: {
                Text(presetFooter)
            }

            if preset == .custom {
                Section {
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Max long edge")
                            Spacer()
                            Text("\(Int(customMaxLongEdge)) px").foregroundStyle(.secondary)
                        }
                        Slider(value: $customMaxLongEdge, in: 768...2576, step: 64)
                            .onChange(of: customMaxLongEdge) { _, value in
                                Config.setLLMImageCustomMaxLongEdge(Int(value))
                            }
                    }

                    VStack(alignment: .leading) {
                        HStack {
                            Text("Max file size")
                            Spacer()
                            Text(String(format: "%.1f MB", customMaxMegabytes)).foregroundStyle(.secondary)
                        }
                        Slider(value: $customMaxMegabytes, in: 0.4...4.5, step: 0.1)
                            .onChange(of: customMaxMegabytes) { _, value in
                                Config.setLLMImageCustomMaxBytes(Int(value * 1_000_000))
                            }
                    }

                    VStack(alignment: .leading) {
                        HStack {
                            Text("JPEG quality")
                            Spacer()
                            Text(String(format: "%.0f%%", customJPEGQuality * 100)).foregroundStyle(.secondary)
                        }
                        Slider(value: $customJPEGQuality, in: 0.4...0.95, step: 0.05)
                            .onChange(of: customJPEGQuality) { _, value in
                                Config.setLLMImageCustomJPEGQuality(CGFloat(value))
                            }
                    }
                } header: {
                    Text("Custom")
                } footer: {
                    Text("Images are downscaled to the long-edge limit, then JPEG-compressed until they fit the size cap.")
                }
            }

            if preset != .custom {
                Section {
                    LabeledContent("Long edge", value: "\(Int(activeLimits.maxLongEdge)) px")
                    LabeledContent("Size cap", value: formattedBytes(activeLimits.maxBytes))
                } header: {
                    Text("Active Limits")
                } footer: {
                    Text(preset == .original
                         ? "Photos are sent as captured unless they exceed the provider's hard limit, which these bounds enforce."
                         : "")
                }
            }
        }
        .navigationTitle("Vision Images")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var activeLimits: LLMImagePreparer.Limits {
        LLMImagePreparer.limits
    }

    private var presetFooter: String { preset.explanation }

    private func formattedBytes(_ bytes: Int) -> String {
        if bytes >= 1_000_000 {
            return String(format: "%.1f MB", Double(bytes) / 1_000_000)
        }
        return String(format: "%.0f KB", Double(bytes) / 1000)
    }
}
