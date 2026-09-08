import XCTest
@testable import OpenGlasses

/// Tests for the validator between a model's answer and the knowledge graph.
///
/// This is the one place in the brain where a relation is *proposed* rather than matched, so
/// every bound the regexes get for free has to be re-imposed by hand. Each test below is one of
/// those bounds; together they are the reason a wrong answer costs one unconfirmed row for one
/// expiry window instead of a permanent fact.
final class RelationEnrichmentParserTests: XCTestCase {

    private let source = "Alice has been at Acme since the spring, and Maria moved to Wellington."

    private func object(_ relations: [[String: Any]]) -> [String: Any] {
        ["relations": relations]
    }

    private func wellFormed(relation: String = "works_at",
                            src: String = "Alice",
                            dst: String = "Acme",
                            evidence: String = "Alice has been at Acme") -> [String: Any] {
        ["src": src, "srcKind": "person", "relation": relation,
         "dst": dst, "dstKind": "org", "evidence": evidence]
    }

    /// The happy path, and the shape the ingest side relies on: names as written, the canonical
    /// relation, and the destination kind the ontology dictates.
    func testWellFormedResponseRoundTrips() {
        let parsed = RelationEnrichmentParser.relations(from: object([wellFormed()]),
                                                        sourceText: source)
        XCTAssertEqual(parsed, [BrainRelationExtractor.Relation(
            srcKind: "person", src: "Alice", relation: "works_at", dstKind: "org", dst: "Acme")])
    }

    /// Nothing decoded, nothing stored. A failed or empty call must be indistinguishable from a
    /// turn with no relationships in it.
    func testMissingOrMalformedTopLevelYieldsNothing() {
        XCTAssertTrue(RelationEnrichmentParser.relations(from: nil, sourceText: source).isEmpty)
        XCTAssertTrue(RelationEnrichmentParser.relations(from: [:], sourceText: source).isEmpty)
        XCTAssertTrue(RelationEnrichmentParser.relations(from: ["relations": "not an array"],
                                                         sourceText: source).isEmpty)
    }

    /// All six keys or none of the relation. A half-stated edge is a guess about what the model
    /// meant, and guessing is the failure this whole layer exists to bound.
    func testAnObjectMissingAnyKeyIsRefused() {
        for key in ["src", "srcKind", "relation", "dst", "dstKind", "evidence"] {
            var item = wellFormed()
            item.removeValue(forKey: key)
            XCTAssertTrue(
                RelationEnrichmentParser.relations(from: object([item]), sourceText: source).isEmpty,
                "an object without '\(key)' must be refused")
        }
    }

    /// The vocabulary is closed, and this is the entry point most likely to widen it. A relation
    /// the ontology does not spell is not stored under some near neighbour — it is dropped.
    func testUnknownRelationIsRefused() {
        let item = wellFormed(relation: "vibes_with")
        XCTAssertTrue(RelationEnrichmentParser.relations(from: object([item]),
                                                         sourceText: source).isEmpty)
    }

    /// "Alice knows Alice" says nothing and would sit in the graph forever looking like a fact.
    func testSelfLoopIsRefused() {
        let item = wellFormed(relation: "knows", src: "Alice", dst: "alice",
                              evidence: "Alice has been at Acme")
        XCTAssertTrue(RelationEnrichmentParser.relations(from: object([item]),
                                                         sourceText: source).isEmpty)
    }

    /// The same 60-character bound the patterns apply. A model that hands back a sentence where a
    /// name belongs is answering the wrong question.
    func testOverLongNameIsRefused() {
        let sprawling = String(repeating: "Acme Holdings ", count: 8)
        let item = wellFormed(dst: sprawling, evidence: "Alice has been at Acme")
        XCTAssertGreaterThan(sprawling.count, 60)
        XCTAssertTrue(RelationEnrichmentParser.relations(from: object([item]),
                                                         sourceText: source).isEmpty)
    }

    /// The anchor that separates reading from inventing: the model has to point at the wearer's
    /// own words. A span that is not in the source means the relation came from somewhere else.
    func testEvidenceAbsentFromTheSourceIsRefused() {
        let item = wellFormed(evidence: "Alice founded Acme in 2011")
        XCTAssertTrue(RelationEnrichmentParser.relations(from: object([item]),
                                                         sourceText: source).isEmpty)
    }

    /// A turn that yields nine relations is a model enumerating, not a wearer stating facts, so
    /// the turn's contribution is capped rather than the answer rejected.
    func testNineRelationsAreTruncatedToEight() {
        let names = ["Acme", "Bacme", "Cacme", "Dacme", "Eacme",
                     "Facme", "Gacme", "Hacme", "Iacme"]
        let items = names.map { wellFormed(dst: $0, evidence: "Alice has been at") }
        XCTAssertEqual(items.count, 9)
        let parsed = RelationEnrichmentParser.relations(from: object(items), sourceText: source)
        XCTAssertEqual(parsed.count, RelationEnrichmentParser.maxRelations)
        XCTAssertEqual(parsed.map(\.dst), Array(names.prefix(8)))
    }

    /// The ontology decides what a relation points at, not the answer. A model that calls
    /// Wellington an organisation still gets a place in the graph.
    func testDestinationKindComesFromTheOntologyNotTheAnswer() {
        let item: [String: Any] = ["src": "Maria", "srcKind": "person", "relation": "Lives In",
                                   "dst": "Wellington", "dstKind": "org",
                                   "evidence": "Maria moved to Wellington"]
        let parsed = RelationEnrichmentParser.relations(from: object([item]), sourceText: source)
        XCTAssertEqual(parsed.first?.relation, "lives_in")
        XCTAssertEqual(parsed.first?.dstKind, "place")
    }

    /// One good relation is not spoiled by a bad neighbour: a refusal is per-object, so a mixed
    /// answer still contributes what it got right.
    func testABadObjectDoesNotSinkTheGoodOnesBesideIt() {
        let parsed = RelationEnrichmentParser.relations(
            from: object([wellFormed(relation: "vibes_with"), wellFormed()]),
            sourceText: source)
        XCTAssertEqual(parsed.map(\.dst), ["Acme"])
    }

    /// What the model is told it may say and what the parser will accept are the same list, or
    /// every answer is a drop the wearer never hears about.
    func testTheSchemaOffersExactlyTheOntologyTheParserEnforces() {
        let properties = RelationEnrichmentParser.jsonSchema["properties"] as? [String: Any]
        let relations = properties?["relations"] as? [String: Any]
        let items = relations?["items"] as? [String: Any]
        let itemProperties = items?["properties"] as? [String: Any]
        let relation = itemProperties?["relation"] as? [String: Any]
        XCTAssertEqual(relation?["enum"] as? [String], RelationOntology.sortedRelations)
        XCTAssertEqual(items?["required"] as? [String],
                       ["src", "srcKind", "relation", "dst", "dstKind", "evidence"])
    }
}
