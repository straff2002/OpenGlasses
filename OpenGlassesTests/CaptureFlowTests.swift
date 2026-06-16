import XCTest
@testable import OpenGlasses

/// Tests for the structured capture-flow schema (Plan U): the `CaptureFlow` JSON model, the
/// deterministic `CaptureFlowRunner` (validation + advance/back/skip/finish), `FieldResolver`
/// cross-pack binding, and `CaptureRecord` round-tripping. Headless — no vault/mic/camera.
@MainActor
final class CaptureFlowTests: XCTestCase {

    private func sampleFlow() -> CaptureFlow {
        CaptureFlow(id: "asset_inspection_v1", title: "Asset Inspection",
                    appliesTo: ["refrigeration", "it_network"], steps: [
            FlowStep(field: "asset_id", prompt: "Scan or say the code.",
                     binding: FieldBinding(type: .barcodeOrVoice), required: true),
            FlowStep(field: "gauge_psi", prompt: "Read the suction gauge.",
                     binding: FieldBinding(type: .voiceNumber, unit: "psig"),
                     completion: Completion(minLen: nil, range: [0, 600])),
            FlowStep(field: "severity", prompt: "Severity?",
                     binding: FieldBinding(type: .enumChoice, options: ["minor", "major", "critical"])),
            FlowStep(field: "photo", prompt: "Show the nameplate.",
                     binding: FieldBinding(type: .photo), required: true),
        ])
    }

    // MARK: - Schema decode

    func testDecodeFlowFromPlanJSON() throws {
        let json = """
        {
          "id": "asset_inspection_v1", "title": "Asset Inspection",
          "applies_to": ["refrigeration", "electrical"],
          "steps": [
            { "field": "asset_id", "prompt": "Scan the asset barcode or say the code.",
              "binding": { "type": "barcode_or_voice" }, "required": true },
            { "field": "gauge_psi", "prompt": "Read the suction gauge.",
              "binding": { "type": "voice_number", "unit": "psig" }, "completion": { "range": [0, 600] } },
            { "field": "severity", "prompt": "Severity?",
              "binding": { "type": "enum", "options": ["minor","major","critical"] } }
          ],
          "preconditions": [ { "type": "inside_region", "region": "site_boundary", "message": "You're outside the work zone." } ]
        }
        """
        let flow = try XCTUnwrap(CaptureFlowLibrary.decode(Data(json.utf8)))
        XCTAssertEqual(flow.id, "asset_inspection_v1")
        XCTAssertEqual(flow.appliesTo, ["refrigeration", "electrical"])
        XCTAssertEqual(flow.steps.map(\.binding.type), [.barcodeOrVoice, .voiceNumber, .enumChoice])
        XCTAssertTrue(flow.steps[0].required)
        XCTAssertFalse(flow.steps[1].required)              // defaulted
        XCTAssertEqual(flow.steps[1].binding.unit, "psig")
        XCTAssertEqual(flow.steps[1].completion?.range, [0, 600])
        XCTAssertEqual(flow.steps[2].binding.options, ["minor", "major", "critical"])
        XCTAssertEqual(flow.preconditions.first?.region, "site_boundary")
    }

    func testDecodeRejectsMalformed() {
        XCTAssertNil(CaptureFlowLibrary.decode(Data("not json".utf8)))
        XCTAssertNil(CaptureFlowLibrary.decode(Data(#"{"id":"x"}"#.utf8)))   // missing title/steps
    }

    // MARK: - Runner happy path

    func testRunnerCapturesTypedRecord() {
        let r = CaptureFlowRunner(flow: sampleFlow(), sessionId: "sess")
        XCTAssertEqual(r.prompt(), "Step 1 of 4: Scan or say the code.")

        XCTAssertEqual(r.answer("47B"), .accepted(next: "Step 2 of 4: Read the suction gauge."))
        XCTAssertEqual(r.answer("about 118 psi"), .accepted(next: "Step 3 of 4: Severity?"))
        XCTAssertEqual(r.answer("major"), .accepted(next: "Step 4 of 4: Show the nameplate."))
        XCTAssertEqual(r.answer("/tmp/nameplate.jpg"), .finished)

        guard case .completed(let record) = r.finish() else { return XCTFail("expected completion") }
        XCTAssertEqual(record.value(for: "asset_id"), .code("47B"))
        XCTAssertEqual(record.value(for: "gauge_psi"), .number(118, unit: "psig"))
        XCTAssertEqual(record.value(for: "severity"), .option("major"))
        XCTAssertEqual(record.value(for: "photo")?.kind, "photo")
        XCTAssertNotNil(record.finishedAt)
    }

    // MARK: - Validation + re-prompt

    func testVoiceNumberRangeAndParseRejects() {
        let r = CaptureFlowRunner(flow: sampleFlow(), sessionId: "s")
        _ = r.answer("47B")                                  // advance to gauge step
        if case .rejected = r.answer("nine hundred and ninety") { /* no digits → reject */ }
        else { XCTFail("non-numeric should reject") }
        if case .rejected(let reason) = r.answer("999") { XCTAssertTrue(reason.contains("range")) }
        else { XCTFail("out-of-range should reject") }
        XCTAssertEqual(r.answer("118"), .accepted(next: "Step 3 of 4: Severity?"))  // recovers
    }

    func testEnumRejectsUnknownPhrase() {
        let r = CaptureFlowRunner(flow: sampleFlow(), sessionId: "s")
        _ = r.answer("47B"); _ = r.answer("118")
        if case .rejected = r.answer("enormous") {} else { XCTFail("unknown enum should reject") }
        XCTAssertEqual(r.answer("it's major"), .accepted(next: "Step 4 of 4: Show the nameplate."))  // phrase maps
    }

    func testFinishBlocksOnMissingRequired() {
        let r = CaptureFlowRunner(flow: sampleFlow(), sessionId: "s")
        _ = r.skip()                                          // skip required asset_id
        _ = r.answer("118"); _ = r.answer("minor"); _ = r.answer("/tmp/p.jpg")
        guard case .missingRequired(let missing) = r.finish() else { return XCTFail("should block") }
        XCTAssertEqual(missing, ["asset_id"])
    }

    func testBackRevisitsAndOverwrites() {
        let r = CaptureFlowRunner(flow: sampleFlow(), sessionId: "s")
        _ = r.answer("47B"); _ = r.answer("100")
        _ = r.back()                                          // back to gauge step
        XCTAssertEqual(r.prompt(), "Step 2 of 4: Read the suction gauge.")
        _ = r.answer("200")
        XCTAssertEqual(r.record.value(for: "gauge_psi"), .number(200, unit: "psig"))
    }

    // MARK: - Preconditions

    func testPreconditionUnmetOnlyWhenDefinitelyOutside() {
        let flow = CaptureFlow(id: "f", title: "F", steps: [
            FlowStep(field: "x", prompt: "p", binding: FieldBinding(type: .voice))
        ], preconditions: [FlowPrecondition(type: "inside_region", region: "zone", message: "Outside.")])

        let outside = CaptureFlowRunner(flow: flow, sessionId: "s", insideRegion: { _ in false })
        XCTAssertEqual(outside.unmetPreconditions().count, 1)
        let unknown = CaptureFlowRunner(flow: flow, sessionId: "s", insideRegion: { _ in nil })
        XCTAssertTrue(unknown.unmetPreconditions().isEmpty)   // unknown GPS never hard-blocks
        let inside = CaptureFlowRunner(flow: flow, sessionId: "s", insideRegion: { _ in true })
        XCTAssertTrue(inside.unmetPreconditions().isEmpty)
    }

    // MARK: - Static helpers

    func testParseNumberAndResolveOption() {
        XCTAssertEqual(CaptureFlowRunner.parseNumber("about 118 psi"), 118)
        XCTAssertEqual(CaptureFlowRunner.parseNumber("-4.5"), -4.5)
        XCTAssertNil(CaptureFlowRunner.parseNumber("no digits here"))
        XCTAssertEqual(CaptureFlowRunner.resolveOption("major", options: ["minor", "major"]), "major")
        XCTAssertEqual(CaptureFlowRunner.resolveOption("it's critical actually", options: ["minor", "critical"]), "critical")
        XCTAssertNil(CaptureFlowRunner.resolveOption("huge", options: ["minor", "major"]))
    }

    // MARK: - FieldResolver

    func testFieldResolverCrossPack() {
        let flow = sampleFlow()   // appliesTo refrigeration, it_network
        XCTAssertEqual(FieldResolver.resolve(flow, vaultId: "refrigeration", knownFields: []), .runnable)
        XCTAssertEqual(FieldResolver.resolve(flow, vaultId: "electrical", knownFields: []),
                       .notApplicable(vault: "electrical"))
        // Applies, but the vault lacks a bound field.
        let known: Set<String> = ["asset_id", "gauge_psi", "severity"]   // missing "photo"
        XCTAssertEqual(FieldResolver.resolve(flow, vaultId: "it_network", knownFields: known),
                       .missingFields(["photo"]))
        // No appliesTo constraint → universal.
        let universal = CaptureFlow(id: "u", title: "U", steps: flow.steps)
        XCTAssertTrue(FieldResolver.canRun(universal, vaultId: "anything"))
    }

    // MARK: - CaptureRecord round-trip

    func testCaptureRecordRoundTrips() throws {
        var record = CaptureRecord(flowId: "f", sessionId: "s", assetId: "47B", startedAt: Date(timeIntervalSince1970: 1))
        record.set("gauge", value: .number(118, unit: "psig"), provenance: Provenance(method: "voice_number", at: Date(timeIntervalSince1970: 2)))
        record.set("sev", value: .option("major"), provenance: Provenance(method: "enum", at: Date(timeIntervalSince1970: 3)))
        record.finishedAt = Date(timeIntervalSince1970: 4)

        let data = try JSONEncoder().encode(record)
        let back = try JSONDecoder().decode(CaptureRecord.self, from: data)
        XCTAssertEqual(back, record)
        XCTAssertEqual(back.value(for: "gauge"), .number(118, unit: "psig"))
    }
}
