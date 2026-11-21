import XCTest
@testable import OpenGlasses

/// Plan MQ P0: the compact schema shared by Apple's on-device model and the downloaded models, its
/// local rendering, and argument coercion. The Apple path's own conversion is covered, unchanged, by
/// `AppleToolSchemaTests` and `AppleToolBridgeTests`; these prove the two paths read one tree.
@MainActor
final class OnDeviceToolSchemaTests: XCTestCase {

    private var previousEntitlement: FieldAssistEntitlementProvider!
    private var previousEnabled: Any?

    /// The registry hands out Field Assist tools only while Field Assist is active, and the parity
    /// check should cover them too.
    override func setUp() {
        super.setUp()
        previousEnabled = UserDefaults.standard.object(forKey: "fieldAssistEnabled")
        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
        previousEntitlement = EntitlementTestScope.grant()
    }

    override func tearDown() {
        if let previousEnabled { UserDefaults.standard.set(previousEnabled, forKey: "fieldAssistEnabled") }
        else { UserDefaults.standard.removeObject(forKey: "fieldAssistEnabled") }
        EntitlementTestScope.restore(previousEntitlement)
        super.tearDown()
    }

    private func registry() -> NativeToolRegistry {
        NativeToolRegistry(locationService: LocationService())
    }

    // MARK: - Parity with the Apple path

    func testTheApplePathReadsTheSharedType() {
        XCTAssertTrue(AppleToolSchema.self == OnDeviceToolSchema.self,
                      "the Apple path must read the shared schema, not a copy that can drift")
    }

    /// For every registered tool, the local rendering says what Apple's tree says: the same
    /// properties, types, required set, choices and condensed descriptions, down to the depth both
    /// render.
    func testTheLocalRenderingMatchesTheAppleTreeForEveryRegisteredTool() throws {
        let tools = registry()
        XCTAssertGreaterThan(tools.toolNames.count, 50)
        for name in tools.toolNames {
            let tool = try XCTUnwrap(tools.tool(named: name))
            let appleRoot = AppleToolSchema.root(toolName: name, parameters: tool.parametersSchema)
            let local = OnDeviceToolSchema.localParameters(appleRoot)
            assertMatches(local, appleRoot, depth: 1, path: name)
        }
    }

    private func assertMatches(_ local: [String: Any], _ node: OnDeviceToolSchema.Node, depth: Int,
                               path: String, file: StaticString = #filePath, line: UInt = #line) {
        let type = local["type"] as? String
        XCTAssertNotNil(type, "\(path) has no type", file: file, line: line)
        if depth > OnDeviceToolSchema.localMaxDepth, node.isContainer {
            XCTAssertEqual(type, "string", "\(path) should be flattened to text", file: file, line: line)
            return
        }
        switch node {
        case .string(let choices):
            XCTAssertEqual(type, "string", path, file: file, line: line)
            XCTAssertEqual(local["enum"] as? [String], choices, path, file: file, line: line)
        case .integer: XCTAssertEqual(type, "integer", path, file: file, line: line)
        case .number: XCTAssertEqual(type, "number", path, file: file, line: line)
        case .boolean: XCTAssertEqual(type, "boolean", path, file: file, line: line)
        case .array(let item):
            XCTAssertEqual(type, "array", path, file: file, line: line)
            let items = local["items"] as? [String: Any] ?? [:]
            assertMatches(items, item, depth: depth + 1, path: path + "[]", file: file, line: line)
        case .object(_, _, let properties):
            XCTAssertEqual(type, "object", path, file: file, line: line)
            let rendered = local["properties"] as? [String: Any] ?? [:]
            XCTAssertEqual(Set(rendered.keys), Set(properties.map(\.name)), path, file: file, line: line)
            let required = Set(local["required"] as? [String] ?? [])
            XCTAssertEqual(required, Set(properties.filter { !$0.isOptional }.map(\.name)), path,
                           file: file, line: line)
            for property in properties {
                let child = rendered[property.name] as? [String: Any] ?? [:]
                if depth + 1 <= OnDeviceToolSchema.localMaxDepth || !property.node.isContainer {
                    XCTAssertEqual(child["description"] as? String, property.description,
                                   "\(path).\(property.name) description", file: file, line: line)
                }
                assertMatches(child, property.node, depth: depth + 1, path: "\(path).\(property.name)",
                              file: file, line: line)
            }
        }
    }

    func testEveryRegisteredToolRendersWithinTheDepthLimitAndATypeOnEveryNode() throws {
        let tools = registry()
        for name in tools.toolNames {
            let tool = try XCTUnwrap(tools.tool(named: name))
            let local = OnDeviceToolSchema.localParameters(
                OnDeviceToolSchema.root(toolName: name, parameters: tool.parametersSchema))
            XCTAssertLessThanOrEqual(depth(of: local), OnDeviceToolSchema.localMaxDepth, name)
            XCTAssertTrue(everyNodeTyped(local), "\(name) has a node without a type")
            XCTAssertTrue(JSONSerialization.isValidJSONObject(local), name)
        }
    }

    private func depth(of schema: [String: Any]) -> Int {
        switch schema["type"] as? String {
        case "object":
            let children = (schema["properties"] as? [String: Any] ?? [:]).values.compactMap { $0 as? [String: Any] }
            return 1 + (children.map(depth(of:)).filter { $0 > 0 }.max() ?? 0)
        case "array":
            return 1 + depth(of: schema["items"] as? [String: Any] ?? [:])
        default:
            return 0
        }
    }

    private func everyNodeTyped(_ schema: [String: Any]) -> Bool {
        guard schema["type"] is String else { return false }
        if let properties = schema["properties"] as? [String: Any] {
            return properties.values.allSatisfy { ($0 as? [String: Any]).map(everyNodeTyped) ?? false }
        }
        if let items = schema["items"] as? [String: Any] { return everyNodeTyped(items) }
        return true
    }

    func testANestedObjectPastTheLimitBecomesTextHoldingJSON() {
        let root = OnDeviceToolSchema.root(toolName: "t", parameters: [
            "type": "object",
            "properties": [
                "outer": [
                    "type": "object",
                    "properties": [
                        "inner": ["type": "object", "properties": ["z": ["type": "string"]]],
                        "list": ["type": "array", "items": ["type": "integer"]],
                        "count": ["type": "integer"],
                    ],
                ],
            ],
        ])
        let local = OnDeviceToolSchema.localParameters(root)
        let outer = (local["properties"] as? [String: Any])?["outer"] as? [String: Any]
        let inner = (outer?["properties"] as? [String: Any])?["inner"] as? [String: Any]
        let list = (outer?["properties"] as? [String: Any])?["list"] as? [String: Any]
        let count = (outer?["properties"] as? [String: Any])?["count"] as? [String: Any]
        XCTAssertEqual(outer?["type"] as? String, "object")
        XCTAssertEqual(inner?["type"] as? String, "string")
        XCTAssertEqual(list?["type"] as? String, "string")
        XCTAssertEqual(count?["type"] as? String, "integer", "a scalar at any depth is itself")
    }

    func testTheToolSpecIsTheFunctionShapeWithACondensedDescription() {
        let long = String(repeating: "Logs a reading. ", count: 60)
        let spec = OnDeviceToolSchema.localToolSpec(name: "reading", description: long,
                                                    parameters: ["type": "object", "properties": [:]])
        XCTAssertEqual(spec["type"] as? String, "function")
        let function = spec["function"] as? [String: Any]
        XCTAssertEqual(function?["name"] as? String, "reading")
        XCTAssertEqual(function?["description"] as? String, OnDeviceToolSchema.toolDescription(long))
        XCTAssertLessThanOrEqual((function?["description"] as? String)?.count ?? .max,
                                 OnDeviceToolSchema.Limits.standard.toolDescription + 1)
        XCTAssertEqual((function?["parameters"] as? [String: Any])?["type"] as? String, "object")
    }

    // MARK: - Coercion

    private let schema = OnDeviceToolSchema.root(toolName: "t", parameters: [
        "type": "object",
        "properties": [
            "count": ["type": "integer"],
            "pressure": ["type": "number"],
            "value": ["type": "string"],
            "flag": ["type": "boolean"],
            "action": ["type": "string", "enum": ["start", "end"]],
            "tags": ["type": "array", "items": ["type": "string"]],
            "where": ["type": "object", "properties": ["floor": ["type": "integer"]], "required": ["floor"]],
        ],
        "required": ["action"],
    ])

    func testANumberWrittenAsTextReadsAsTheNumber() {
        let result = OnDeviceArgumentCoercion.coerce(["action": "start", "count": "42", "pressure": " 4.5 "], to: schema)
        XCTAssertTrue(result.isDispatchable)
        XCTAssertEqual(result.arguments["count"] as? Int, 42)
        XCTAssertEqual(result.arguments["pressure"] as? Double, 4.5)
        XCTAssertEqual(result.coercedCount, 2)
    }

    func testAWholeDoubleReadsAsAnIntegerButAFractionDoesNot() {
        XCTAssertEqual(OnDeviceArgumentCoercion.coerce(["action": "end", "count": 7.0], to: schema)
            .arguments["count"] as? Int, 7)
        let fraction = OnDeviceArgumentCoercion.coerce(["action": "end", "count": 7.5], to: schema)
        XCTAssertEqual(fraction.problems, [.wrongType(path: "count", expected: "integer")])
    }

    func testANumberForAStringReadsAsItsText() {
        let result = OnDeviceArgumentCoercion.coerce(["action": "start", "value": 108], to: schema)
        XCTAssertEqual(result.arguments["value"] as? String, "108")
        XCTAssertEqual(OnDeviceArgumentCoercion.coerce(["action": "start", "value": 0.28], to: schema)
            .arguments["value"] as? String, "0.28")
    }

    func testBooleansReadOnlyFromBooleansOrTheirWords() {
        XCTAssertEqual(OnDeviceArgumentCoercion.coerce(["action": "start", "flag": "TRUE"], to: schema)
            .arguments["flag"] as? Bool, true)
        XCTAssertEqual(OnDeviceArgumentCoercion.coerce(["action": "start", "flag": false], to: schema)
            .arguments["flag"] as? Bool, false)
        XCTAssertFalse(OnDeviceArgumentCoercion.coerce(["action": "start", "flag": 1], to: schema).isDispatchable,
                       "1 is not a boolean: refuse rather than guess")
        XCTAssertFalse(OnDeviceArgumentCoercion.coerce(["action": "start", "flag": "yes"], to: schema).isDispatchable)
    }

    func testABooleanIsNeverReadAsANumber() {
        XCTAssertFalse(OnDeviceArgumentCoercion.coerce(["action": "start", "count": true], to: schema).isDispatchable)
        XCTAssertFalse(OnDeviceArgumentCoercion.coerce(["action": "start", "pressure": false], to: schema).isDispatchable)
    }

    func testAChoiceInTheWrongCaseReadsAsTheChoiceAndAnUnlistedOneIsRefused() {
        XCTAssertEqual(OnDeviceArgumentCoercion.coerce(["action": "Start"], to: schema).arguments["action"] as? String,
                       "start")
        let unlisted = OnDeviceArgumentCoercion.coerce(["action": "stop"], to: schema)
        XCTAssertEqual(unlisted.problems, [.wrongType(path: "action", expected: "one of the listed choices")])
    }

    func testTextThatIsNotAPlainNumberIsRefused() {
        for text in ["45 psi", "about forty", "1,200", "4.5.1", "", "0x10", "1e3"] {
            let result = OnDeviceArgumentCoercion.coerce(["action": "start", "pressure": text], to: schema)
            XCTAssertEqual(result.problems, [.wrongType(path: "pressure", expected: "number")], text)
        }
    }

    func testJSONTextForAContainerIsParsedAndItsFieldsCoerced() {
        let result = OnDeviceArgumentCoercion.coerce(
            ["action": "start", "where": #"{"floor": "3"}"#, "tags": #"["a", "b"]"#], to: schema)
        XCTAssertTrue(result.isDispatchable, "\(result.problems)")
        XCTAssertEqual((result.arguments["where"] as? [String: Any])?["floor"] as? Int, 3)
        XCTAssertEqual(result.arguments["tags"] as? [String], ["a", "b"])
    }

    func testASingleValueForAListBecomesAListOfOne() {
        XCTAssertEqual(OnDeviceArgumentCoercion.coerce(["action": "start", "tags": "urgent"], to: schema)
            .arguments["tags"] as? [String], ["urgent"])
    }

    func testMissingRequiredAndNestedProblemsNameTheirPath() {
        let result = OnDeviceArgumentCoercion.coerce(["where": ["floor": "high"]], to: schema)
        XCTAssertEqual(Set(result.problems.map(\.message)), [
            "Argument 'action' is required.",
            "Argument 'where.floor' must be an integer.",
        ])
        XCTAssertEqual(result.refusalMessage?.hasPrefix("Error: "), true)
    }

    func testNullsAreDroppedAndUndeclaredArgumentsPassThrough() {
        let result = OnDeviceArgumentCoercion.coerce(["action": "start", "count": NSNull(), "extra": "kept"], to: schema)
        XCTAssertTrue(result.isDispatchable)
        XCTAssertNil(result.arguments["count"])
        XCTAssertEqual(result.arguments["extra"] as? String, "kept")
    }

    func testAProblemMessageNeverCarriesTheValue() {
        let result = OnDeviceArgumentCoercion.coerce(["action": "start", "pressure": "secret 4412"], to: schema)
        XCTAssertFalse(result.refusalMessage?.contains("4412") ?? true)
    }

    func testTheRealReadingToolTakesANumberForItsTextValue() throws {
        // `reading.value` is declared as text; a small model often sends the bare number.
        let tool = try XCTUnwrap(registry().tool(named: "reading"))
        let root = OnDeviceToolSchema.root(toolName: "reading", parameters: tool.parametersSchema)
        let result = OnDeviceArgumentCoercion.coerce(["action": "record_reading", "value": 118], to: root)
        XCTAssertTrue(result.isDispatchable)
        XCTAssertEqual(result.arguments["value"] as? String, "118")
    }

    func testTheRealCalculatorTakesNumbersWrittenAsText() throws {
        let tool = try XCTUnwrap(registry().tool(named: "domain_calc"))
        let root = OnDeviceToolSchema.root(toolName: "domain_calc", parameters: tool.parametersSchema)
        let result = OnDeviceArgumentCoercion.coerce(
            ["operation": "superheat", "suction_pressure_psig": "118", "suction_line_temp_f": "52"], to: root)
        XCTAssertTrue(result.isDispatchable, "\(result.problems)")
        XCTAssertEqual(result.arguments["suction_pressure_psig"] as? Double, 118)
    }
}
