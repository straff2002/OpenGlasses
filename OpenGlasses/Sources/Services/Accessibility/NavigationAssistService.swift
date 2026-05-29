import Foundation
import UIKit

/// Low-Vision Navigation Assist (Plan J): an Assistive-Mode variant tuned for mobility. Periodically
/// captures the glasses view, asks the LLM for movement-relevant hazards/landmarks in clock-position
/// phrasing, and speaks them — escalating urgency for immediate hazards (A2). Reuses `AssistiveAdvice`
/// + `LLMService.analyzeFrame`. Deps are configured by AppState; a tool starts/stops it.
///
/// This is an assistive aid, NOT a primary mobility device — surfaced in the activation disclaimer.
@MainActor
final class NavigationAssistService: ObservableObject {
    static let shared = NavigationAssistService()

    @Published private(set) var isActive = false
    @Published private(set) var lastAdvice: AssistiveAdvice?

    /// Faster than A3 scene mode — mobility hazards are time-sensitive.
    var interval: TimeInterval = 2.5

    private weak var camera: CameraService?
    private weak var llm: LLMService?
    private weak var tts: TextToSpeechService?

    private var timer: Timer?
    private var analyzing = false

    private init() {}

    func configure(camera: CameraService, llm: LLMService, tts: TextToSpeechService) {
        self.camera = camera
        self.llm = llm
        self.tts = tts
    }

    var isConfigured: Bool { camera != nil && llm != nil && tts != nil }

    static let systemPrompt = """
    You are a mobility aid for a low-vision user who is walking. Report ONLY movement-relevant \
    hazards and landmarks: steps, drop-offs, curbs, doors, obstacles, oncoming people or vehicles. \
    Use clock positions and rough distance (e.g. "step down, two o'clock, about one meter"). One \
    sentence, at most 15 words. Respond ONLY in valid JSON: \
    {"advice": string, "urgency": "low"|"medium"|"high", "followup": string optional}. \
    urgency: low = clear path, medium = obstacle to navigate, high = immediate hazard (drop-off, \
    vehicle, collision). If the view is unclear, set advice to "view unclear" with urgency low. \
    No markdown.
    """

    // MARK: - Lifecycle

    @discardableResult
    func start() -> Bool {
        guard isConfigured else { return false }
        guard !isActive else { return true }
        isActive = true
        lastAdvice = nil
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        NSLog("[NavAssist] Started")
        return true
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        timer?.invalidate()
        timer = nil
        NSLog("[NavAssist] Stopped")
    }

    // MARK: - Loop

    private func tick() async {
        guard isActive, !analyzing, let camera, let llm, let tts else { return }
        if tts.isSpeaking { return }

        analyzing = true
        defer { analyzing = false }

        guard let frame = camera.latestFrame, let cg = frame.cgImage else { return }
        // Skip dark/flat frames to save tokens and avoid confident wrong calls.
        guard Self.isFrameUsable(cg) else { return }
        guard let data = frame.jpegData(compressionQuality: 0.7) else { return }

        guard let raw = await llm.analyzeFrame(systemPrompt: Self.systemPrompt,
                                               userText: "What hazards or landmarks should I know about right now?",
                                               imageData: data, maxTokens: 80),
              let advice = AssistiveAdvice.parse(raw) else { return }
        guard isActive else { return }

        // Skip "view unclear" low-priority noise and near-duplicates of the last spoken advice.
        if advice.advice.lowercased().contains("view unclear") && advice.urgency == .low { return }
        if let last = lastAdvice, Self.isSimilar(advice.advice, last.advice) { return }

        lastAdvice = advice
        await tts.speak(advice.advice, urgency: advice.urgency.speechUrgency)
    }

    // MARK: - Frame quality (pure, testable)

    /// A frame is usable if it isn't too dark and isn't near-uniform (flat/blurred). Samples an
    /// 8×8 grayscale downscale and checks mean luminance + variance.
    static func isFrameUsable(_ cgImage: CGImage, minMean: Double = 0.06, minVariance: Double = 0.0008) -> Bool {
        let size = 8
        var pixels = [UInt8](repeating: 0, count: size * size)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: &pixels, width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: size, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return true }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))

        let values = pixels.map { Double($0) / 255.0 }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return mean >= minMean && variance >= minVariance
    }

    /// Token-overlap similarity to suppress repeating the same callout.
    static func isSimilar(_ a: String, _ b: String, threshold: Double = 0.6) -> Bool {
        let setA = Set(a.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }))
        let setB = Set(b.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }))
        guard !setA.isEmpty, !setB.isEmpty else { return a == b }
        return Double(setA.intersection(setB).count) / Double(setA.union(setB).count) >= threshold
    }
}
