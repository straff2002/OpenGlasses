import XCTest
@testable import OpenGlasses

/// A guard against the defect that shipped twice in Plan CV: an `Interruption` case declared,
/// documented, handled in every exhaustive switch, tested at the policy layer — and **never
/// raised**. `.realtimeSession` and `.cameraUnavailable` were both green the whole time they were
/// dead code, and one of them meant narration silently described nothing while Settings said
/// "Watching…".
///
/// Why the existing tests could not catch it, which is the part worth understanding: exhaustive
/// switches force a new case to decide *what the wearer is told*, and the unit tests call
/// `noteInterruption` **themselves**, so the seam is exercised identically whether or not anything
/// in the app ever calls it. A pure core tested exhaustively tells you the decision is right; it
/// can never tell you that anything asks.
///
/// So this test reads the app's source rather than running it. `#filePath` is the repo anchor —
/// baked in at compile time, so it resolves the same on a developer machine and in CI, and the
/// simulator shares the host filesystem.
///
/// **Known limitation, stated rather than hidden:** it matches a literal `noteInterruption(.case`,
/// so a raise site that passes the interruption in a variable would not be seen. That is a
/// deliberate trade — the check is cheap and its failure mode is a false alarm that a human
/// resolves in seconds, which is the right way round for a guard whose absence cost two bugs.
final class NarrationInterruptionWiringTests: XCTestCase {

    /// `<repo>/OpenGlasses/Sources` — the app target only. Deliberately **not** the test target:
    /// tests raise every case by construction, so including them would make this pass always,
    /// which is precisely the failure being guarded against.
    private static var appSourcesDirectory: URL {
        URL(fileURLWithPath: #filePath)   // <repo>/OpenGlassesTests/<thisfile>.swift
            .deletingLastPathComponent()  // <repo>/OpenGlassesTests
            .deletingLastPathComponent()  // <repo>
            .appendingPathComponent("OpenGlasses")
            .appendingPathComponent("Sources")
    }

    private static func appSourceText() throws -> String {
        let root = appSourcesDirectory
        guard let walker = FileManager.default.enumerator(at: root,
                                                          includingPropertiesForKeys: nil) else {
            throw XCTSkip("Could not enumerate \(root.path)")
        }
        var text = ""
        for case let url as URL in walker where url.pathExtension == "swift" {
            text += (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            text += "\n"
        }
        return text
    }

    /// The guard itself.
    func testEveryInterruptionIsActuallyRaisedByTheApp() throws {
        let sources = try Self.appSourceText()

        for interruption in NarrationSessionPolicy.Interruption.allCases {
            XCTAssertTrue(
                sources.contains("noteInterruption(.\(interruption.rawValue)"),
                """
                `NarrationSessionPolicy.Interruption.\(interruption.rawValue)` is declared but \
                nothing in OpenGlasses/Sources ever raises it, so narration will never react to \
                it. Either wire it (see the `.backgrounded` / `.ambientCaptions` / \
                `.cameraUnavailable` edges in AppState) or delete the case — a case that only \
                appears in switch statements and tests is dead policy that reads as shipped \
                behaviour.
                """)
        }
    }

    /// The guard's own guard. If the repo anchor ever stops resolving — a moved test file, a
    /// sandbox with no host filesystem — the scan would find nothing and the check above would
    /// pass vacuously, which is a silently disabled test: worse than no test, because the green
    /// tick still reads as a promise.
    func testTheScanIsActuallyReadingTheAppSources() throws {
        let sources = try Self.appSourceText()

        XCTAssertFalse(sources.isEmpty, "The app sources did not resolve — see appSourcesDirectory")
        XCTAssertTrue(sources.contains("final class SceneNarrationService"),
                      "Sanity: the scan should be seeing the narration service")
        XCTAssertFalse(sources.contains("noteInterruption(.aCaseThatHasNeverExisted"),
                       "Sanity: the match must not be trivially true for any token")
    }
}
