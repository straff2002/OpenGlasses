import XCTest
@testable import OpenGlasses

/// Change detection for the instructions the safety corpus was evaluated against (W08.4).
///
/// The corpus measures the app's handling of a model response under one set of prompts and schemas.
/// Edit a prompt and the last run's numbers describe a build that no longer exists — so a moved
/// digest fails here, and the only way to make it pass is to bump the corpus version, which is the
/// point at which somebody has to look at whether the corpus still evaluates the right thing.
///
/// Regenerating the snapshot is deliberately awkward: `SAFETY_EVAL_UPDATE_DIGESTS=1`, and only after
/// the corpus version has been bumped. The procedure is in the corpus README.
final class PromptVersionRegistryTests: XCTestCase {

    private static let snapshotFile = "prompt-digests.json"
    private static let updateFlag = "SAFETY_EVAL_UPDATE_DIGESTS"

    /// The digest is only a version identifier if it is stable. A JSON Schema is a dictionary, and
    /// Swift seeds dictionary hashing per process, so anything reflecting one into a string is
    /// stable within a run and different in the next.
    func testEveryRegisteredSchemaSerialisesToCanonicalJSON() {
        for schema in PromptVersionRegistry.schemas {
            let (_, json) = PromptVersionRegistry.instructions(for: schema)
            XCTAssertTrue(JSONSerialization.isValidJSONObject(json),
                          "\(schema.kind): the augmented JSON schema will not serialise, so its digest "
                          + "falls back to a reflected description that changes every launch")
        }
    }

    func testDigestIgnoresDictionaryOrdering() {
        let a: [String: Any] = ["type": "object",
                                "properties": ["b": ["type": "string"], "a": ["type": "number"]]]
        let b: [String: Any] = ["properties": ["a": ["type": "number"], "b": ["type": "string"]],
                                "type": "object"]
        XCTAssertEqual(AIProvenance.promptDigest(systemPrompt: "p", jsonSchema: a),
                       AIProvenance.promptDigest(systemPrompt: "p", jsonSchema: b))
        XCTAssertNotEqual(AIProvenance.promptDigest(systemPrompt: "p", jsonSchema: a),
                          AIProvenance.promptDigest(systemPrompt: "p2", jsonSchema: a))
    }

    func testSnapshotCoversEveryRegisteredVertical() throws {
        let snapshot = try loadSnapshot()
        for schema in PromptVersionRegistry.schemas {
            XCTAssertNotNil(snapshot.digests[schema.kind],
                            "\(schema.kind) has no recorded prompt digest — a new vertical must be "
                            + "snapshotted before it can be evaluated")
        }
    }

    /// The load-bearing one: current digests against the snapshot, and the snapshot against the
    /// corpus version it was taken at.
    func testPromptDigestsMatchTheSnapshotForThisCorpusVersion() throws {
        let snapshot = try loadSnapshot()
        let corpus = try SafetyEvalCorpusLoader.load()
        let current = PromptVersionRegistry.digests()

        XCTAssertEqual(snapshot.corpusVersion, corpus.version,
                       "prompt-digests.json records corpus version \(snapshot.corpusVersion) but "
                       + "corpus.json is at \(corpus.version): the snapshot was taken against a "
                       + "different corpus than the one that would run")

        let moved = current.filter { snapshot.digests[$0.key] != $0.value }.keys.sorted()
        guard !moved.isEmpty else { return }

        if ProcessInfo.processInfo.environment[Self.updateFlag] == "1" {
            if snapshot.corpusVersion == corpus.version {
                XCTFail("""
                \(moved.joined(separator: ", ")) changed while the corpus version stayed at \
                \(corpus.version). Bump `corpus_version` in corpus.json first — a prompt change is a \
                behaviour change, and the corpus has to be re-read against the new instructions \
                before its results mean anything.
                """)
                return
            }
            try writeSnapshot(digests: current, corpusVersion: corpus.version, previous: snapshot)
            XCTFail("""
            Snapshot regenerated at corpus version \(corpus.version) for: \
            \(moved.joined(separator: ", ")). Review the diff to prompt-digests.json, then re-run \
            without \(Self.updateFlag).
            """)
            return
        }

        XCTFail("""
        The instructions changed and the safety corpus has not been re-evaluated against them.

        Moved: \(moved.map { "\($0) \(snapshot.digests[$0] ?? "—") → \(current[$0] ?? "—")" }.joined(separator: "\n                "))

        To proceed: bump `corpus_version` in corpus.json, review the corpus against the new \
        instructions, then re-run this test once with \(Self.updateFlag)=1 to record the new digests.
        """)
    }

    // MARK: - Snapshot file

    private struct Snapshot {
        let corpusVersion: String
        let digests: [String: String]
        let history: [[String: Any]]
    }

    private func loadSnapshot() throws -> Snapshot {
        let json = try SafetyEvalCorpusLoader.object(at: Self.snapshotFile)
        guard let corpusVersion = json["corpus_version"] as? String,
              let digests = json["digests"] as? [String: String] else {
            throw SafetyEvalError.malformed("\(Self.snapshotFile) is missing corpus_version or digests")
        }
        return Snapshot(corpusVersion: corpusVersion, digests: digests,
                        history: json["history"] as? [[String: Any]] ?? [])
    }

    private func writeSnapshot(digests: [String: String], corpusVersion: String, previous: Snapshot) throws {
        let stamp = ISO8601DateFormatter().string(from: Date())
        var history = previous.history
        history.append(["corpus_version": previous.corpusVersion, "digests": previous.digests])
        let payload: [String: Any] = [
            "schema_version": "1",
            "corpus_version": corpusVersion,
            "recorded": stamp,
            "note": "Digests of the instructions the corpus at this version was evaluated against. "
                + "Regenerate only through PromptVersionRegistryTests, and only after bumping corpus_version.",
            "digests": digests,
            "history": history,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: SafetyEvalCorpusLoader.directory.appendingPathComponent(Self.snapshotFile))
    }
}
