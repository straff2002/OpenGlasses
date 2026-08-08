import Foundation
import Vision
import UIKit
import Combine

/// Recognizes faces from the glasses camera and matches them against a local database.
/// Whispers the person's name via TTS when a known face is detected.
@MainActor
class FaceRecognitionService: ObservableObject {
    @Published var isActive = false
    @Published var lastRecognizedName: String?
    @Published var knownFaces: [KnownFace] = []

    struct KnownFace: Codable, Identifiable {
        let id: String
        var name: String
        let faceprint: [Float]  // 128-dim face embedding vector
        let addedAt: Date
        var lastSeen: Date

        init(name: String, faceprint: [Float]) {
            self.id = UUID().uuidString
            self.name = name
            self.faceprint = faceprint
            self.addedAt = Date()
            self.lastSeen = Date()
        }
    }

    /// Callback to speak a name when recognized
    var onRecognition: ((String) -> Void)?

    /// CO Item 1: fired instead of `onRecognition` when two or more enrolled people are too close
    /// to separate. Names are ordered best-first, but the ordering is explicitly not a ranking the
    /// caller should collapse back into a single answer — that is the bug this exists to prevent.
    var onAmbiguousRecognition: (([String]) -> Void)?

    private var frameSubscription: AnyCancellable?
    private var processingFrame = false

    /// Cooldown — don't re-announce the same person within 60 seconds
    private var lastAnnouncedNames: [String: Date] = [:]
    private let announceCooldown: TimeInterval = 60

    /// Throttle — process only every Nth frame
    private var frameCount = 0
    private let processEveryNFrames = 15  // ~2 fps at 30fps input
    private let normalProcessEveryN = 15
    private let reducedProcessEveryN = 60  // ~0.5 fps — much less CPU in background
    private var currentProcessEveryN = 15

    /// Similarity threshold for matching (0-1, higher = stricter)
    private let matchThreshold: Float = 0.6

    private let storageURL: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        storageURL = docs.appendingPathComponent("known_faces.json")
        loadFaces()
    }

    // MARK: - Public API

    func start(cameraService: CameraService) {
        guard !isActive else { return }
        isActive = true
        frameCount = 0

        // Subscribe to the shared frame publisher with a stored cancellable (Plan: face-rec
        // lifecycle). The old code chained `cameraService.onVideoFrame`, which `stop()` never
        // detached — so recognition kept running after stop, and every start() stacked another
        // closure. A publisher subscription cancels cleanly and can't stack.
        frameSubscription = cameraService.framePublisher
            .sink { [weak self] image in
                Task { @MainActor in
                    guard let self, self.isActive else { return }
                    self.frameCount += 1
                    if self.frameCount % self.currentProcessEveryN == 0 && !self.processingFrame {
                        self.processFrame(image)
                    }
                }
            }

        print("👤 Face recognition started")
    }

    func stop() {
        isActive = false
        frameSubscription?.cancel()
        frameSubscription = nil
        lastRecognizedName = nil
        print("👤 Face recognition stopped")
    }

    /// Reduce processing frequency for background optimization (streaming priority).
    func reduceFrequency() {
        currentProcessEveryN = reducedProcessEveryN
        NSLog("[FaceRecognition] Reduced to background frequency")
    }

    /// Restore normal processing frequency.
    func restoreFrequency() {
        currentProcessEveryN = normalProcessEveryN
        NSLog("[FaceRecognition] Restored normal frequency")
    }

    /// Remember a face from the current camera frame with a name
    func rememberFace(name: String, from image: UIImage) async -> String {
        guard let cgImage = image.cgImage else {
            return "Couldn't process the image."
        }

        do {
            let faceprints = try await detectFaceprints(in: cgImage)
            if faceprints.isEmpty {
                return "No face detected in the image. Please make sure a face is clearly visible."
            }
            if faceprints.count > 1 {
                return "Multiple faces detected. Please make sure only one person is in frame."
            }

            let faceprint = faceprints[0]

            // Check if this person already exists. CO Item 1: this branch *renames an existing
            // record*, so acting on a near-tie is the destructive form of the confident-wrong bug —
            // enrolling one sibling would silently rewrite the other's name. Refuse and ask.
            switch classify(faceprint) {
            case .confident(let candidate):
                let oldName = knownFaces[candidate.index].name
                knownFaces[candidate.index].name = name
                knownFaces[candidate.index].lastSeen = Date()
                saveFaces()
                return "Updated \(oldName) to \(name)."

            case .ambiguous(let contenders):
                let names = contenders.map { knownFaces[$0.index].name }
                return "That face is too close to call between \(Self.spokenList(names)) — I won't "
                     + "rename the wrong person. Remove the one that's wrong in Settings, then "
                     + "save \(name) again."

            case .none:
                break
            }

            let face = KnownFace(name: name, faceprint: faceprint)
            knownFaces.append(face)
            saveFaces()
            return "Got it, I'll remember \(name)."
        } catch {
            return "Face detection failed: \(error.localizedDescription)"
        }
    }

    /// Forget a person by name
    func forgetFace(name: String) -> String {
        let target = name.lowercased()
        let before = knownFaces.count
        knownFaces.removeAll { $0.name.lowercased() == target }
        saveFaces()
        let removed = before - knownFaces.count
        if removed > 0 {
            return "Forgot \(name) (\(removed) face\(removed == 1 ? "" : "s") removed)."
        }
        return "No face found for '\(name)'."
    }

    /// List all known faces
    func listKnownFaces() -> String {
        if knownFaces.isEmpty {
            return "No faces saved yet. Say 'remember this person as [name]' while looking at someone."
        }
        let names = knownFaces.map { face -> String in
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            let lastSeen = formatter.localizedString(for: face.lastSeen, relativeTo: Date())
            return "\(face.name) (last seen \(lastSeen))"
        }
        return "Known faces: \(names.joined(separator: ", "))"
    }

    // MARK: - Frame Processing

    private func processFrame(_ image: UIImage) {
        guard isActive, let cgImage = image.cgImage, !knownFaces.isEmpty else { return }
        processingFrame = true

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            do {
                // `detectFaceprints` is nonisolated, so this Vision work runs off the main actor
                // (the old code left it main-isolated, so the detached task hopped straight back).
                let faceprints = try await self.detectFaceprints(in: cgImage)

                await MainActor.run {
                    for faceprint in faceprints {
                        switch self.classify(faceprint) {
                        case .confident(let candidate):
                            let name = self.knownFaces[candidate.index].name
                            self.knownFaces[candidate.index].lastSeen = Date()
                            self.lastRecognizedName = name

                            // Check cooldown before announcing
                            if let lastAnnounced = self.lastAnnouncedNames[name],
                               Date().timeIntervalSince(lastAnnounced) < self.announceCooldown {
                                continue
                            }

                            self.lastAnnouncedNames[name] = Date()
                            self.onRecognition?(name)
                            print("👤 Recognized: \(name)")

                        case .ambiguous(let contenders):
                            // CO Item 1: too close to call. Say so rather than picking the leader —
                            // and don't touch `lastSeen`, since we don't know whose it is.
                            let names = contenders.map { self.knownFaces[$0.index].name }
                            let key = names.sorted().joined(separator: "|")
                            if let lastAnnounced = self.lastAnnouncedNames[key],
                               Date().timeIntervalSince(lastAnnounced) < self.announceCooldown {
                                continue
                            }
                            self.lastAnnouncedNames[key] = Date()
                            self.onAmbiguousRecognition?(names)
                            print("👤 Ambiguous: \(names.joined(separator: " / "))")

                        case .none:
                            continue
                        }
                    }
                    self.processingFrame = false
                }
            } catch {
                await MainActor.run {
                    self.processingFrame = false
                }
            }
        }
    }

    // MARK: - Vision Framework

    private nonisolated func detectFaceprints(in cgImage: CGImage) async throws -> [[Float]] {
        // Step 1: Detect face rectangles
        let faceRequest = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([faceRequest])

        guard let faceObservations = faceRequest.results, !faceObservations.isEmpty else {
            return []
        }

        // Step 2: Generate face print for each detected face
        // Use VNGenerateFaceObservationsRequest for more detailed face analysis
        var faceprints: [[Float]] = []

        for face in faceObservations.prefix(5) {
            // Create a feature print request scoped to this face's bounding box
            let featurePrintRequest = VNGenerateImageFeaturePrintRequest()

            // Crop to face region
            let faceImage = cropFace(from: cgImage, boundingBox: face.boundingBox)
            guard let croppedCG = faceImage else { continue }

            let faceHandler = VNImageRequestHandler(cgImage: croppedCG, options: [:])
            try faceHandler.perform([featurePrintRequest])

            guard let featurePrint = featurePrintRequest.results?.first else { continue }

            // Extract the feature print data as Float array
            let data = featurePrint.data
            let count = data.count / MemoryLayout<Float>.size
            var floats = [Float](repeating: 0, count: count)
            _ = floats.withUnsafeMutableBytes { data.copyBytes(to: $0) }

            faceprints.append(floats)
        }

        return faceprints
    }

    private nonisolated func cropFace(from cgImage: CGImage, boundingBox: CGRect) -> CGImage? {
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)

        // Vision bounding box is normalized and origin is bottom-left
        let padding: CGFloat = 0.15 // Add padding around face
        let x = max(0, (boundingBox.minX - padding) * width)
        let y = max(0, (1 - boundingBox.maxY - padding) * height)
        let w = min(width - x, (boundingBox.width + padding * 2) * width)
        let h = min(height - y, (boundingBox.height + padding * 2) * height)

        let cropRect = CGRect(x: x, y: y, width: w, height: h)
        return cgImage.cropping(to: cropRect)
    }

    // MARK: - Matching

    private func findMatch(for faceprint: [Float]) -> Int? {
        FaceMatcher.bestMatch(for: faceprint, among: knownFaces.map(\.faceprint), threshold: matchThreshold)
    }

    /// What the wearer hears on a near-tie. Phrased as a real question, for two reasons: it is
    /// honest about the app's state, and it lets the normal conversation loop act on the answer
    /// through the existing face tools. It also has to *read* as a question so CO Item 4 grants the
    /// longer silence window — otherwise the prompt closes before the user can answer it, which
    /// would be a worse experience than the confident wrong guess this replaces.
    nonisolated static func ambiguityPrompt(names: [String]) -> String {
        "That might be \(spokenList(names)) — which one is it?"
    }

    /// "Sam or Alex" / "Sam, Alex or Jo" — spoken aloud, so it needs the conjunction.
    /// `nonisolated` so phrasing is testable without standing up the main-actor service.
    nonisolated static func spokenList(_ names: [String]) -> String {
        guard let last = names.last else { return "" }
        guard names.count > 1 else { return last }
        return names.dropLast().joined(separator: ", ") + " or " + last
    }

    /// CO Item 1: the full outcome, including the near-tie case `findMatch` cannot express.
    func classify(_ faceprint: [Float]) -> FaceMatcher.MatchOutcome {
        FaceMatcher.match(for: faceprint,
                          among: knownFaces.map(\.faceprint),
                          threshold: matchThreshold,
                          margin: Config.faceMatchAmbiguityMargin)
    }

    // MARK: - Persistence

    private func saveFaces() {
        do {
            let data = try JSONEncoder().encode(knownFaces)
            // Face embeddings are biometric data — encrypt at rest (accessible only while unlocked).
            try data.write(to: storageURL, options: [.atomic, .completeFileProtection])
        } catch {
            print("👤 Failed to save faces: \(error)")
        }
    }

    private func loadFaces() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL)
            knownFaces = try JSONDecoder().decode([KnownFace].self, from: data)
            print("👤 Loaded \(knownFaces.count) known faces")
        } catch {
            print("👤 Failed to load faces: \(error)")
        }
    }
}
