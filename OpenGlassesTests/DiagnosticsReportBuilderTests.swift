import XCTest
@testable import OpenGlasses

final class DiagnosticsReportBuilderTests: XCTestCase {

    private func snapshot(
        logTail: [String] = [],
        selfTest: [String] = [],
        connected: Bool = true
    ) -> DiagnosticsSnapshot {
        DiagnosticsSnapshot(
            appVersion: "2026.7",
            buildNumber: "306",
            systemName: "iOS",
            systemVersion: "26.1",
            deviceModel: "iPhone17,1",
            localeIdentifier: "en_NZ",
            glassesConnected: connected,
            glassesName: connected ? "Ray-Ban Meta" : nil,
            glassesBatteryPercent: connected ? 82 : nil,
            hasDisplayCapability: connected,
            activeModelName: "Test Model",
            logTail: logTail,
            selfTestSummary: selfTest
        )
    }

    /// The body of the prefilled issue URL, decoded back out of the query.
    private func decodedURLBody(_ report: DiagnosticsReport) -> String {
        let components = URLComponents(url: report.issueURL, resolvingAgainstBaseURL: false)
        let item = components?.queryItems?.first { $0.name == "body" }
        return item?.value ?? ""
    }

    // MARK: - Context

    func testBodyCarriesDeviceAndAppContext() {
        let report = DiagnosticsReportBuilder.build(snapshot())

        XCTAssertTrue(report.body.contains("2026.7 (306)"))
        XCTAssertTrue(report.body.contains("iOS 26.1"))
        XCTAssertTrue(report.body.contains("iPhone17,1"))
        XCTAssertTrue(report.body.contains("en_NZ"))
        XCTAssertTrue(report.body.contains("Connected — Ray-Ban Meta · 82%"))
        XCTAssertTrue(report.body.contains("Test Model"))
        XCTAssertEqual(report.title, "Bug report — OpenGlasses 2026.7 (306)")
    }

    func testDisconnectedGlassesReportedAsSuch() {
        let report = DiagnosticsReportBuilder.build(snapshot(connected: false))

        XCTAssertTrue(report.body.contains("| Glasses | Not connected |"))
        XCTAssertTrue(report.body.contains("| Display | None |"))
        XCTAssertFalse(report.body.contains("82%"))
    }

    func testEmptyLogStillProducesAValidReport() {
        let report = DiagnosticsReportBuilder.build(snapshot())

        XCTAssertTrue(report.body.contains("_No debug events recorded._"))
        XCTAssertEqual(report.includedLogLines, 0)
        XCTAssertEqual(report.omittedLogLines, 0)
        XCTAssertEqual(report.issueURL.host, "github.com")
    }

    func testSelfTestSectionOnlyAppearsWhenProbesRan() {
        let without = DiagnosticsReportBuilder.build(snapshot())
        XCTAssertFalse(without.body.contains("## Self-test"))

        let with = DiagnosticsReportBuilder.build(
            snapshot(selfTest: ["PASS — Glasses Link: Ray-Ban Meta (0.1s)"])
        )
        XCTAssertTrue(with.body.contains("## Self-test"))
        XCTAssertTrue(with.body.contains("- PASS — Glasses Link"))
    }

    // MARK: - Log tail

    func testLogTailKeepsTheNewestLinesOnly() {
        let lines = (1...200).map { "[12:00:00] event \($0)" }
        let report = DiagnosticsReportBuilder.build(snapshot(logTail: lines))

        XCTAssertTrue(report.body.contains("event 200"))
        XCTAssertTrue(report.body.contains("event 141"))   // 200 - 60 + 1
        XCTAssertFalse(report.body.contains("event 140"))
    }

    func testLogTailPreservesOrderOldestFirst() {
        let report = DiagnosticsReportBuilder.build(snapshot(logTail: ["first", "second", "third"]))
        guard let firstIndex = report.body.range(of: "first"),
              let thirdIndex = report.body.range(of: "third") else {
            return XCTFail("expected both log lines in the body")
        }
        XCTAssertLessThan(firstIndex.lowerBound, thirdIndex.lowerBound)
    }

    // MARK: - Redaction

    func testPlantedSecretLookalikesNeverReachTheReport() {
        let planted: [(line: String, secret: String)] = [
            ("[10:00:00] auth header sk-proj-AbCdEfGhIjKlMnOp0123456789", "sk-proj-AbCdEfGhIjKlMnOp0123456789"),
            ("[10:00:01] pushing with ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345", "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345"),
            ("[10:00:02] gemini AIzaSyA12345678901234567890123456789012", "AIzaSyA12345678901234567890123456789012"),
            ("[10:00:03] Authorization: Bearer abcdefghijklmnopqrstuvwxyz", "abcdefghijklmnopqrstuvwxyz"),
            ("[10:00:04] request api_key=HUNTER2HUNTER2HUNTER2", "HUNTER2HUNTER2HUNTER2"),
            ("[10:00:05] Stream key: live-9f2b-7c41-abcd", "live-9f2b-7c41-abcd"),
            ("[10:00:06] contact wearer@example.com about it", "wearer@example.com"),
        ]

        let report = DiagnosticsReportBuilder.build(snapshot(logTail: planted.map(\.line)))
        let urlBody = decodedURLBody(report)

        for entry in planted {
            XCTAssertFalse(report.body.contains(entry.secret), "leaked \(entry.secret) into the body")
            XCTAssertFalse(urlBody.contains(entry.secret), "leaked \(entry.secret) into the URL")
        }
        XCTAssertTrue(report.body.contains(SecretPatterns.redactionPlaceholder))
        XCTAssertFalse(report.redactionHits.isEmpty)
    }

    func testConfiguredSecretsAreScrubbedByLiteralMatch() {
        // A key with no recognisable shape — only the caller knows it is a secret.
        let key = "zq7-plain-looking-value"
        let report = DiagnosticsReportBuilder.build(
            snapshot(logTail: ["[10:00:00] broadcasting to rtmp://example/\(key)"]),
            redacting: [key]
        )

        XCTAssertFalse(report.body.contains(key))
        XCTAssertFalse(decodedURLBody(report).contains(key))
        XCTAssertTrue(report.redactionHits.contains("configured_secret"))
    }

    func testShortConfiguredValuesAreNotUsedAsRedactionMasks() {
        // An unset or trivially short secret must not blanket-mask ordinary log text.
        let report = DiagnosticsReportBuilder.build(
            snapshot(logTail: ["[10:00:00] ok"]),
            redacting: ["", "ok"]
        )

        XCTAssertTrue(report.body.contains("[10:00:00] ok"))
        XCTAssertFalse(report.redactionHits.contains("configured_secret"))
    }

    func testRedactionKeepsTheLabelSoTheReaderSeesWhatWasMasked() {
        let report = DiagnosticsReportBuilder.build(
            snapshot(logTail: ["[10:00:00] token = SUPERSECRETVALUE123"])
        )

        XCTAssertTrue(report.body.contains("token = "))
        XCTAssertFalse(report.body.contains("SUPERSECRETVALUE123"))
    }

    func testOrdinaryLogLinesSurviveRedactionUnchanged() {
        let line = "[10:00:00] Wake word heard, starting turn (camera warm)"
        let report = DiagnosticsReportBuilder.build(snapshot(logTail: [line]))

        XCTAssertTrue(report.body.contains(line))
        XCTAssertTrue(report.redactionHits.isEmpty)
    }

    func testRedactorIsIdempotent() {
        let once = DiagnosticsRedactor.redact("api_key=ABCDEFGHIJKL").redacted
        let twice = DiagnosticsRedactor.redact(once).redacted
        XCTAssertEqual(once, twice)
    }

    // MARK: - URL

    func testURLTargetsTheProjectIssueTrackerWithBothParameters() {
        let report = DiagnosticsReportBuilder.build(snapshot(logTail: ["[10:00:00] hello"]))
        let url = report.issueURL.absoluteString

        XCTAssertTrue(url.hasPrefix("https://github.com/straff2002/OpenGlasses/issues/new?"))
        XCTAssertTrue(url.contains("title="))
        XCTAssertTrue(url.contains("&body="))
        XCTAssertTrue(decodedURLBody(report).contains("[10:00:00] hello"))
    }

    func testURLEncodesCharactersThatWouldBreakAQuery() {
        let report = DiagnosticsReportBuilder.build(
            snapshot(logTail: ["[10:00:00] a&b=c #d +e /f?g"])
        )
        let raw = report.issueURL.absoluteString

        // The markdown headings alone guarantee an encoded '#'; the log line adds the rest.
        XCTAssertFalse(raw.contains("#"))
        XCTAssertTrue(raw.contains("%20"))
        XCTAssertTrue(raw.contains("%0A"))          // newlines survive as encoded breaks
        XCTAssertTrue(decodedURLBody(report).contains("a&b=c #d +e /f?g"))
    }

    func testLongLogIsTruncatedToFitTheURLButNotTheFullBody() {
        let line = String(repeating: "x", count: 400)
        let lines = (1...60).map { "[10:00:00] \($0) \(line)" }
        let report = DiagnosticsReportBuilder.build(snapshot(logTail: lines))

        XCTAssertLessThanOrEqual(report.issueURL.absoluteString.count, DiagnosticsReportBuilder.maxURLLength)
        XCTAssertGreaterThan(report.omittedLogLines, 0)
        XCTAssertEqual(report.includedLogLines + report.omittedLogLines, 60)
        XCTAssertTrue(decodedURLBody(report).contains("earlier line"))

        // The copy/share body keeps everything the tail had.
        XCTAssertTrue(report.body.contains("[10:00:00] 1 "))
        XCTAssertTrue(report.body.contains("[10:00:00] 60 "))
        XCTAssertFalse(report.body.contains("earlier line"))
    }

    func testTruncationDropsTheOldestLinesFirst() {
        let line = String(repeating: "y", count: 400)
        let lines = (1...60).map { "[10:00:00] \($0) \(line)" }
        let urlBody = decodedURLBody(DiagnosticsReportBuilder.build(snapshot(logTail: lines)))

        XCTAssertTrue(urlBody.contains("[10:00:00] 60 "))
        XCTAssertFalse(urlBody.contains("[10:00:00] 1 y"))
    }

    func testAbsurdlySmallLimitStillYieldsAUsableURL() {
        let report = DiagnosticsReportBuilder.build(
            snapshot(logTail: ["[10:00:00] hello"]),
            urlLimit: 300
        )

        XCTAssertLessThanOrEqual(report.issueURL.absoluteString.count, 300)
        XCTAssertEqual(report.includedLogLines, 0)
        XCTAssertEqual(report.issueURL.host, "github.com")
    }

    // MARK: - Determinism

    func testBuildIsDeterministic() {
        let input = snapshot(logTail: ["[10:00:00] a", "[10:00:01] b"], selfTest: ["PASS — TTS: Spoken"])
        XCTAssertEqual(
            DiagnosticsReportBuilder.build(input),
            DiagnosticsReportBuilder.build(input)
        )
    }

    // MARK: - Shape

    /// A report is only ever these sections — the guard against a future field
    /// quietly adding conversation, location, or memory content to it.
    func testSectionsAreExactlyTheDeclaredOnes() {
        let report = DiagnosticsReportBuilder.build(
            snapshot(logTail: ["[10:00:00] a"], selfTest: ["PASS — TTS: Spoken"])
        )
        let headings = report.body.split(separator: "\n").filter { $0.hasPrefix("## ") }.map(String.init)

        XCTAssertEqual(headings, [
            "## What happened?", "## Steps to reproduce", "## Device & app",
            "## Self-test", "## Recent log",
        ])
    }

    func testDeviceTableCarriesExactlyTheDeclaredFacts() {
        let report = DiagnosticsReportBuilder.build(snapshot())
        let labels = report.body.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("| "), line != "| | |" else { return nil }
            return line.split(separator: "|").first?.trimmingCharacters(in: .whitespaces)
        }

        XCTAssertEqual(labels, ["App", "System", "Device", "Locale", "Glasses", "Display", "Model"])
    }
}
