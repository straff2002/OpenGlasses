import Foundation
import Hub
import MLXLLM
import MLXLMCommon

/// Manages on-device LLM inference via Apple's MLX framework.
/// Handles model downloading, loading, generation, and lifecycle.
@MainActor
final class LocalLLMService: ObservableObject {
    @Published var isModelLoaded = false
    @Published var downloadProgress: Double = 0
    @Published var isDownloading = false
    @Published var isGenerating = false
    @Published var loadedModelId: String?

    private var modelContainer: ModelContainer?

    /// HubApi configured to store models in Application Support (persistent, not purgeable).
    private let hub: HubApi = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let modelsDir = appSupport.appendingPathComponent("LocalModels", isDirectory: true)
        try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        return HubApi(downloadBase: modelsDir)
    }()

    // MARK: - Recommended Models

    static let recommendedModels: [RecommendedModel] = [
        RecommendedModel(
            id: "mlx-community/gemma-2-2b-it-4bit",
            name: "Gemma 2 2B",
            estimatedSize: "1.5 GB",
            hasVision: false,
            hasToolCalling: true,
            notes: "Good balance of size and quality"
        ),
        RecommendedModel(
            id: "mlx-community/Qwen2.5-3B-Instruct-4bit",
            name: "Qwen 2.5 3B",
            estimatedSize: "1.8 GB",
            hasVision: false,
            hasToolCalling: true,
            notes: "Strong reasoning and tool use"
        ),
        RecommendedModel(
            id: "mlx-community/Qwen2.5-0.5B-Instruct-4bit",
            name: "Qwen 2.5 0.5B",
            estimatedSize: "0.4 GB",
            hasVision: false,
            hasToolCalling: true,
            notes: "Ultra-light, basic capability"
        ),
        RecommendedModel(
            id: "mlx-community/SmolLM2-1.7B-Instruct-4bit",
            name: "SmolLM2 1.7B",
            estimatedSize: "1.0 GB",
            hasVision: false,
            hasToolCalling: false,
            notes: "Compact and fast"
        ),
    ]

    // MARK: - Model Management

    /// Download a model from HuggingFace without loading into memory.
    /// This avoids OOM crashes on devices with limited RAM.
    func downloadModel(_ modelId: String) async throws {
        isDownloading = true
        downloadProgress = 0
        defer { isDownloading = false }

        // Download files only — don't load into GPU memory
        let repo = Hub.Repo(id: modelId)
        _ = try await hub.snapshot(from: repo) { progress in
            Task { @MainActor in
                self.downloadProgress = progress.fractionCompleted
            }
        }

        downloadProgress = 1.0
        print("✅ Local model downloaded: \(modelId)")
    }

    /// Load an already-downloaded model into memory.
    func loadModel(_ modelId: String) async throws {
        if loadedModelId == modelId && isModelLoaded {
            return  // Already loaded
        }

        unloadModel()

        let config = ModelConfiguration(id: modelId)
        modelContainer = try await LLMModelFactory.shared.loadContainer(
            hub: hub, configuration: config
        ) { progress in
            Task { @MainActor in
                self.downloadProgress = progress.fractionCompleted
            }
        }

        loadedModelId = modelId
        isModelLoaded = true
        print("✅ Local model loaded: \(modelId)")
    }

    /// Unload model from memory.
    func unloadModel() {
        modelContainer = nil
        loadedModelId = nil
        isModelLoaded = false
        print("🔄 Local model unloaded")
    }

    // MARK: - Generation

    /// Generate a text response from the local model.
    func generate(
        userMessage: String,
        systemPrompt: String,
        history: [(role: String, content: String)] = []
    ) async throws -> String {
        guard let container = modelContainer else {
            throw LocalLLMError.modelNotLoaded
        }

        isGenerating = true
        defer { isGenerating = false }

        // Build messages for chat template
        var messages: [[String: String]] = [
            ["role": "system", "content": systemPrompt]
        ]
        for turn in history {
            messages.append(["role": turn.role, "content": turn.content])
        }
        messages.append(["role": "user", "content": userMessage])

        // Tokenize using chat template
        let tokens = try await container.applyChatTemplate(messages: messages)
        let input = LMInput(text: .init(tokens: .init(tokens)))

        // Generate
        let parameters = GenerateParameters(maxTokens: 512, temperature: 0.7, topP: 0.9)
        let stream = try await container.generate(input: input, parameters: parameters)

        var output = ""
        for try await generation in stream {
            switch generation {
            case .chunk(let text):
                output += text
            case .info:
                break  // Generation complete info
            case .toolCall:
                break  // Handled at a higher level via text parsing
            @unknown default:
                break
            }
        }

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Storage Info

    /// Persistent model storage directory (Application Support, never purged by iOS).
    var modelDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("LocalModels", isDirectory: true)
    }

    /// The models subdirectory where Hub stores model repos.
    private var modelsSubdir: URL {
        modelDirectory.appendingPathComponent("models", isDirectory: true)
    }

    /// Get the on-disk path for a model (matches Hub's storage: downloadBase/models/{org}/{name}).
    private func modelPath(_ modelId: String) -> URL {
        modelsSubdir.appendingPathComponent(modelId, isDirectory: true)
    }

    /// Check if a model is downloaded.
    func isModelDownloaded(_ modelId: String) -> Bool {
        FileManager.default.fileExists(atPath: modelPath(modelId).path)
    }

    /// Get size of a downloaded model on disk.
    func modelSizeOnDisk(_ modelId: String) -> Int64 {
        directorySize(modelPath(modelId))
    }

    /// Delete a downloaded model.
    func deleteModel(_ modelId: String) throws {
        if loadedModelId == modelId {
            unloadModel()
        }
        let path = modelPath(modelId)
        if FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.removeItem(at: path)
            print("🗑️ Deleted local model: \(modelId)")
        }
    }

    /// List all downloaded model IDs by scanning the models directory.
    func downloadedModelIds() -> [String] {
        // Hub stores as: downloadBase/models/{org}/{modelName}
        guard let orgs = try? FileManager.default.contentsOfDirectory(
            at: modelsSubdir, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        var ids: [String] = []
        for orgDir in orgs {
            guard orgDir.hasDirectoryPath || (try? orgDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let org = orgDir.lastPathComponent
            if org.hasPrefix(".") { continue }
            if let models = try? FileManager.default.contentsOfDirectory(
                at: orgDir, includingPropertiesForKeys: nil
            ) {
                for modelDir in models {
                    let modelName = modelDir.lastPathComponent
                    if modelName.hasPrefix(".") { continue }
                    ids.append("\(org)/\(modelName)")
                }
            }
        }
        return ids.sorted()
    }

    // MARK: - Helpers

    private func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }
}

// MARK: - Types

enum LocalLLMError: LocalizedError {
    case modelNotLoaded
    case generationFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "No local model is loaded. Download one in Settings → AI Models."
        case .generationFailed(let reason):
            return "Local model generation failed: \(reason)"
        }
    }
}

struct RecommendedModel: Identifiable {
    let id: String
    let name: String
    let estimatedSize: String
    let hasVision: Bool
    let hasToolCalling: Bool
    let notes: String
}
