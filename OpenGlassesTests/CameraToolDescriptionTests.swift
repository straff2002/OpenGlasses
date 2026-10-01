import XCTest
@testable import OpenGlasses

/// Plan GV P2 — what the model is told about the camera.
///
/// Tool descriptions feed the system prompt (`SystemPromptBuilder`), and a description that says
/// "from the glasses camera" teaches the model to refuse whenever no glasses are connected — which
/// is exactly what the Field Assist tiles ran into. Failure strings come back to the model as tool
/// results and teach the same thing. This scrapes the tool sources the way the frame roster does:
/// an ask-on-phone tool may not claim the camera is the glasses', and every tool that reaches a
/// still must be in `PhoneCapturePolicy`'s table.
final class CameraToolDescriptionTests: XCTestCase {

    private static var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("OpenGlasses/Sources")
    }

    /// Phrases that tie the camera to the glasses. Matched case-insensitively, outside comments.
    private static let glassesOnlyPhrases = [
        "glasses camera", "through the glasses", "point the glasses", "glasses are connected",
        "glasses view", "glasses at the",
    ]

    /// Tools that reach a still through a service rather than calling the accessor themselves.
    private static let serviceBackedCameraTools: [String: String] = [
        "SafetyAssessmentTool.swift": "safety_assessment",
        "VisionAssessTool.swift": "vision_assess",
        "StudyTool.swift": "study",
        "TeleprompterTool.swift": "teleprompter",
        "ParkingTool.swift": "parking",
        "LookCloselyTool.swift": "look_closely",
    ]

    /// Services whose sentences are returned by an ask-on-phone tool, so they are held to the same
    /// wording.
    private static let toolResultServices = [
        "Services/SafetyAssessment/SafetyAssessmentService.swift",
        "Services/StructuredVision/StructuredVisionService.swift",
        "Services/Study/StudyService.swift",
        "Services/Teleprompter/TeleprompterService.swift",
        "Services/Vision/SharpStillCapture.swift",
    ]

    private struct ToolFile {
        let file: String
        let name: String
        let code: [String]   // non-comment lines
    }

    private func toolFiles() throws -> [ToolFile] {
        let dir = Self.sourcesRoot.appendingPathComponent("Services/NativeTools")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".swift") }
        return try names.compactMap { file in
            let lines = try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.hasPrefix("//") && !$0.hasPrefix("*") && !$0.hasPrefix("/*") }
            guard let nameLine = lines.first(where: { $0.hasPrefix("let name = \"") }) else { return nil }
            let name = nameLine.dropFirst("let name = \"".count).prefix { $0 != "\"" }
            return ToolFile(file: file, name: String(name), code: lines)
        }
    }

    private func offendingLines(_ lines: [String]) -> [String] {
        lines.filter { line in
            let lower = line.lowercased()
            return Self.glassesOnlyPhrases.contains { lower.contains($0) }
        }
    }

    func testTheScrapeFindsTheCameraTools() throws {
        let names = Set(try toolFiles().map(\.name))
        for expected in ["capture_photo", "equipment_lookup", "safety_assessment", "scan_document"] {
            XCTAssertTrue(names.contains(expected), "scrape missed \(expected) — the walk is broken")
        }
    }

    func testNoAskOnPhoneToolSaysTheCameraIsTheGlasses() throws {
        var violations: [String] = []
        for tool in try toolFiles() where PhoneCapturePolicy.askOnPhoneTools.contains(tool.name) {
            for line in offendingLines(tool.code) {
                violations.append("\(tool.file) [\(tool.name)]: \(line)")
            }
        }
        XCTAssertTrue(violations.isEmpty, """
            These camera tools tell the model the camera is the glasses', so it refuses without \
            them. Say "the camera" (the glasses when connected, otherwise the phone):
            \(violations.joined(separator: "\n"))
            """)
    }

    func testTheirServicesSayTheSame() throws {
        var violations: [String] = []
        for path in Self.toolResultServices {
            let lines = try String(contentsOf: Self.sourcesRoot.appendingPathComponent(path), encoding: .utf8)
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.hasPrefix("//") && !$0.hasPrefix("*") && !$0.hasPrefix("/*") }
                .filter { $0.contains("\"") }
            violations += offendingLines(lines).map { "\(path): \($0)" }
        }
        XCTAssertTrue(violations.isEmpty, violations.joined(separator: "\n"))
    }

    func testEveryToolThatReachesAStillIsInTheTable() throws {
        var missing: [String] = []
        for tool in try toolFiles() {
            let joined = tool.code.joined(separator: "\n")
            let reachesStill = joined.contains("filteredStill(") || joined.contains("capturePhoto(")
                || Self.serviceBackedCameraTools[tool.file] == tool.name
            if reachesStill, PhoneCapturePolicy.routes[tool.name] == nil {
                missing.append("\(tool.file) [\(tool.name)]")
            }
        }
        XCTAssertTrue(missing.isEmpty, """
            These tools reach a camera still but have no route in PhoneCapturePolicy, so nobody \
            decided what they do without glasses: \(missing.joined(separator: ", "))
            """)
    }

    func testEveryNameInTheTableIsARealTool() throws {
        let names = Set(try toolFiles().map(\.name))
        let unknown = Set(PhoneCapturePolicy.routes.keys).subtracting(names)
        XCTAssertTrue(unknown.isEmpty, "routes for tools that do not exist: \(unknown.sorted())")
    }
}
