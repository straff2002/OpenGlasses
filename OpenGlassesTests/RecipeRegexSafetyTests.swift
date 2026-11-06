import XCTest
@testable import OpenGlasses

/// `NSRegularExpression` has no timeout. Known catastrophic patterns are refused by shape at
/// install, and — run anyway against adversarial input inside the caps — matching stops on the
/// wall-clock budget instead of hanging.
final class RecipeRegexSafetyTests: XCTestCase {

    private let catastrophic = ["(a+)+$", "(a|aa)+$", "(.*a){12}", "(a*)*b", "((ab)*)+c", "(?:a+)+$", "(\\w+\\s?)+$"]

    func testCatastrophicPatternsAreRefusedByShape() {
        for pattern in catastrophic {
            XCTAssertTrue(RecipeRegex.issues(in: pattern, needsCaptureGroup: false).contains(.nestedQuantifier), pattern)
        }
    }

    func testOrdinaryPatternsAreAccepted() {
        for pattern in ["rate=([0-9.]+)", "<title>([^<]{1,100})</title>", "(\\d+)\\s*°C", "(a+)?b",
                        "\"temp\":\\s*(-?\\d+(?:\\.\\d+)?)", "([A-Za-z]+) wins", "(?i)(sunny|rain)"] {
            let issues = RecipeRegex.issues(in: pattern, needsCaptureGroup: true)
            // An alternation is fine unless its group is repeated.
            XCTAssertEqual(issues, [], pattern)
        }
        // A parameter `pattern` needs no capture group; an `extract` regex does.
        XCTAssertEqual(RecipeRegex.issues(in: "^[A-Z]{3}$", needsCaptureGroup: false), [])
        XCTAssertEqual(RecipeRegex.issues(in: "^[A-Z]{3}$", needsCaptureGroup: true), [.noCaptureGroup])
    }

    func testOtherShapeRules() {
        XCTAssertEqual(RecipeRegex.issues(in: "(a)\\1", needsCaptureGroup: true), [.backreference])
        XCTAssertEqual(RecipeRegex.issues(in: "(?<x>a)\\k<x>", needsCaptureGroup: true), [.backreference])
        XCTAssertEqual(RecipeRegex.issues(in: "\\\\1(a)", needsCaptureGroup: true), [], "an escaped backslash then 1 is literal")
        XCTAssertEqual(RecipeRegex.issues(in: "(a{1,1000})", needsCaptureGroup: true), [.repeatTooLarge])
        XCTAssertEqual(RecipeRegex.issues(in: "(a", needsCaptureGroup: true), [.doesNotCompile])
        XCTAssertEqual(RecipeRegex.issues(in: "abc", needsCaptureGroup: true), [.noCaptureGroup])
        XCTAssertEqual(RecipeRegex.issues(in: String(repeating: "a", count: 201), needsCaptureGroup: false), [.tooLong])
        XCTAssertEqual(RecipeRegex.issues(in: "[(a+)+](x)", needsCaptureGroup: true), [], "inside a class, nothing nests")
    }

    /// Run the refused patterns anyway, as an unvalidated file would, on input built to make them
    /// backtrack: each finishes (as a time-out or an answer) well inside a generous bound.
    func testCatastrophicPatternsStopOnTheBudgetAgainstAdversarialInput() throws {
        let adversarial = String(repeating: "a", count: 5_000) + "!"
        for pattern in catastrophic {
            let regex = try NSRegularExpression(pattern: pattern)
            let started = Date()
            let outcome = RecipeRegex.firstCapture(of: regex, in: adversarial, budget: 0.25)
            let took = Date().timeIntervalSince(started)
            XCTAssertLessThan(took, 10, "\(pattern) took \(took)s (outcome \(outcome))")
        }
    }

    func testPolynomialPatternOverAMegabyteStopsOnTheBudget() throws {
        // Not refused by shape — no nested quantifier — but quadratic over a large input.
        let regex = try NSRegularExpression(pattern: "(\\d+)x")
        XCTAssertEqual(RecipeRegex.issues(in: "(\\d+)x", needsCaptureGroup: true), [])
        let input = String(repeating: "1", count: RecipeRegex.maxInputBytes - 1)
        let started = Date()
        let outcome = RecipeRegex.firstCapture(of: regex, in: input, budget: 0.25)
        let took = Date().timeIntervalSince(started)
        XCTAssertLessThan(took, 10, "took \(took)s")
        XCTAssertTrue(outcome == .noMatch || outcome == .timedOut, "no x, so no match: \(outcome)")
    }

    func testBudgetIsMeasuredOnTheInjectedUptime() throws {
        // With an uptime that leaps forward on every progress callback, matching stops at once.
        let regex = try NSRegularExpression(pattern: "(a+)+$")
        var tick: TimeInterval = 0
        let outcome = RecipeRegex.firstCapture(of: regex, in: String(repeating: "a", count: 40) + "!", budget: 1) {
            tick += 10
            return tick
        }
        XCTAssertEqual(outcome, .timedOut)
    }

    func testAMatchWithinBudget() throws {
        let regex = try NSRegularExpression(pattern: "rate=([0-9.]+)")
        XCTAssertEqual(RecipeRegex.firstCapture(of: regex, in: "x rate=1.25 y", budget: 1), .matched("1.25"))
        XCTAssertEqual(RecipeRegex.firstCapture(of: regex, in: "nothing", budget: 1), .noMatch)
    }
}
