import XCTest
@testable import OpenGlasses

/// The instrument that decides what the evidence gate should be, rather than assuming it.
///
/// Ingests the two real Lennox SLP99 manuals (when a developer has dropped them into
/// `examples/vaults/lennox-slp99/documents/` — skipped otherwise, they are the manufacturer's
/// copyright) into a temporary store, runs a labelled question set through the shipped
/// [[VaultRetriever]], and prints, per policy variant, positive recall@4, insufficiency recall over
/// out-of-scope questions, and the similarity distribution of each side. The printed table is what
/// §2 of `docs/plans/EJ-manual-retrieval-fidelity.md` records; the assertions are kept to the
/// findings that hold rather than to the numbers of one run.
@MainActor
final class RetrievalGateCalibrationTests: XCTestCase {

    // MARK: - Labelled sets

    private static let serviceManual = "SLP99UHVK Service Manual"
    private static let installation = "SLP99UHVK Installation Instructions"

    /// A question the manuals answer, with the printed pages that answer it. Page sets come from
    /// the manuals themselves (grep, not from a run of the retriever) and list every page the
    /// answer spans, because a chunk is attributed to the page it starts on.
    private struct Positive {
        let query: String
        let anchors: [String: Set<Int>]
    }

    private static let positives: [Positive] = [
        .init(query: "what is the manifold pressure on high fire",
              anchors: [serviceManual: [65, 66, 67], installation: [62, 63, 64]]),
        .init(query: "how do I measure the gas supply pressure at the valve",
              anchors: [serviceManual: [64, 65], installation: [62]]),
        .init(query: "what flame signal in microamps should I read at the sensor",
              anchors: [serviceManual: [34], installation: [64]]),
        .init(query: "how long is the pre-purge before the ignitor warm up begins",
              anchors: [serviceManual: [15, 76, 77], installation: [65, 66]]),
        .init(query: "how do I prime the condensate trap with water",
              anchors: [serviceManual: [63], installation: [61]]),
        .init(query: "what is the correct heating temperature rise for this furnace",
              anchors: [serviceManual: [2, 69], installation: [65]]),
        .init(query: "how do I configure the unit size code on the integrated control",
              anchors: [serviceManual: [30], installation: [70]]),
        .init(query: "which propane conversion kit does this furnace need",
              anchors: [serviceManual: [67], installation: [64]]),
        .init(query: "what high altitude pressure switch is required above seven thousand feet",
              anchors: [serviceManual: [67], installation: [64]]),
        .init(query: "how do I clock the gas meter to check the input rate",
              anchors: [serviceManual: [65], installation: [62]]),
        .init(query: "what external static pressure range does the blower cover",
              anchors: [serviceManual: [4], installation: [48, 56]]),
        .init(query: "how do I inspect the heat exchanger during annual maintenance",
              anchors: [installation: [67, 68]]),
        // Short in-scope questions — the way a technician mid-job actually asks. Each carries two
        // or three content terms after [[LexicalSupport]] drops words under four letters, which is
        // the case a flat `minSharedTerms` of 3 can never satisfy. Same subjects, and so the same
        // grep-verified anchor pages, as the long-form questions above.
        .init(query: "pre-purge time",
              anchors: [serviceManual: [15, 76, 77], installation: [65, 66]]),
        .init(query: "flame signal microamps",
              anchors: [serviceManual: [34], installation: [64]]),
        .init(query: "condensate trap priming",
              anchors: [serviceManual: [63], installation: [61]]),
        .init(query: "trap water amount",
              anchors: [serviceManual: [63], installation: [61]]),
        .init(query: "high fire manifold pressure",
              anchors: [serviceManual: [65, 66, 67], installation: [62, 63, 64]]),
    ]

    /// Questions these two manuals do not answer: other manufacturers, other equipment, figures the
    /// Lennox pair never prints. An answer to any of these is a fabrication the gate should have
    /// stopped.
    private static let negatives: [String] = [
        "what is the torque for the blower wheel set screw",
        "how do I replace the heat exchanger on a Carrier 58MVB",
        "how do I charge the refrigerant on the outdoor unit",
        "how do I reset the defrost board on a heat pump",
        "what size ductwork do I need for a large two storey house",
        "what is the weather forecast for tomorrow afternoon",
        "how do I wire a Trane XR95 two stage thermostat",
        "what is the seasonal efficiency rating of a Goodman condenser",
        "how much does a replacement inducer motor cost to buy",
        "what oil does the York chiller pump take",
        "how do I bleed the radiators on a hydronic boiler",
        "what is the warranty claim procedure for Rheem parts",
        // Short out-of-scope questions, the counterweight to the short in-scope ones: whatever a
        // fraction buys for a two-term question it must not spend on these.
        "compressor amp draw",
        "refrigerant charge weight",
        "defrost board wiring",
        "duct sizing chart",
    ]

    /// The gate variants compared. `margin` and `minSharedTerms` are switched on one at a time so
    /// each column of the table is attributable to one criterion.
    private static let variants: [(name: String, policy: RetrievalEvidencePolicy)] = [
        ("floor 0.30 (shipped before P2)", RetrievalEvidencePolicy()),
        ("floor 0.30 + margin 0.02", RetrievalEvidencePolicy(similarityFloor: 0.30, margin: 0.02)),
        ("floor 0.30 + margin 0.005", RetrievalEvidencePolicy(similarityFloor: 0.30, margin: 0.005)),
        ("floor 0.88", RetrievalEvidencePolicy(similarityFloor: 0.88)),
        ("floor 0.30 + terms >= 1", RetrievalEvidencePolicy(similarityFloor: 0.30, minSharedTerms: 1)),
        ("floor 0.30 + terms >= 2", RetrievalEvidencePolicy(similarityFloor: 0.30, minSharedTerms: 2)),
        ("floor 0.30 + terms >= 3", RetrievalEvidencePolicy(similarityFloor: 0.30, minSharedTerms: 3)),
        ("floor 0.30 + terms >= 4", RetrievalEvidencePolicy(similarityFloor: 0.30, minSharedTerms: 4)),
        ("floor 0.30 + terms >= 5", RetrievalEvidencePolicy(similarityFloor: 0.30, minSharedTerms: 5)),
        ("floor 0.30 + terms >= 3 + margin 0.02",
         RetrievalEvidencePolicy(similarityFloor: 0.30, margin: 0.02, minSharedTerms: 3)),
        // The count scaled to the question's own length, so a two-term question is asked for two
        // terms rather than an unreachable three.
        ("floor 0.30 + terms >= 3 + fraction 0.5",
         RetrievalEvidencePolicy(similarityFloor: 0.30, minSharedTerms: 3, sharedFraction: 0.5)),
        ("floor 0.30 + terms >= 3 + fraction 0.6",
         RetrievalEvidencePolicy(similarityFloor: 0.30, minSharedTerms: 3, sharedFraction: 0.6)),
        ("floor 0.30 + terms >= 3 + fraction 0.75",
         RetrievalEvidencePolicy(similarityFloor: 0.30, minSharedTerms: 3, sharedFraction: 0.75)),
        ("default(for: nl-word)", RetrievalEvidencePolicy.default(for: "nl-word.en")),
    ]

    // MARK: - Fixture

    private var tempRoot: URL!

    private static var documentsDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OpenGlassesTests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("examples/vaults/lennox-slp99/documents", isDirectory: true)
    }

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RetrievalGateCalibration-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    /// The two manuals in a fresh store, or a skip when they aren't checked out locally.
    private func ingestManuals() async throws -> DocumentStore {
        let dir = Self.documentsDirectory
        let files = [(Self.serviceManual, "SLP99UHVK-service-manual.md"),
                     (Self.installation, "SLP99UHVK-installation-instructions.md")]
        for (_, file) in files where !FileManager.default.fileExists(atPath: dir.appendingPathComponent(file).path) {
            throw XCTSkip("Lennox manuals not present in \(dir.path); see its README")
        }
        let store = DocumentStore(directory: tempRoot)
        for (title, file) in files {
            let text = try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
            _ = await store.ingest(name: title, text: text, sourceType: "text")
        }
        return store
    }

    private func retriever(over store: DocumentStore, policy: RetrievalEvidencePolicy) -> VaultRetriever {
        VaultRetriever(query: { query, limit in store.query(query, limit: limit) },
                       tokenSearch: { token, limit in store.passages(containingToken: token, limit: limit) },
                       provenance: nil,
                       policy: policy)
    }

    // MARK: - The measurement

    func testGateVariantsMeasuredAgainstTheLennoxPair() async throws {
        let store = try await ingestManuals()
        // A permissive gate so `retrieve` returns the ranked list itself; every variant is then
        // applied to that same list, which is exactly what the shipped `decide` does.
        let open = retriever(over: store, policy: RetrievalEvidencePolicy(similarityFloor: 0))

        func ranked(_ query: String) -> [VaultRetriever.Passage] {
            open.retrieve(.init(turn: query, limit: 25)).passages
        }
        let positiveRanked = Self.positives.map { (p: $0, ranked: ranked($0.query)) }
        let negativeRanked = Self.negatives.map { (query: $0, ranked: ranked($0)) }

        print("[GATE] embedder=\(Embedder().modelId) sentenceModel=\(Embedder().usesSentenceModel) "
              + "chunks=\(store.documents.map(\.chunkCount).reduce(0, +))")

        // Distribution of the top-4 similarities on each side — the question the whole exercise
        // turns on is whether these two ranges are distinguishable at all.
        let positiveSims = positiveRanked.flatMap { $0.ranked.prefix(4).map(\.similarity) }
        let negativeSims = negativeRanked.flatMap { $0.ranked.prefix(4).map(\.similarity) }
        print("[GATE] similarity positives \(describe(positiveSims)) | negatives \(describe(negativeSims))")

        for (p, list) in positiveRanked {
            let top = list.prefix(4).map { "\($0.citation) \(fmt($0.similarity))" }
            print("[GATE] + '\(p.query)' hit=\(hits(p, in: list, k: 4)) → \(top)")
        }
        for (q, list) in negativeRanked {
            let top = list.prefix(2).map { "\($0.citation) \(fmt($0.similarity)) tokens=\($0.matchedTokens)" }
            print("[GATE] - '\(q)' → \(top)")
        }

        // How many content terms each question actually carries — the number a flat count has to be
        // reachable by, and the number a fraction scales against.
        for p in Self.positives {
            let terms = LexicalSupport.contentTerms(p.query)
            print("[GATE] terms(+) \(terms.count) '\(p.query)' \(terms.sorted())")
        }
        for q in Self.negatives {
            let terms = LexicalSupport.contentTerms(q)
            print("[GATE] terms(-) \(terms.count) '\(q)'")
        }

        print("[GATE] variant | recall@4 | insufficiency recall | in-scope questions refused")
        var scores: [String: (recall: Double, insufficiency: Double, falseRefusals: Double)] = [:]
        for (name, policy) in Self.variants {
            // recall@4 under the variant: the gate runs first, so a criterion that drops a correct
            // passage costs recall — which is the trade the table exists to show. It also rises when
            // a criterion drops off-topic passages that were crowding the top four.
            let decisions = positiveRanked.map { p, list in
                (p: p, outcome: policy.decide(list, limit: 4, queryTerms: LexicalSupport.contentTerms(p.query)))
            }
            let gated: [(query: String, rankedIds: [String])] = decisions.map { decision in
                (decision.p.query,
                 decision.outcome.passages.compactMap { locationId($0, anchors: decision.p.anchors) })
            }
            let labels = Dictionary(uniqueKeysWithValues: Self.positives.map { ($0.query, "hit") })
            let recall = EmbeddingBenchmark.recallAtK(4, results: gated, labels: labels)
            let insufficiency = EmbeddingBenchmark.insufficiencyRecall(
                policy: policy,
                results: negativeRanked.map { (query: $0.query, ranked: $0.ranked) },
                limit: 4)
            // The cost side of the same coin: an in-scope question told "the manuals do not cover this".
            let falseRefusals = Double(decisions.filter { !$0.outcome.isSufficient }.count) / Double(decisions.count)
            scores[name] = (recall, insufficiency, falseRefusals)
            print("[GATE] \(name) | \(fmt(Float(recall))) | \(fmt(Float(insufficiency))) | \(fmt(Float(falseRefusals)))")
            let refusedHere = decisions.filter { !$0.outcome.isSufficient }.map(\.p.query)
            if !refusedHere.isEmpty { print("[GATE]   \(name) refuses in scope: \(refusedHere)") }
        }

        // What the shipped default still lets through, and what it wrongly turns away. Printed:
        // these are the residue the plan records, not a threshold to tune against.
        let shipped = RetrievalEvidencePolicy.default(for: Embedder().modelId)
        let answered = negativeRanked.filter {
            shipped.decide($0.ranked, limit: 4, queryTerms: LexicalSupport.contentTerms($0.query)).isSufficient
        }.map(\.query)
        let refused = positiveRanked.filter {
            !shipped.decide($0.ranked, limit: 4, queryTerms: LexicalSupport.contentTerms($0.p.query)).isSufficient
        }.map(\.p.query)
        print("[GATE] shipped default still answers: \(answered)")
        print("[GATE] shipped default refuses in scope: \(refused)")

        // --- Findings asserted, one at a time ---

        // Retrieval itself works: every question, in scope or not, comes back with passages. That is
        // the premise of the whole exercise — the gate is the only thing standing between an
        // out-of-scope question and a confident answer.
        for (p, list) in positiveRanked { XCTAssertFalse(list.isEmpty, p.query) }
        for (q, list) in negativeRanked { XCTAssertFalse(list.isEmpty, q) }

        // A relative margin cannot reject a query, at any setting: the best passage in the list is
        // always within `margin` of itself. It trims a weak tail, nothing more. This is a property
        // of the criterion, not of this corpus, so it is asserted rather than printed.
        let baseline = try XCTUnwrap(scores["floor 0.30 (shipped before P2)"])
        for name in ["floor 0.30 + margin 0.02", "floor 0.30 + margin 0.005"] {
            let variant = try XCTUnwrap(scores[name])
            XCTAssertEqual(variant.insufficiency, baseline.insufficiency, accuracy: 1e-9,
                           "a margin cannot make a query insufficient: \(name)")
        }

        let chosen = try XCTUnwrap(scores["default(for: nl-word)"])

        if Embedder().modelId.hasPrefix("nl-word") {
            // The lexical criterion is the only one that rejects anything on this backend, which is
            // why the measured default carries it. Asserted only here: on a backend whose defaults
            // are still today's gate, `default(for:)` is the baseline by construction.
            XCTAssertGreaterThan(chosen.insufficiency, baseline.insufficiency,
                                 "the chosen default must reject more than the floor alone")

            // On the word-average backend the two similarity ranges overlap completely, which is
            // why no floor and no margin can separate them. Guarded by backend: a sentence or
            // contextual model may well separate them, and that measurement is still pending.
            let bestNegative = try XCTUnwrap(negativeSims.max())
            let worstPositive = try XCTUnwrap(positiveSims.min())
            XCTAssertGreaterThan(bestNegative, worstPositive,
                                 "similarity is expected to be flat on nl-word: positives \(describe(positiveSims)), "
                                 + "negatives \(describe(negativeSims))")
            XCTAssertEqual(baseline.insufficiency, 0, accuracy: 1e-9,
                           "the 0.30 floor rejects nothing on this backend")
            XCTAssertGreaterThanOrEqual(chosen.recall, 0.5, "the chosen default keeps most in-scope answers")

            // Why the default scales the shared-term count instead of applying it flat: the whole
            // case for the fraction is that it costs nothing on the out-of-scope side. If a future
            // corpus makes it cost something, this fails and the default goes back to the flat
            // count rather than quietly trading refusals for answers.
            let flat = try XCTUnwrap(scores["floor 0.30 + terms >= 3"])
            XCTAssertGreaterThanOrEqual(chosen.insufficiency, flat.insufficiency,
                                        "scaling the count must not let more out-of-scope questions through")
            XCTAssertLessThanOrEqual(chosen.falseRefusals, flat.falseRefusals,
                                     "scaling the count must refuse no more in-scope questions than the flat count")
        }
    }

    // MARK: - Helpers

    /// "hit" when the passage sits on one of the pages that actually answers the question, nil
    /// otherwise — shaped for `EmbeddingBenchmark.recallAtK`, which asks for ranked ids.
    private func locationId(_ passage: VaultRetriever.Passage, anchors: [String: Set<Int>]) -> String? {
        guard let page = passage.page, let pages = anchors[passage.documentName], pages.contains(page) else { return nil }
        return "hit"
    }

    private func hits(_ positive: Positive, in list: [VaultRetriever.Passage], k: Int) -> Int {
        list.prefix(k).filter { locationId($0, anchors: positive.anchors) != nil }.count
    }

    private func fmt(_ value: Float) -> String { String(format: "%.3f", value) }

    private func describe(_ values: [Float]) -> String {
        guard !values.isEmpty else { return "(none)" }
        let sorted = values.sorted()
        let median = sorted[sorted.count / 2]
        return "min \(fmt(sorted.first!)) median \(fmt(median)) max \(fmt(sorted.last!)) n=\(values.count)"
    }
}
