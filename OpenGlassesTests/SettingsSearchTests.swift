import XCTest
@testable import OpenGlasses

/// Plan NE P2 — finding a setting by typing: what matches, in what order, and that a blank query
/// shows the hub. Pure — no `.shared`.
final class SettingsSearchTests: XCTestCase {

    private let everyone = SettingsSearchConditions(assistingPresent: true, agentMode: true,
                                                    fieldAssistUnlocked: true, fieldAssistOn: true,
                                                    watchInstalled: true, myDayOn: true)

    private func ids(_ query: String, in conditions: SettingsSearchConditions? = nil) -> [String] {
        SettingsSearch.results(for: query, in: conditions ?? everyone).map(\.id)
    }

    private func entry(_ title: String, keywords: [String] = [], kind: SettingsIndexEntry.Kind = .setting)
        -> SettingsIndexEntry {
        SettingsIndexEntry(id: "test", title: title, keywords: keywords, kind: kind, category: .voice,
                           destination: .category(.voice), gate: [])
    }

    private func rank(_ query: String, _ entry: SettingsIndexEntry, breadcrumb: String = "Assistant")
        -> SettingsSearch.Rank? {
        let words = SettingsSearch.words(of: query)
        return SettingsSearch.rank(of: entry, breadcrumb: breadcrumb, words: words,
                                   whole: words.joined(separator: " "))
    }

    // MARK: - A blank query

    func testABlankQueryHasNoResults() {
        for query in ["", " ", "   \n\t "] {
            XCTAssertEqual(ids(query), [], "“\(query)”")
            XCTAssertFalse(SettingsSearch.isSearching(query))
        }
        XCTAssertTrue(SettingsSearch.isSearching(" blur "))
    }

    // MARK: - What it finds

    func testThePlansExamplesAreFound() {
        let memory = ids("memory")
        for id in ["what-avenkin-remembers", "user-memory", "memory-suggestions"] {
            XCTAssertTrue(memory.contains(id), id)
        }
        XCTAssertEqual(ids("hipaa").first, "medical-compliance")
        XCTAssertEqual(ids("blur").first, "blur-bystander-faces")
        XCTAssertTrue(ids("faces").contains("blur-bystander-faces"))
        XCTAssertTrue(ids("wake word").contains("listen-for-wake-phrase"))
        XCTAssertTrue(ids("hey").contains("wake-phrase"))
        XCTAssertTrue(ids("dark").contains("theme"))
    }

    func testMatchingIgnoresCaseAndAccents() {
        XCTAssertEqual(SettingsSearch.fold("Résumé"), SettingsSearch.fold("resume"))
        XCTAssertEqual(SettingsSearch.fold("ÉCOLE"), "ecole")
        XCTAssertEqual(ids("BLUR"), ids("blur"))
        XCTAssertEqual(ids("accéssibilité").first, nil, "a misspelling is not a match")
        XCTAssertEqual(ids("Accéssibility").first, "category-accessibility")
        XCTAssertEqual(rank("resume", entry("Résumé Playback")), .titlePrefix)
    }

    func testEveryWordOfAQueryMustMatch() {
        XCTAssertEqual(ids("blur faces").first, "blur-bystander-faces")
        XCTAssertEqual(ids("faces blur").first, "blur-bystander-faces")
        XCTAssertEqual(ids("blur xyzzy"), [])
        // Words may match across the title, the keywords and where it lives.
        XCTAssertTrue(ids("voice wake").contains("wake-phrase"))
        XCTAssertTrue(ids("hardware microphone").contains("microphone"))
    }

    // MARK: - In what order

    func testRanksFollowThePlansOrder() {
        XCTAssertEqual(rank("wake", entry("Wake Phrase")), .titlePrefix)
        XCTAssertEqual(rank("wake", entry("Listen for Wake Phrase")), .titleWordPrefix)
        XCTAssertEqual(rank("ake", entry("Listen for Wake Phrase")), .titleContains)
        XCTAssertEqual(rank("hey", entry("Wake Phrase", keywords: ["Hey Avenkin"])), .keyword)
        XCTAssertEqual(rank("assistant", entry("Wake Phrase")), .breadcrumb)
        XCTAssertNil(rank("nothing", entry("Wake Phrase")))
        XCTAssertLessThan(SettingsSearch.Rank.titlePrefix, .titleWordPrefix)
        XCTAssertLessThan(SettingsSearch.Rank.titleWordPrefix, .titleContains)
        XCTAssertLessThan(SettingsSearch.Rank.titleContains, .keyword)
        XCTAssertLessThan(SettingsSearch.Rank.keyword, .breadcrumb)
    }

    func testResultsAreSortedByRankThenScreensThenIndexOrder() {
        let results = SettingsSearch.results(for: "glasses", in: everyone)
        XCTAssertEqual(Array(results.prefix(3).map(\.id)), ["glasses", "glasses-only-audio", "glasses-display-hud"],
                       "the screen first, then settings in index order")
        let ranks = results.map(\.rank)
        XCTAssertEqual(ranks, ranks.sorted())
        let order = SettingsIndex.entries.map(\.id)
        for (lhs, rhs) in zip(results, results.dropFirst()) where lhs.rank == rhs.rank {
            if lhs.entry.kind == rhs.entry.kind {
                XCTAssertLessThan(order.firstIndex(of: lhs.id)!, order.firstIndex(of: rhs.id)!)
            } else {
                XCTAssertEqual(lhs.entry.kind, .screen)
            }
        }
    }

    func testABreadcrumbOnlyMatchComesLast() {
        let results = SettingsSearch.results(for: "hardware", in: everyone)
        XCTAssertEqual(results.first?.id, "hardware-privacy")
        XCTAssertEqual(results.first { $0.id == "microphone" }?.rank, .breadcrumb)
    }

    // MARK: - What it may find

    func testResultsComeOnlyFromWhatThisPersonMaySee() {
        let technician = SettingsSearchConditions(context: SettingsIndexTests.technician())
        XCTAssertEqual(ids("blur", in: technician).contains("blur-bystander-faces"), false)
        XCTAssertFalse(ids("hipaa", in: technician).contains("medical-compliance"))
        XCTAssertFalse(ids("quiet after", in: SettingsSearchConditions(simpleMode: true))
            .contains("quiet-after-actions"))
        XCTAssertTrue(ids("glasses", in: technician).contains("glasses"), "Glasses stays open for the technician")
    }

    func testEachResultSaysWhereItLives() {
        for result in SettingsSearch.results(for: "a", in: everyone) {
            XCTAssertEqual(result.breadcrumb, SettingsIndex.breadcrumb(for: result.entry, on: everyone.phone))
            XCTAssertFalse(result.breadcrumb.isEmpty, result.id)
        }
        XCTAssertEqual(SettingsSearch.results(for: "wake phrase", in: everyone).first?.breadcrumb,
                       "Assistant › Voice & Triggers")
    }
}
