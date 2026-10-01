import XCTest
@testable import OpenGlasses

/// Plan GG P0 — every kind of fact lands in exactly one group, the way the wearer thinks of it.
final class MemoryFactGrouperTests: XCTestCase {

    func testEverySemanticTopicLandsInOneGroup() {
        let expected: [String: MemoryFactGroup] = [
            "people": .people, "places": .places, "preferences": .preferences, "health": .health,
            "work": .other, "finance": .other, "learning": .other, "general": .other,
            "something-new": .other,
        ]
        for (topic, group) in expected {
            XCTAssertEqual(MemoryFactGrouper.group(for: .semantic(topic: topic)), group, topic)
        }
    }

    func testBrainKindsGroupByWhoTheyAreAbout() {
        XCTAssertEqual(MemoryFactGrouper.group(for: .relation(relation: "lives_in", srcKind: "person", dstKind: "place")), .people)
        XCTAssertEqual(MemoryFactGrouper.group(for: .relation(relation: "works_at", srcKind: "org", dstKind: "person")), .people)
        XCTAssertEqual(MemoryFactGrouper.group(for: .relation(relation: "located_in", srcKind: "org", dstKind: "place")), .other)
        XCTAssertEqual(MemoryFactGrouper.group(for: .need), .unfinished)
        XCTAssertEqual(MemoryFactGrouper.group(for: .projectNote), .unfinished)
    }

    func testPlacesNotesAndDiary() {
        XCTAssertEqual(MemoryFactGrouper.group(for: .object), .places)
        XCTAssertEqual(MemoryFactGrouper.group(for: .savedPlace), .places)
        XCTAssertEqual(MemoryFactGrouper.group(for: .agentNote), .other)
        XCTAssertEqual(MemoryFactGrouper.group(for: .diary), .other,
                       "inferred diary observations show under Other (decision 4)")
    }

    func testGroupedKeepsDisplayOrderDropsEmptyGroupsAndPutsHealthLast() {
        let now = Date()
        func fact(_ id: String, _ kind: MemoryFactKind, _ age: TimeInterval) -> MemoryFact {
            MemoryFact(id: MemoryFactID(store: .semantic, recordID: id), text: id, kind: kind,
                       origin: .toldMe, createdAt: now.addingTimeInterval(-age))
        }
        let grouped = MemoryFactGrouper.grouped([
            fact("knee", .semantic(topic: "health"), 1),
            fact("old-sister", .semantic(topic: "people"), 100),
            fact("new-sister", .semantic(topic: "people"), 10),
            fact("tea", .semantic(topic: "preferences"), 5),
        ])
        XCTAssertEqual(grouped.map(\.group), [.people, .preferences, .health])
        XCTAssertEqual(grouped[0].facts.map(\.text), ["new-sister", "old-sister"], "newest first")
    }
}
