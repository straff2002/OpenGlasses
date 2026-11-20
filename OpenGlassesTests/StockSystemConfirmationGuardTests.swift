import XCTest
@testable import OpenGlasses

/// Plan MM P4, Decision 5 — no agent path may send a staged batch, Agent Mode included. A batch
/// is confirmed in two places only: the close-of-job question the app itself asks and hears
/// (`GuidedJobFlow`), and the parts step a person taps (`StockSystemPartsSendSheet`). The tool and
/// agent layers can note and list parts and have no action that confirms or sends.
final class StockSystemConfirmationGuardTests: XCTestCase {

    private var repo: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func swiftFiles(under path: String) -> [URL] {
        let root = repo.appendingPathComponent(path)
        return (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "swift" }
    }

    /// The only files that may make a person's confirmation.
    private let confirmers: Set<String> = ["GuidedJobFlow.swift", "StockSystemPartsSendSheet.swift"]

    func testAPersonsConfirmationIsMadeInTwoPlacesOnly() throws {
        var makers: Set<String> = []
        for file in swiftFiles(under: "OpenGlasses/Sources") {
            let text = try String(contentsOf: file, encoding: .utf8)
            if text.contains(".person(.voice)") || text.contains(".person(.screen)")
                || text.contains("StockUseConfirmation.person(") {
                makers.insert(file.lastPathComponent)
            }
        }
        XCTAssertEqual(makers, confirmers, "a confirmation made anywhere else could be an unattended send")
    }

    func testTheVoiceConfirmationIsTheAppsOwnQuestionAnsweredByThePerson() throws {
        let flow = try String(contentsOf: repo.appendingPathComponent(
            "OpenGlasses/Sources/Services/FieldAssist/Job/GuidedJobFlow.swift"), encoding: .utf8)
        // The only voice yes is the one the flow hears for its own parts question.
        let lines = flow.components(separatedBy: "\n").filter { $0.contains(".person(.voice)") }
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines.first?.contains("seams.answerParts(pending.sessionID, yes ? .person(.voice) : nil)") == true)
        XCTAssertTrue(flow.contains("RemoteActionVoiceConsent.interpret(text)"), "a plain yes or no, read by the app")
        let sheet = try String(contentsOf: repo.appendingPathComponent(
            "OpenGlasses/Sources/App/Views/Job/StockSystemPartsSendSheet.swift"), encoding: .utf8)
        let code = sheet.components(separatedBy: "\n").filter {
            !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") && $0.contains(".person(.screen)")
        }
        XCTAssertEqual(code.count, 1, "one Send button")
        XCTAssertTrue(code.first?.contains("parts.confirm(scope, by: .person(.screen)") == true)
    }

    func testNoToolOrAgentSurfaceCanConfirmOrSend() throws {
        let surfaces = ["OpenGlasses/Sources/Services/NativeTools", "OpenGlasses/Sources/Services/Agent",
                        "OpenGlasses/Sources/Services/AgentHarness", "OpenGlasses/Sources/Services/AppleIntelligence",
                        "OpenGlasses/Sources/Services/Gateway", "OpenGlasses/Sources/Services/HermesBridge",
                        "OpenGlasses/Sources/App/Intents"]
        var files: [URL] = []
        for surface in surfaces { files += swiftFiles(under: surface) }
        files += ["AgentScheduler.swift", "AgentNotificationQueue.swift", "AgentDataExporter.swift"]
            .map { repo.appendingPathComponent("OpenGlasses/Sources/Services/\($0)") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        XCTAssertTrue(files.contains { $0.lastPathComponent == "VanStockTool.swift" }, "the tool is scanned")
        XCTAssertGreaterThan(files.count, 20)
        let forbidden = ["StockUseConfirmation", "ConfirmedStockUseBatch", "StockSystemPartsUsed", "stockParts",
                         "StockSystemSyncSink", "stockSystemSink", ".stockSystemParts", "answerParts(", "answerParts:",
                         "partsUsed", "confirm(.job", "confirm(.day", "PartsUsedWritePlan(", "setDelivery("]
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for name in forbidden {
                XCTAssertFalse(text.contains(name), "\(file.lastPathComponent) reaches \(name)")
            }
        }
    }

    @MainActor
    func testTheToolsActionsNeverIncludeASendOrAConfirm() {
        for kind in StockPlace.Kind.allCases {
            for system in [nil, "Sample System"] as [String?] {
                let schema = VanStockTool.parametersSchema(for: kind, system: system)
                let properties = schema["properties"] as? [String: Any]
                let actions = (properties?["action"] as? [String: Any])?["enum"] as? [String] ?? []
                XCTAssertFalse(actions.isEmpty)
                for action in actions {
                    XCTAssertFalse(action.contains("confirm") || action == "send" || action.hasPrefix("send_parts"),
                                   "\(action) for \(kind)")
                }
                XCTAssertFalse(VanStockTool.description(for: kind, system: system).contains("'confirm'"))
            }
        }
        // `send_to_base` is the phone list's handover to base, never a send to the system: under a
        // system it is answered with the sentence that the system already has it.
        XCTAssertTrue(VanStockTool.actions.contains("send_to_base"))
    }
}
