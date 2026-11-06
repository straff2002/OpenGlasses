import XCTest
@testable import OpenGlasses

/// Recipe add-on file format: the worked example decodes, and every strictness rule refuses —
/// unknown keys at each level, the format tag, skills-or-mcp, step shapes.
final class RecipeAddOnManifestTests: XCTestCase {

    private typealias F = RecipeAddOnFixtures

    private func decodeError(_ data: Data, file: StaticString = #filePath, line: UInt = #line) -> RecipeAddOnDecodeError? {
        do {
            _ = try RecipeAddOnManifest.decode(data)
            XCTFail("expected a decode error", file: file, line: line)
            return nil
        } catch let error as RecipeAddOnDecodeError {
            return error
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
            return nil
        }
    }

    private func json(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private func root(_ data: Data) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    private let sayHi: [[String: Any]] = [["say": "Hi."]]

    // MARK: - The worked example

    func testCurrencyExampleDecodes() throws {
        let m = F.currencyManifest
        XCTAssertEqual(m.format, "avenkin.addon/1")
        XCTAssertEqual(m.id, "dev.frankfurter.currency")
        XCTAssertEqual(m.author.web, "https://example.org")
        XCTAssertEqual(m.icon, "dollarsign.arrow.circlepath")
        XCTAssertEqual(m.coverage, ["*"])
        XCTAssertFalse(m.slow)
        XCTAssertEqual(m.permissions, .init(network: ["api.frankfurter.dev"], location: false, memory: false, display: false))
        XCTAssertNil(m.mcp)
        let skill = try XCTUnwrap(m.skills.first)
        XCTAssertEqual(skill.name, "convert_currency")
        XCTAssertEqual(skill.parameters.map(\.name), ["amount", "from", "to"])
        let amount = try XCTUnwrap(skill.parameters.first { $0.name == "amount" })
        XCTAssertEqual(amount.kind, .number)
        XCTAssertTrue(amount.required)
        XCTAssertEqual(amount.min, 0)
        XCTAssertEqual(amount.max, 1_000_000_000)
        XCTAssertEqual(skill.parameters.first { $0.name == "from" }?.pattern, "^[A-Z]{3}$")
        XCTAssertEqual(skill.steps.count, 3)
        guard case .http(let h) = skill.steps[0], case .extract(let e) = skill.steps[1], case .when(let w) = skill.steps[2] else {
            return XCTFail("step kinds")
        }
        XCTAssertEqual(h.method, "GET")
        XCTAssertEqual(h.as, "fx")
        XCTAssertEqual(e.jsonpath, "$.rates.{{to}}")
        XCTAssertEqual(w.op, "empty")
        XCTAssertEqual(w.then, [.say("I couldn't find a rate for {{to}}.")])
        XCTAssertEqual(w.else, [.say("{{amount}} {{from}} is {{result}} {{to}}.")])
    }

    func testDefaultsWhenOptionalFieldsAreAbsent() throws {
        let m = try F.manifest(skills: [F.skill(steps: sayHi)], permissions: [:])
        XCTAssertEqual(m.permissions, .empty)
        XCTAssertNil(m.icon)
        XCTAssertNil(m.coverage)
        XCTAssertFalse(m.slow)
        XCTAssertNil(m.author.web)
        XCTAssertEqual(m.skills.first?.parameters, [])
    }

    func testEveryStepKindDecodes() throws {
        let steps: [[String: Any]] = [
            ["http": ["method": "POST", "url": "https://api.example.org/x", "as": "r",
                      "headers": ["Accept-Language": "en"], "json": ["q": "{{q}}", "n": 2, "ok": true, "z": NSNull(), "list": [1, "a"]]]],
            ["extract": ["from": "r", "regex": "id=(\\d+)", "as": "id", "fallback": "none", "limit": 2]],
            ["remember": ["key": "last", "value": "{{id}}"]],
            ["display": ["kind": "markers", "title": "Here", "markers": [["lat": 51.5, "lon": "{{id}}", "label": "A"]]]],
            ["say": "Done."],
        ]
        let m = try F.manifest(skills: [F.skill(parameters: ["q": ["type": "string"]], steps: steps)])
        let decoded = m.skills[0].steps
        guard case .http(let h) = decoded[0] else { return XCTFail() }
        XCTAssertEqual(h.json, .object(["q": .string("{{q}}"), "n": .number(2), "ok": .bool(true), "z": .null,
                                        "list": .array([.number(1), .string("a")])]))
        XCTAssertEqual(h.headers, ["Accept-Language": "en"])
        guard case .extract(let e) = decoded[1] else { return XCTFail() }
        XCTAssertEqual(e.regex, "id=(\\d+)")
        XCTAssertEqual(e.limit, 2)
        XCTAssertEqual(decoded[2], .remember(.init(key: "last", value: "{{id}}")))
        guard case .display(let d) = decoded[3] else { return XCTFail() }
        XCTAssertEqual(d.markers, [.init(lat: "51.5", lon: "{{id}}", label: "A")])
        XCTAssertEqual(decoded[4], .say("Done."))
    }

    func testMCPEntryDecodes() throws {
        var r = root(F.file(skills: []))
        r.removeValue(forKey: "skills")
        r["mcp"] = ["url": "https://mcp.example.org/sse", "auth": "header", "header": "X-API-Key"]
        let m = try RecipeAddOnManifest.decode(json(r))
        XCTAssertEqual(m.mcp, .init(url: "https://mcp.example.org/sse", auth: "header", header: "X-API-Key"))
        XCTAssertEqual(m.skills, [])
    }

    // MARK: - Refusals

    func testWrongFormatTagIsRefused() {
        for tag in ["avenkin.addon/2", "openglasses.addon/1", "Avenkin.addon/1", ""] {
            let data = F.file(skills: [F.skill(steps: sayHi)], overrides: ["format": tag])
            XCTAssertEqual(decodeError(data), .unsupportedFormat(tag), tag)
        }
    }

    func testUnknownTopLevelKeyIsRefused() {
        let data = F.file(skills: [F.skill(steps: sayHi)], overrides: ["permision": ["network": ["x.org"]]])
        XCTAssertEqual(decodeError(data), .unknownKey(path: "", key: "permision"))
    }

    func testUnknownPermissionIsRefusedNotIgnored() {
        // A typo, and a capability the community format doesn't have, both refuse the file.
        for key in ["netwrok", "contacts", "credentials", "camera"] {
            let data = F.file(skills: [F.skill(steps: sayHi)], permissions: [key: true])
            XCTAssertEqual(decodeError(data), .unknownKey(path: "permissions", key: key), key)
        }
    }

    func testUnknownKeysInNestedObjectsAreRefused() {
        let author = F.file(skills: [F.skill(steps: sayHi)], overrides: ["author": ["name": "A", "email": "a@b.c"]])
        XCTAssertEqual(decodeError(author), .unknownKey(path: "author", key: "email"))

        let param = F.file(skills: [F.skill(parameters: ["q": ["type": "string", "maxLen": 5]], steps: sayHi)])
        XCTAssertEqual(decodeError(param), .unknownKey(path: "skills[0].parameters.q", key: "maxLen"))

        var skill = F.skill(steps: sayHi)
        skill["timeout"] = 5
        XCTAssertEqual(decodeError(F.file(skills: [skill])), .unknownKey(path: "skills[0]", key: "timeout"))

        let http = F.file(skills: [F.skill(steps: [["http": ["url": "https://api.example.org", "as": "r", "follow": true]], ["say": "x"]])])
        XCTAssertEqual(decodeError(http), .unknownKey(path: "skills[0].steps[0].http", key: "follow"))

        let ifStep = F.file(skills: [F.skill(steps: [["if": ["op": "empty", "var": "x", "then": sayHi, "otherwise": sayHi]]])])
        XCTAssertEqual(decodeError(ifStep), .unknownKey(path: "skills[0].steps[0].if", key: "otherwise"))

        var r = root(F.file(skills: []))
        r.removeValue(forKey: "skills")
        r["mcp"] = ["url": "https://mcp.example.org", "token": "abc"]
        XCTAssertEqual(decodeError(json(r)), .unknownKey(path: "mcp", key: "token"))
    }

    func testUnknownStepKindIsRefused() {
        let data = F.file(skills: [F.skill(steps: [["shell": "ls"]])])
        XCTAssertEqual(decodeError(data), .unknownKey(path: "skills[0].steps[0]", key: "shell"))
    }

    func testAStepHasExactlyOneKind() {
        let two = F.file(skills: [F.skill(steps: [["say": "a", "remember": ["key": "k", "value": "v"]]])])
        guard case .invalidStep(let path, _) = decodeError(two) else { return XCTFail() }
        XCTAssertEqual(path, "skills[0].steps[0]")
        let none = F.file(skills: [F.skill(steps: [[:]])])
        guard case .invalidStep = decodeError(none) else { return XCTFail() }
    }

    func testSkillsAndMCPAreExclusive() {
        let both = F.file(skills: [F.skill(steps: sayHi)], overrides: ["mcp": ["url": "https://api.example.org"]])
        XCTAssertEqual(decodeError(both), .bothSkillsAndMCP)
        var r = root(F.file(skills: []))
        r.removeValue(forKey: "skills")
        XCTAssertEqual(decodeError(json(r)), .neitherSkillsNorMCP)
    }

    func testParameterTypeMustBeKnown() {
        let data = F.file(skills: [F.skill(parameters: ["q": ["type": "object"]], steps: sayHi)])
        guard case .malformed(let path, _) = decodeError(data) else { return XCTFail() }
        XCTAssertEqual(path, "skills[0].parameters.q")
    }

    func testWrongValueTypesAreMalformed() {
        let slow = F.file(skills: [F.skill(steps: sayHi)], overrides: ["slow": "yes"])
        guard case .malformed = decodeError(slow) else { return XCTFail() }
        let location = F.file(skills: [F.skill(steps: sayHi)], permissions: ["location": "true"])
        guard case .malformed(let path, _) = decodeError(location) else { return XCTFail() }
        XCTAssertTrue(path.hasPrefix("permissions"), path)
        guard case .malformed = decodeError(Data("{ not json".utf8)) else { return XCTFail() }
        let missingID = root(F.file(skills: [F.skill(steps: sayHi)])).filter { $0.key != "id" }
        guard case .malformed(_, let reason) = decodeError(json(missingID)) else { return XCTFail() }
        XCTAssertTrue(reason.contains("id"))
    }

    func testDecodeErrorsReadAsSentences() {
        XCTAssertTrue(RecipeAddOnDecodeError.unknownKey(path: "permissions", key: "netwrok").message.contains("netwrok"))
        XCTAssertTrue(RecipeAddOnDecodeError.unsupportedFormat("x").message.contains("avenkin.addon/1"))
    }
}
