import XCTest
@testable import OpenGlasses

/// The parts of OGDesign's VoiceOver behaviour that are plain functions —
/// what a chip, a pill and the hero card actually say. The rest of the
/// semantics (traits, grouping, hidden decoration) only exist in a running UI
/// and belong to the accessibility-audit UI target, not here.
final class OGDesignAccessibilityTests: XCTestCase {

    // MARK: - Chips

    func testAvailableChipReadsAsItsLabel() {
        XCTAssertEqual(OGChip.spokenLabel(text: "Camera", available: true), "Camera")
    }

    /// On screen the difference is a grey fill; in words it has to be said.
    func testUnavailableChipSaysSo() {
        XCTAssertEqual(
            OGChip.spokenLabel(text: "Display", available: false),
            "Display, unavailable"
        )
    }

    // MARK: - Saved-model rows

    /// Vision used to be an `eye` glyph beside the provider name. A row that
    /// supports images has to say so in both the visible line and the spoken one.
    func testModelRowSaysVisionInWords() {
        XCTAssertEqual(
            ModelRowSummary.subtitle(provider: "Anthropic", modelId: "claude-sonnet-4", visionEnabled: true),
            "Anthropic · claude-sonnet-4 · Vision"
        )
        XCTAssertEqual(
            ModelRowSummary.subtitle(provider: "Groq", modelId: "llama-3.3-70b", visionEnabled: false),
            "Groq · llama-3.3-70b"
        )
    }

    /// Identity, then capability, then whether this is the model in use — and
    /// the active state is a word, not just a tick.
    func testModelRowSpokenLabelOrdersIdentityThenCapabilityThenState() {
        XCTAssertEqual(
            ModelRowSummary.spoken(name: "Claude Sonnet", provider: "Anthropic",
                                   visionEnabled: true, isActive: true),
            "Claude Sonnet, Anthropic, vision enabled, active"
        )
    }

    func testModelRowSpokenLabelOmitsWhatIsNotTrue() {
        XCTAssertEqual(
            ModelRowSummary.spoken(name: "GPT-4o mini", provider: "OpenAI",
                                   visionEnabled: false, isActive: false),
            "GPT-4o mini, OpenAI"
        )
    }

    // MARK: - Status pills

    func testStatusPillTurnsItsSeparatorIntoAPause() {
        XCTAssertEqual(OGStatusPill.spokenLabel("Glasses · 82%"), "Glasses, 82%")
    }

    func testStatusPillLeavesTextWithoutASeparatorAlone() {
        XCTAssertEqual(OGStatusPill.spokenLabel("Connected"), "Connected")
    }

    // MARK: - Hero device card

    func testHeroSummaryReadsIdentityThenStateThenPower() {
        let summary = OGHeroDeviceCard.spokenSummary(
            title: "Ray-Ban Meta",
            status: "Connected",
            batteryPercent: 82,
            chips: []
        )
        XCTAssertEqual(summary, "Ray-Ban Meta. Connected. Battery 82 percent")
    }

    func testHeroSummaryOmitsBatteryUntilTheDeviceReportsIt() {
        let summary = OGHeroDeviceCard.spokenSummary(
            title: "Ray-Ban Meta",
            status: "Connecting",
            batteryPercent: nil,
            chips: []
        )
        XCTAssertEqual(summary, "Ray-Ban Meta. Connecting")
        XCTAssertFalse(summary.contains("Battery"))
    }

    func testHeroSummaryGroupsChipsByAvailability() {
        let summary = OGHeroDeviceCard.spokenSummary(
            title: "Ray-Ban Meta",
            status: "Connected",
            batteryPercent: 40,
            chips: [(label: "Camera", available: true),
                    (label: "Display", available: false),
                    (label: "Microphone", available: true)]
        )
        XCTAssertEqual(
            summary,
            "Ray-Ban Meta. Connected. Battery 40 percent. "
                + "Available: Camera, Microphone. Unavailable: Display"
        )
    }

    func testHeroSummarySkipsAnEmptyAvailabilityGroup() {
        let allOn = OGHeroDeviceCard.spokenSummary(
            title: "Glasses", status: "Connected", batteryPercent: nil,
            chips: [(label: "Camera", available: true)]
        )
        XCTAssertEqual(allOn, "Glasses. Connected. Available: Camera")
        XCTAssertFalse(allOn.contains("Unavailable"))
    }

    // MARK: - Reduce Motion

    /// Reduce Motion holds the ambience steady: every state gives the same
    /// radiance, so nothing breathes behind the conversation.
    func testAmbienceHoldsSteadyUnderReduceMotion() {
        let levels = Set(
            [VoiceVisualState.idle, .listening, .thinking, .speaking]
                .map { VoiceAmbience.glow(for: $0, reduceMotion: true) }
        )
        XCTAssertEqual(levels.count, 1)
    }

    func testAmbienceStillBreathesWhenMotionIsAllowed() {
        XCTAssertNotEqual(
            VoiceAmbience.glow(for: .idle, reduceMotion: false),
            VoiceAmbience.glow(for: .speaking, reduceMotion: false)
        )
    }

    /// The still frame has to be a moment where the strands are apart, or the
    /// fallback reads as one thick line instead of a ribbon.
    func testWavelineStillFrameSeparatesTheStrands() {
        let amplitudes = WavelineParams.params(for: .speaking)
        let displacements = [2.1, 4.4, 1.1, 0.0].map {
            WavelineParams.displacement(
                phase: 0.5, time: VoiceWaveline.stillTime,
                amplitudes: amplitudes, phaseShift: $0
            )
        }
        let spread = (displacements.max() ?? 0) - (displacements.min() ?? 0)
        XCTAssertGreaterThan(spread, 0.2, "the still frame stacks the strands")
    }
}
