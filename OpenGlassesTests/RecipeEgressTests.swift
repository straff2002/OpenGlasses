import XCTest
@testable import OpenGlasses

/// Parameter values pass the egress screen before substitution: a credential blocks the run with
/// nothing sent; other personal data is redacted and the run goes on.
final class RecipeEgressTests: XCTestCase {

    private typealias F = RecipeAddOnFixtures

    /// Credential-shaped values built at run time from a prefix and a filler, so no literal token
    /// sits in the source for a secret scanner to flag.
    private func sample(_ prefix: String, _ bodyLength: Int, _ bodyChar: Character = "a") -> String {
        prefix + String(repeating: bodyChar, count: bodyLength)
    }

    private func run(_ value: String) async throws -> (RecipeRunResult, FakeAddOnHTTPTransport) {
        let m = try F.manifest(skills: [F.skill(
            parameters: ["q": ["type": "string", "maxLength": 200]],
            steps: [["http": ["url": "https://api.example.org/search?q={{q}}", "as": "r"]], ["say": "Searched {{q}}."]])])
        let transport = FakeAddOnHTTPTransport(json: "{}")
        let result = await RecipeRunner(transport: transport, clock: FakeAddOnClock())
            .run(m, skill: "look_up", arguments: ["q": value], context: F.context)
        return (result, transport)
    }

    func testASecretInAParameterBlocksTheRun() async throws {
        for (name, secret) in [("openai_key", sample("sk-ant-", 24)), ("github_token", sample("ghp_", 36)),
                               ("aws_access_key_id", sample("AKIA", 16, "A")), ("bearer_token", "Bearer " + sample("", 24))] {
            let (result, transport) = try await run("look up \(secret) please")
            XCTAssertEqual(result.outcome, .blockedCredential([name]), name)
            XCTAssertTrue(transport.requests.isEmpty, "nothing is sent: \(name)")
            XCTAssertEqual(result.spokenText, "")
        }
    }

    func testPersonalDataIsRedactedAndTheRunContinues() async throws {
        let (result, transport) = try await run("mail jo@example.org")
        XCTAssertEqual(result.outcome, .completed)
        let url = try XCTUnwrap(transport.requests.first?.url.absoluteString)
        XCTAssertFalse(url.contains("example.org%40") || url.contains("jo%40example"), url)
        let q = URLComponents(string: url)?.queryItems?.first?.value
        XCTAssertEqual(q, "mail " + SecretPatterns.redactionPlaceholder)
        XCTAssertEqual(result.spokenText, "Searched mail \(SecretPatterns.redactionPlaceholder).")
    }

    func testCleanValuesPassUnchanged() async throws {
        let (result, transport) = try await run("weather in Wellington")
        XCTAssertEqual(result.outcome, .completed)
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(transport.requests.first?.url), resolvingAgainstBaseURL: false)?
            .queryItems?.first?.value, "weather in Wellington")
    }

    func testScreenSeparatesCredentialsFromOtherHits() {
        XCTAssertEqual(RecipeArguments.screen(["a": "plain"]), .passed(["a": "plain"]))
        XCTAssertEqual(RecipeArguments.screen(["a": "id 12-345-678"]), .passed(["a": "id \(SecretPatterns.redactionPlaceholder)"]))
        XCTAssertEqual(RecipeArguments.screen(["a": "x@example.org", "b": sample("ghp_", 30)]), .blocked(["github_token"]))
    }
}
