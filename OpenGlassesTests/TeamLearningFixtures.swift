import Foundation
import XCTest
@testable import OpenGlasses

/// Shared fixtures for the Plan FP P2 test classes: candidates, entries, model indexes and a
/// custom vault with models, a safety file and one text manual. Fresh instances only — nothing
/// here touches a `.shared` store, the glasses or a camera.
@MainActor
enum TeamLearningFixtures {

    static let model090 = "SLP99UH090XV60CK"
    static let model070 = "SLP99UH070XV36B"
    static let vaultId = "fp_learning_test"

    /// A model core naming two machines, the way the vault guide writes them.
    static let modelsCore = """
    # Models

    ## \(model090) (090XV60C)

    The 90,000 BTU unit.

    ## \(model070) (070XV36B)

    The 70,000 BTU unit.
    """

    static let safetyCore = """
    # Safety

    ## Electrical safety — Lockout/Tagout

    Lock out power before opening any panel.

    ## Flame rollout and lockouts

    Never reset a rollout switch more than once.
    """

    static let manualText = """
    RTU-500 SERVICE MANUAL

    1 FAULT CODES
    Fault code ZX9 indicates a low refrigerant charge on the RTU-500. Check the liquid line sight glass and verify subcooling before adding charge.
    Fault code ZX3 indicates a condenser fan failure. Inspect the fan motor capacitor and the fan relay.

    2 PRESSURE SWITCH
    The high-pressure switch opens at 610 psig and resets automatically at 420 psig. Replace the switch if it does not reset.
    """

    static func modelIndex(_ files: [(String, String)] = [("models.md", modelsCore)]) -> VaultModelIndex {
        VaultModelIndex(vaultName: "Test", files: files.map { (filename: $0.0, contents: $0.1) })
    }

    static func candidate(id: String = LearningCandidate.newID(), session: String = "job-1",
                          vault: String = vaultId, model: String? = model090, spokenModel: String? = nil,
                          finding: String = "The pressure switch tubing sweats and reads open on a cold start",
                          symptom: String? = "Fails on the first call for heat",
                          fix: String? = "Re-route the tubing away from the inducer",
                          author: String = "Sam Tane", status: LearningCandidate.Status = .filed) -> LearningCandidate {
        LearningCandidate(id: id, status: status, sessionId: session, jobReference: "WO-1", taskId: nil,
                          vaultId: vault,
                          equipment: model.map { .init(modelToken: $0, heading: $0, source: "spoken") },
                          spokenModel: spokenModel, finding: finding, symptom: symptom, fix: fix,
                          evidence: .init(pagesVerified: ["Manual, page 3"]), author: author,
                          createdAt: Date(timeIntervalSince1970: 1_800_000_000), redactions: [])
    }

    static func entry(id: String = LearningCandidate.newID(),
                      subject: LearningEntry.Subject = .model(modelToken: model090),
                      vaultIDs: [String] = [vaultId],
                      finding: String = "The pressure switch tubing sweats and reads open on a cold start",
                      fix: String? = "Re-route the tubing",
                      approvedAt: Date = Date(timeIntervalSince1970: 1_791_590_400), // 2026-10-10T00:00:00Z
                      role: String = "Service manager", jobs: [String] = ["job-1"],
                      count: Int? = 1) -> LearningEntry {
        LearningEntry(id: id, subject: subject, vaultIDs: vaultIDs, finding: finding, fix: fix,
                      approvedAt: approvedAt, approvedByRole: role, approvedByName: "Ari Reviewer",
                      candidateID: nil, sourceJobIDs: jobs, confirmedJobCount: count)
    }

    static func tempDirectory(_ label: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func documentStore(in root: URL) -> DocumentStore {
        let dir = root.appendingPathComponent("docs-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return DocumentStore(directory: dir)
    }

    /// A custom vault folder: the model core, the safety core and one text manual.
    static func writeVault(in root: URL, id: String = vaultId) -> URL {
        let dir = root.appendingPathComponent("vault-\(id)-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("documents", isDirectory: true),
                                                 withIntermediateDirectories: true)
        let manifest = VaultManifest(id: id, name: "Learning Test", version: "1.0.0",
                                     files: ["safety.md", "models.md"], proceduresDir: nil,
                                     documentsDir: "documents",
                                     documents: [VaultDocument(file: "manual.txt", title: "Test Manual", kind: "service_manual")],
                                     gating: .init(iap: "enterprise"),
                                     promptRules: ["Never fabricate.", "Cite the source."])
        try? JSONEncoder().encode(manifest).write(to: dir.appendingPathComponent("manifest.json"))
        try? safetyCore.write(to: dir.appendingPathComponent("safety.md"), atomically: true, encoding: .utf8)
        try? modelsCore.write(to: dir.appendingPathComponent("models.md"), atomically: true, encoding: .utf8)
        try? manualText.write(to: dir.appendingPathComponent("documents/manual.txt"), atomically: true, encoding: .utf8)
        return dir
    }
}
