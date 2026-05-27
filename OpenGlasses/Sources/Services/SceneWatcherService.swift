import Foundation
import UIKit

/// Background service that periodically captures frames from the glasses camera
/// and sends them to the LLM for proactive scene analysis. Speaks up only when
/// something notable, urgent, or interesting is detected.
///
/// Inspired by MMDuet2's proactive AI concept, but uses existing LLM providers
/// instead of a custom model.
@MainActor
final class SceneWatcherService: ObservableObject {
    @Published var isRunning = false
    @Published var lastObservation: String?
    @Published var observationCount: Int = 0

    /// How often to check the scene (seconds). Default 15s, configurable.
    var checkInterval: TimeInterval = 15

    /// Callback to speak a proactive observation through TTS.
    var onObservation: ((String) -> Void)?

    /// Callback to send a frame + prompt to the LLM and get a response.
    /// Takes (prompt, imageData) and returns the LLM's response.
    var onAnalyzeFrame: ((String, Data) async -> String?)?

    private var watcherTask: Task<Void, Never>?
    private weak var cameraService: CameraService?

    /// Track recent observations to avoid repeating the same thing.
    private var recentObservations: [String] = []
    private let maxRecentObservations = 10

    // MARK: - Lifecycle

    init(cameraService: CameraService) {
        self.cameraService = cameraService
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        recentObservations.removeAll()

        watcherTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkScene()
                try? await Task.sleep(nanoseconds: UInt64((self?.checkInterval ?? 15) * 1_000_000_000))
            }
        }

        NSLog("[SceneWatcher] Started — checking every %.0fs", checkInterval)
    }

    func stop() {
        watcherTask?.cancel()
        watcherTask = nil
        isRunning = false
        NSLog("[SceneWatcher] Stopped")
    }

    // MARK: - Scene Analysis

    private func checkScene() async {
        guard let camera = cameraService,
              let frame = camera.latestFrame,
              let imageData = frame.jpegData(compressionQuality: 0.5) else {
            return
        }

        guard let analyze = onAnalyzeFrame else { return }

        let prompt = buildAnalysisPrompt()

        guard let response = await analyze(prompt, imageData) else { return }

        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)

        // Only speak if the LLM returned something meaningful
        if !trimmed.isEmpty &&
            trimmed.uppercased() != "NONE" &&
            trimmed.uppercased() != "NOTHING" &&
            trimmed.count > 5 &&
            !isDuplicate(trimmed) {

            lastObservation = trimmed
            observationCount += 1
            recentObservations.append(trimmed.prefix(100).lowercased().description)
            if recentObservations.count > maxRecentObservations {
                recentObservations.removeFirst()
            }

            NSLog("[SceneWatcher] Observation #%d: %@", observationCount, String(trimmed.prefix(100)))
            onObservation?(trimmed)
        }
    }

    private func buildAnalysisPrompt() -> String {
        var prompt = """
        You are a proactive visual assistant on smart glasses. Analyze this scene briefly.

        RESPOND ONLY IF you see something that is:
        - Safety-critical (obstacles, hazards, vehicles approaching, wet floor)
        - Notably interesting (famous landmark, unusual event, wildlife)
        - Practically useful (parking meter expiring, store closing sign, menu special)
        - A significant change from the user's recent environment

        If NOTHING notable, reply with exactly: NONE

        Rules:
        - Keep responses under 2 sentences
        - Be specific and actionable
        - Don't describe mundane things (walls, floors, sky, regular people walking)
        - Don't repeat observations you've already made
        - This is spoken aloud — no markdown, no formatting
        """

        if !recentObservations.isEmpty {
            prompt += "\n\nRecent observations (don't repeat): \(recentObservations.suffix(5).joined(separator: "; "))"
        }

        return prompt
    }

    /// Check if this observation is too similar to a recent one.
    private func isDuplicate(_ observation: String) -> Bool {
        let lower = observation.prefix(80).lowercased()
        return recentObservations.contains { recent in
            // Simple substring overlap check
            let overlap = lower.filter { recent.contains(String($0)) }.count
            let similarity = Double(overlap) / Double(max(lower.count, 1))
            return similarity > 0.7
        }
    }
}
