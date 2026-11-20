import XCTest
@testable import OpenGlasses

/// Shared fixtures for Plan MN's tests: the plan's own pH step, the bottling-line example vault,
/// and a session logger in a temporary folder.
enum ProcedureAnswerFixtures {

    /// The repository root, from this source file.
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    static var exampleVault: URL {
        repoRoot.appendingPathComponent("examples/vaults/bottling-line-check", isDirectory: true)
    }

    static func exampleProcedure() throws -> Procedure {
        let url = exampleVault.appendingPathComponent("procedures/start_of_shift_check.json")
        return try JSONDecoder().decode(Procedure.self, from: Data(contentsOf: url))
    }

    /// Every procedure JSON the repository ships: bundled vaults and examples.
    static func allShippedProcedureFiles() throws -> [URL] {
        let fm = FileManager.default
        var roots: [URL] = []
        let bundled = repoRoot.appendingPathComponent("OpenGlasses/Sources/Resources/Vaults", isDirectory: true)
        let examples = repoRoot.appendingPathComponent("examples/vaults", isDirectory: true)
        for base in [bundled, examples] {
            for vault in (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? [] {
                roots.append(vault.appendingPathComponent("procedures", isDirectory: true))
            }
        }
        return roots.flatMap { dir in
            ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "json" }
        }.sorted { $0.path < $1.path }
    }

    static let phAnswer = StepAnswer(recordAs: "ph", kind: .number, label: "pH", critical: true,
                                     decimals: 2, plausible: [0, 14], spec: [3.8, 4.4])

    /// The plan's §1 example: check_ph decides in_spec / high / low by rule.
    static func phProcedure(defaultNext: String? = nil, branches: [Procedure.Branch]? = nil) -> Procedure {
        let rules = branches ?? [
            .init(id: "in_spec", condition: "pH 3.8 to 4.4", next: "record_brix",
                  when: .test(.init(answer: "ph", op: .between, operand: .pair(3.8, 4.4)))),
            .init(id: "high", condition: "pH above 4.4", next: "adjust_acid",
                  when: .test(.init(answer: "ph", op: .gt, operand: .number(4.4)))),
            .init(id: "low", condition: "pH below 3.8", next: "hold_batch",
                  when: .test(.init(answer: "ph", op: .lt, operand: .number(3.8)))),
        ]
        return Procedure(id: "ph_check", title: "pH check", version: "2.1.0", steps: [
            .init(id: "check_ph", title: "Check the pH", instruction: "Read the pH meter.",
                  branches: rules, defaultNext: defaultNext, answer: phAnswer),
            .init(id: "record_brix", title: "Record the Brix", instruction: "Read the refractometer.",
                  defaultNext: "done"),
            .init(id: "adjust_acid", title: "Adjust acid", instruction: "Add acid and retest.", defaultNext: "check_ph"),
            .init(id: "hold_batch", title: "Hold the batch", instruction: "Hold it.", terminal: true, outcome: "escalated"),
            .init(id: "done", title: "Done", instruction: "Release.", terminal: true, outcome: "resolved"),
        ])
    }

    static func number(_ text: String, _ answer: StepAnswer = phAnswer) -> KnownAnswer {
        guard case .accepted(let value) = AnswerReader.read(text, for: answer, locale: Locale(identifier: "en_US")) else {
            preconditionFailure("fixture value \(text) does not read")
        }
        return KnownAnswer(answer: answer, value: value)
    }

    static func test(_ answer: String, _ op: BranchRule.Op, _ operand: BranchRule.Operand) -> BranchRule {
        .test(.init(answer: answer, op: op, operand: operand))
    }

    @MainActor
    static func makeLogger(root: URL) -> SessionLogger {
        let session = FieldSession(
            id: UUID().uuidString, vaultId: "refrigeration", assetId: nil, mode: .aiOnly,
            startedAt: Date(), endedAt: nil, pausedAt: nil, resumedAt: nil, outcome: .inProgress,
            startLocation: nil, endLocation: nil, escalations: [], billableSeconds: 0
        )
        return SessionLogger(session: session, root: root.appendingPathComponent(session.id, isDirectory: true))
    }

    static func temporaryRoot(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
