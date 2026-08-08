import XCTest
@testable import OpenGlasses

/// Plan CN. `AgentHarness.start` was text-only, so a delegated run only ever saw the on-device
/// model's paraphrase of the scene. These tests pin the policy that decides when a frame rides
/// along, and the two adapter contracts that carry it.
final class AgentAttachmentTests: XCTestCase {

    /// Everything on and a pin held — the case the feature exists for.
    private func decideWithDefaults(settingEnabled: Bool = true,
                                    agentModeEnabled: Bool = true,
                                    hipaaMode: Bool = false,
                                    pinHeld: Bool = true,
                                    pinAge: TimeInterval? = 5,
                                    cameraStreaming: Bool = true,
                                    prompt: String = "file this",
                                    explicitAttach: Bool? = nil) -> AgentAttachmentPolicy.Decision {
        AgentAttachmentPolicy.decide(settingEnabled: settingEnabled,
                                     agentModeEnabled: agentModeEnabled,
                                     hipaaMode: hipaaMode,
                                     pinHeld: pinHeld,
                                     pinAge: pinAge,
                                     cameraStreaming: cameraStreaming,
                                     prompt: prompt,
                                     explicitAttach: explicitAttach)
    }

    private func isAttach(_ decision: AgentAttachmentPolicy.Decision) -> Bool {
        if case .attach = decision { return true }
        return false
    }

    // MARK: - Gates

    /// The consent gate. Agent Mode authorised dispatching text, not shipping camera frames.
    func testDefaultOffMeansNoFrameEvenWithAPinHeld() {
        XCTAssertEqual(decideWithDefaults(settingEnabled: false), .skip(.disabled))
    }

    func testAgentModeOffSkips() {
        XCTAssertEqual(decideWithDefaults(agentModeEnabled: false), .skip(.agentModeOff))
    }

    /// HIPAA hard-disables outbound frames regardless of every other input — the Plan AQ precedent.
    func testHipaaModeHardDisablesRegardlessOfEverythingElse() {
        XCTAssertEqual(decideWithDefaults(hipaaMode: true, explicitAttach: true), .skip(.hipaaMode))
        XCTAssertEqual(decideWithDefaults(hipaaMode: true, prompt: "read this label"), .skip(.hipaaMode))
    }

    // MARK: - Frame selection

    /// Pinning is the aiming gesture, so a held pin beats the live frame.
    func testHeldPinIsPreferredOverLive() {
        guard case .attach(let source) = decideWithDefaults() else { return XCTFail("expected .attach") }
        guard case .pinned = source else { return XCTFail("expected the pinned source, got \(source)") }
    }

    /// A forgotten pin must not silently become the agent's view of "now".
    func testStalePinIsSkippedRatherThanSentAsCurrent() {
        let age = AgentAttachmentPolicy.defaultMaxPinAge + 1
        XCTAssertEqual(decideWithDefaults(pinAge: age), .skip(.pinStale))
    }

    func testPinExactlyAtMaxAgeIsStale() {
        XCTAssertEqual(decideWithDefaults(pinAge: AgentAttachmentPolicy.defaultMaxPinAge), .skip(.pinStale))
    }

    func testNoPinAndNoCameraSkips() {
        XCTAssertEqual(decideWithDefaults(pinHeld: false, cameraStreaming: false), .skip(.noFrame))
    }

    // MARK: - Referential matcher

    func testVisuallyReferentialPromptAttachesTheLiveFrame() {
        guard case .attach(let source) = decideWithDefaults(pinHeld: false, prompt: "read this label for me")
        else { return XCTFail("expected .attach") }
        XCTAssertEqual(source, .live)
    }

    /// "run the tests" needs no photograph.
    func testNonReferentialPromptSkips() {
        XCTAssertEqual(decideWithDefaults(pinHeld: false, prompt: "run the unit tests and push"),
                       .skip(.notReferential))
    }

    /// The matcher is demotable in *both* directions — the model can see what it cannot.
    func testExplicitAttachOverridesTheMatcherBothWays() {
        XCTAssertTrue(isAttach(decideWithDefaults(pinHeld: false,
                                                  prompt: "run the unit tests",
                                                  explicitAttach: true)))
        XCTAssertEqual(decideWithDefaults(prompt: "read this label", explicitAttach: false),
                       .skip(.notReferential))
    }

    func testReferentialMatcherCoversDemonstrativesAndReadVerbs() {
        for prompt in ["what's on the sign", "read the serial", "log this", "transcribe the form",
                       "the receipt in front of me"] {
            XCTAssertTrue(AgentAttachmentPolicy.isVisuallyReferential(prompt), prompt)
        }
        for prompt in ["deploy the branch", "summarise my inbox", "what's the weather"] {
            XCTAssertFalse(AgentAttachmentPolicy.isVisuallyReferential(prompt), prompt)
        }
    }

    // MARK: - Provenance

    /// A receiving agent cannot otherwise tell a current scene from a stock reference.
    func testProvenanceDistinguishesPinnedFromLive() {
        let live = AgentAttachmentPhrasing.provenance(for: .live)
        XCTAssertTrue(live.lowercased().contains("just now"), live)

        let now = Date()
        let pinned = AgentAttachmentPhrasing.provenance(for: .pinned(at: now.addingTimeInterval(-30)), now: now)
        XCTAssertTrue(pinned.contains("30 seconds ago"), pinned)
        XCTAssertTrue(pinned.contains("froze"), "a pin is a deliberate act and should read as one")
    }

    func testPromptCarriesProvenanceOnlyWhenSomethingIsAttached() {
        let bare = AgentAttachmentPhrasing.prompt("file this", attaching: nil)
        XCTAssertEqual(bare, "file this")

        let withImage = AgentAttachmentPhrasing.prompt("file this", attaching: .live)
        XCTAssertTrue(withImage.hasPrefix("file this"))
        XCTAssertGreaterThan(withImage.count, bare.count)
    }

    // MARK: - Adapter contracts

    /// An arbitrary user endpoint must not receive surprise multi-megabyte bodies: attaching is
    /// opt-in by *naming the field*, and the default name is empty.
    func testCustomHarnessOmitsTheImageUntilAFieldIsNamed() throws {
        var config = CustomHarnessConfig()
        config.startURL = "https://example.test/run"
        XCTAssertEqual(config.imageField, "", "attaching must be opt-in for a custom endpoint")

        let attachment = AgentTaskAttachment(jpeg: Data([0xFF, 0xD8, 0xFF]), source: .live,
                                             pixelSize: CGSize(width: 4, height: 4))

        let unnamed = try XCTUnwrap(config.startRequest(prompt: "p", project: nil, attachment: attachment))
        let unnamedBody = try JSONSerialization.jsonObject(with: XCTUnwrap(unnamed.httpBody)) as? [String: Any]
        XCTAssertNil(unnamedBody?["image"], "no image field named ⇒ no image sent")
        XCTAssertEqual(unnamed.timeoutInterval, 30, "a text-only body keeps the original timeout")

        config.imageField = "image"
        let named = try XCTUnwrap(config.startRequest(prompt: "p", project: nil, attachment: attachment))
        let namedBody = try JSONSerialization.jsonObject(with: XCTUnwrap(named.httpBody)) as? [String: Any]
        XCTAssertEqual(namedBody?["image"] as? String, attachment.jpeg.base64EncodedString())
        XCTAssertGreaterThan(named.timeoutInterval, 30,
                             "megabytes of base64 on cellular do not fit in the text-only timeout")
    }

    /// A named field with nothing to attach must not put a null or an empty string in the body.
    func testNamedFieldWithNoAttachmentSendsNoImageKey() throws {
        var config = CustomHarnessConfig()
        config.startURL = "https://example.test/run"
        config.imageField = "image"

        let request = try XCTUnwrap(config.startRequest(prompt: "p", project: nil, attachment: nil))
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
        XCTAssertNil(body?["image"])
        XCTAssertEqual(request.timeoutInterval, 30)
    }

    /// Every skip reason must be reachable, or the table is lying about what it models.
    func testEverySkipReasonHasARaw() {
        XCTAssertEqual(Set(AgentAttachmentPolicy.Reason.allCases.map(\.rawValue)).count,
                       AgentAttachmentPolicy.Reason.allCases.count)
    }
}
