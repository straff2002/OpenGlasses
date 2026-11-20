import XCTest
@testable import OpenGlasses

/// Plan MM P0 — what is said when the system holds the count: as-of always, stale first, unknown
/// never a number, "in <system>" and never "counted", the place's own words.
final class StockSystemAnswerComposerTests: XCTestCase {

    private typealias S = StockSystemSamples

    /// 15:00 on the day of the pull.
    private let now = S.date(2026, 11, 20, 15, 0)

    private func composer(_ kind: StockPlace.Kind = .stock, now: Date? = nil) -> StockSystemAnswerComposer {
        StockSystemAnswerComposer(now: now ?? self.now, calendar: S.calendar, wording: StockPlaceWording(kind),
                                  system: "Sample System")
    }

    private func check(_ row: StockSystemRawRow, kind: StockPlace.Kind = .stock, here: [String] = ["L1"],
                       pulledAt: Date = S.pulledAt, now: Date? = nil,
                       unsent: StockSystemAnswerComposer.Unsent? = nil) -> String {
        let snapshot = S.snapshot([row], pulledAt: pulledAt)
        return composer(kind, now: now).check(snapshot.lines[0], in: snapshot, here: here, unsent: unsent)
    }

    func testAFigureNamesTheSystemAndItsAsOfTime() {
        XCTAssertEqual(check(S.row("1001", [("L1", "3")])),
                       "3 × Capacitor 45/5 (ZX-1001) in stock in Sample System, as of 09:10.")
        XCTAssertEqual(check(S.row("1002", description: "Coolant", unit: "litre", [("L1", "4.25")]), kind: .store),
                       "4.25 litres of Coolant (ZX-1002) in the store in Sample System, as of 09:10.")
        // Two of the system's locations are this place: their figures add up.
        XCTAssertEqual(check(S.row("1001", [("L1", "3"), ("L2", "2")]), here: ["L1", "L2"]),
                       "5 × Capacitor 45/5 (ZX-1001) in stock in Sample System, as of 09:10.")
        // The line's own date wins over the snapshot's.
        XCTAssertEqual(check(S.row("1001", [("L1", "3")], asOf: "2026-11-20T08:45:00Z")),
                       "3 × Capacitor 45/5 (ZX-1001) in stock in Sample System, as of 08:45.")
    }

    func testAStaleSnapshotSaysItsAgeFirst() {
        let answer = check(S.row("1001", [("L1", "3")]), pulledAt: S.date(2026, 11, 19, 14, 10))
        XCTAssertEqual(answer, "As of yesterday at 14:10, Sample System had 3 × Capacitor 45/5 (ZX-1001) in stock.")
        // Yesterday within 24 hours is not stale.
        XCTAssertEqual(check(S.row("1001", [("L1", "3")]), pulledAt: S.date(2026, 11, 19, 16, 10),
                             now: S.date(2026, 11, 20, 9, 0)),
                       "3 × Capacitor 45/5 (ZX-1001) in stock in Sample System, as of yesterday at 16:10.")
        let old = check(S.row("1001", [("L1", "3")]), pulledAt: S.date(2026, 11, 2, 7, 0))
        XCTAssertTrue(old.hasPrefix("As of 2 November, Sample System had"), old)
    }

    func testAnUnknownIsNeverANumber() {
        let rows = [
            S.row("1", description: "Brake fluid", unit: "litre", [("L1", "1.23456")]),
            S.row("1", description: "Fastener tin", unit: "tin", [("L1", "7")]),
            S.row("1", description: "Oil filter", [("L1", nil)]),
            S.row("1", description: "Fuse", [("L1", "-2")]),
            S.row("1", description: "Cable tie", [("L1", "2.5")]),
            S.row("1", description: "Fuse", [("L2", "4")]),     // nothing at this place at all
        ]
        for row in rows {
            let answer = check(row)
            XCTAssertTrue(answer.hasPrefix("Sample System lists \(row.description!) (ZX-1) but has no count for it."), answer)
            let withoutName = answer.replacingOccurrences(of: "(ZX-1)", with: "")
            XCTAssertNil(withoutName.rangeOfCharacter(from: .decimalDigits), "a number in: \(answer)")
            XCTAssertTrue(answer.hasSuffix("Do not give a figure for it."), answer)
            XCTAssertNil(answer.range(of: "\\bcounted\\b", options: .regularExpression), answer)
        }
        XCTAssertTrue(check(rows[0]).contains("Sample System holds that to more decimal places than I keep, "
            + "so I can't give you its figure."))
        XCTAssertTrue(check(rows[1]).contains("counts it in 'tin', which is not a unit kept on the phone"))
    }

    func testSomeLocationsUnknownGiveOnlyTheKnownFigure() {
        let answer = check(S.row("1001", [("L1", "3"), ("L2", nil)]), here: ["L1", "L2"])
        XCTAssertEqual(answer, "3 × Capacitor 45/5 (ZX-1001) in stock in Sample System, as of 09:10. "
            + "Sample System has no count for it at North Bay.")
    }

    func testNoneHereNamesTheOtherLocations() {
        XCTAssertEqual(check(S.row("1001", [("L1", "0"), ("L2", "2")])),
                       "No Capacitor 45/5 (ZX-1001) in stock in Sample System, as of 09:10; 2 at North Bay.")
        XCTAssertEqual(check(S.row("1001", [("L1", "0")])),
                       "No Capacitor 45/5 (ZX-1001) in stock in Sample System, as of 09:10.")
    }

    func testNotCarriedAndTheJoinsOtherOutcomes() {
        let snapshot = S.snapshot([S.row("1001", [("L1", "3")])])
        let part = S.parts([("ZX-9009", "Fuse kit", nil)]).parts[0]
        let composer = composer()
        XCTAssertTrue(composer.check(.vaultOnly(part), in: snapshot, here: ["L1"])
            .hasPrefix("Sample System doesn't carry that number"))
        XCTAssertEqual(composer.check(.neither, in: snapshot, here: ["L1"]), composer.notCarried())
        XCTAssertTrue(composer.check(.systemOnly(snapshot.lines[0], bookSearched: true), in: snapshot, here: ["L1"])
            .hasSuffix("It is stocked in Sample System, but I can't check that number against the book."))
        XCTAssertFalse(composer.check(.systemOnly(snapshot.lines[0], bookSearched: false), in: snapshot, here: ["L1"])
            .contains("check that number"))
    }

    func testAStagedOrSendingUseIsSaid() {
        let row = S.row("1001", [("L1", "2")])
        XCTAssertEqual(check(row, unsent: .init(quantity: .whole(1), state: .sending)),
                       "2 × Capacitor 45/5 (ZX-1001) in stock in Sample System, as of 09:10, "
                       + "and 1 used on this job is still being sent.")
        XCTAssertTrue(check(row, unsent: .init(quantity: .whole(1), state: .staged))
            .hasSuffix("and 1 used on this job is noted and not yet sent to Sample System."))

        let line = S.snapshot([row]).lines[0]
        XCTAssertEqual(composer(.van).staged(.whole(1), of: line, jobReference: nil),
                       "I've noted 1 × Capacitor 45/5 (ZX-1001) used on this job. It goes to Sample System when "
                       + "the technician confirms the job's parts, and Sample System's count does not change until then.")
    }

    func testTheRefusalsAndTheTill() {
        let composer = composer(.store)
        XCTAssertEqual(composer.refused(.load),
                       "Stock is kept in Sample System, so each receipt and count is done there, not on the phone. "
                       + "Nothing was changed.")
        for action: StockSystemAnswerComposer.RefusedAction in [.count, .setStandard, .topUp, .undoLoad] {
            XCTAssertTrue(composer.refused(action).hasPrefix("Stock is kept in Sample System, so "))
        }
        XCTAssertTrue(composer.refused(.setStandard).contains("par level"))
        XCTAssertEqual(composer.noSale(),
                       "Sales come off Sample System's count at the till; the phone never records a sale. Nothing was changed.")
    }

    /// Provenance is "in <system>", never "counted"; each place hears only its own words.
    func testNeverCountedAndOnlyThePlacesOwnWords() {
        for kind in StockPlace.Kind.allCases {
            let composer = composer(kind)
            let snapshot = S.snapshot([S.row("1001", [("L1", "0"), ("L2", "2")]),
                                       S.row("1002", unit: "litre", [("L1", "0.5")])])
            var said = [
                composer.check(snapshot.lines[0], in: snapshot, here: ["L1"]),
                composer.check(snapshot.lines[1], in: snapshot, here: ["L1"]),
                composer.check(snapshot.lines[1], in: snapshot, here: ["L1"], unsent: .init(quantity: .whole(1), state: .staged)),
                composer.notCarried(), composer.noSale(), composer.handoverNotOffered(),
                composer.staged(.whole(1), of: snapshot.lines[0], jobReference: "J-1"),
            ]
            let refusals: [StockSystemAnswerComposer.RefusedAction] = [.load, .count, .setStandard, .topUp, .undoLoad]
            said += refusals.map { composer.refused($0) }
            if kind.family == .premises {
                said.append(composer.stagedForToday(.whole(1), of: snapshot.lines[0]))
            } else {
                said.append(composer.useNeedsJob())
            }
            for sentence in said {
                XCTAssertNil(sentence.range(of: "\\bcounted\\b", options: [.regularExpression, .caseInsensitive]),
                             "\(kind): \(sentence)")
                XCTAssertEqual(StockPlaceWordCheck.violations(sentence, kind: kind), [], "\(kind): \(sentence)")
            }
            XCTAssertTrue(said[0].contains("in Sample System"))
        }
    }

    func testTheTimeStyle() {
        let composer = composer()
        XCTAssertEqual(composer.time(S.date(2026, 11, 20, 9, 5)), "09:05")
        XCTAssertEqual(composer.time(S.date(2026, 11, 19, 16, 10)), "yesterday at 16:10")
        XCTAssertEqual(composer.time(S.date(2026, 11, 16, 8, 0)), "Monday at 08:00")
        XCTAssertEqual(composer.time(S.date(2026, 11, 2, 8, 0)), "2 November")
        XCTAssertEqual(composer.time(S.date(2025, 12, 31, 8, 0)), "31 December 2025")
    }
}
