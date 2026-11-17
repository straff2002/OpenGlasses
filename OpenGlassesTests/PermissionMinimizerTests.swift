import XCTest
@testable import OpenGlasses

/// Permissions are recomputed from the steps, never taken from the draft.
final class PermissionMinimizerTests: XCTestCase {

    private func manifest(steps: [[String: Any]], permissions: [String: Any] = [:]) throws -> RecipeAddOnManifest {
        let data = RecipeAddOnFixtures.file(skills: [[
            "name": "tide", "description": "Use when the wearer asks for the tide.",
            "parameters": ["place": ["type": "string", "required": true]],
            "steps": steps,
        ]], permissions: permissions)
        return try RecipeAddOnManifest.decode(data)
    }

    private func get(_ url: String, as name: String = "r") -> [String: Any] {
        ["http": ["method": "GET", "url": url, "as": name]]
    }

    func testNetworkIsExactlyTheLiteralHosts() throws {
        let m = try manifest(steps: [
            get("https://tides.example.net/v1/next?place={{place}}"),
            ["if": ["op": "empty", "var": "r", "then": [get("https://backup.example.org/next?q={{place}}", as: "b"), ["say": "{{b}}"]],
                    "else": [["say": "{{r}}"]]]],
        ])
        let outcome = try PermissionMinimizer.minimise(m).get()
        XCTAssertEqual(outcome.permissions.network, ["backup.example.org", "tides.example.net"])
        XCTAssertFalse(outcome.permissions.location)
        XCTAssertFalse(outcome.permissions.memory)
        XCTAssertFalse(outcome.permissions.display)
        XCTAssertTrue(outcome.permissions.reserved.isEmpty)
    }

    func testExtrasAreStrippedAndMissingHostsAdded() throws {
        let m = try manifest(steps: [get("https://API.Example.org/v1?q={{place}}"), ["say": "{{r}}"]],
                             permissions: ["network": ["api.example.org", "evil.example.com"], "location": true,
                                           "memory": true, "display": true])
        let outcome = try PermissionMinimizer.minimise(m).get()
        XCTAssertEqual(outcome.permissions.network, ["api.example.org"])
        XCTAssertEqual(outcome.removedDomains, ["evil.example.com"])
        XCTAssertEqual(outcome.addedDomains, [])
        XCTAssertEqual(outcome.removedPermissions, ["location", "memory", "display"])
        XCTAssertFalse(outcome.permissions.location || outcome.permissions.memory || outcome.permissions.display)

        let missing = try manifest(steps: [get("https://tides.example.net/x"), ["say": "{{r}}"]])
        XCTAssertEqual(try PermissionMinimizer.minimise(missing).get().addedDomains, ["tides.example.net"])
    }

    func testATemplatedHostIsRefused() throws {
        for url in ["https://{{place}}.example.org/x", "{{place}}/x", "https://tides.example.net{{place}}"] {
            let m = try manifest(steps: [get(url), ["say": "{{r}}"]])
            guard case .failure(let refusal) = PermissionMinimizer.minimise(m) else { return XCTFail(url) }
            if case .templatedHost(let path) = refusal {
                XCTAssertEqual(path, "skills[0].steps[0].http.url")
            } else if case .invalidURL = refusal {
                // A host glued to a variable doesn't parse as a host at all: refused either way.
            } else {
                XCTFail("\(url): \(refusal)")
            }
        }
    }

    func testPlainHTTPAndPortsAndIPsAreRefused() throws {
        for url in ["http://tides.example.net/x", "https://tides.example.net:8443/x", "https://192.168.1.10/x",
                    "https://user@tides.example.net/x"] {
            let m = try manifest(steps: [get(url), ["say": "{{r}}"]])
            guard case .failure(.invalidURL) = PermissionMinimizer.minimise(m) else { return XCTFail(url) }
        }
    }

    func testLocationVariablesAreDetectedWhereverTheyAppear() throws {
        let inURL = try manifest(steps: [get("https://tides.example.net/x?lat={{lat}}&lon={{lon}}"), ["say": "{{r}}"]])
        XCTAssertTrue(try PermissionMinimizer.minimise(inURL).get().permissions.location)
        let inSay = try manifest(steps: [get("https://tides.example.net/x"), ["say": "Near {{city}}: {{r}}"]])
        XCTAssertTrue(try PermissionMinimizer.minimise(inSay).get().permissions.location)
        let inIf = try manifest(steps: [get("https://tides.example.net/x"),
                                        ["if": ["op": "equals", "var": "country", "value": "NZ",
                                                "then": [["say": "{{r}}"]], "else": [["say": "no"]]]]])
        let outcome = try PermissionMinimizer.minimise(inIf).get()
        XCTAssertTrue(outcome.permissions.location)
        XCTAssertEqual(outcome.addedPermissions, ["location"])
    }

    func testMemoryAndDisplayOnlyWithTheirSteps() throws {
        let m = try manifest(steps: [
            get("https://tides.example.net/x"),
            ["remember": ["key": "last_tide", "value": "{{r}}"]],
            ["display": ["kind": "text", "title": "Tide", "items": ["{{r}}"]]],
            ["say": "{{r}}"],
        ])
        let outcome = try PermissionMinimizer.minimise(m).get()
        XCTAssertTrue(outcome.permissions.memory)
        XCTAssertTrue(outcome.permissions.display)
        XCTAssertEqual(Set(outcome.addedPermissions), ["memory", "display"])
    }

    func testAnAddOnThatCallsNothingIsRefused() throws {
        let m = try manifest(steps: [["say": "Hello {{place}}"]])
        XCTAssertEqual(PermissionMinimizer.minimise(m), .failure(.noService))
    }

    func testTheMinimisedSetWritesBackAsJSON() {
        let permissions = RecipeAddOnManifest.Permissions(network: ["tides.example.net"], location: true,
                                                          memory: false, display: false)
        let object = PermissionMinimizer.jsonObject(permissions)
        XCTAssertEqual(object["network"] as? [String], ["tides.example.net"])
        XCTAssertEqual(object["location"] as? Bool, true)
        XCTAssertNil(object["memory"])
    }
}
