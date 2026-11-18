import XCTest
@testable import OpenGlasses

/// Keeps Meta's [Experimental] glasses APIs in their TestFlight-only lane (Plan JV P0).
///
/// Meta's rule: apps that use experimental features cannot be published. The owner's lane is an
/// opt-in generation flag: `AVENKIN_DAT_EXPERIMENTAL=1` adds `project.experimental.yml`, which
/// links `MWDATInputs`, defines `DAT_EXPERIMENTAL` and stamps the build, and every line that
/// touches an experimental API compiles only under that condition. Every unflagged build is a store
/// candidate. This guard fails the ordinary suite when that stops being true by construction:
/// 1. a committed spec other than the experimental one names an experimental module;
/// 2. the generator adds the experimental spec other than behind the flag, or stops refusing it
///    under CI / Xcode Cloud or with the phone-only product;
/// 3. a line under `OpenGlasses/Sources` names an experimental API outside
///    `Sources/Glasses/Experimental/` (each file there wrapped whole in `#if DAT_EXPERIMENTAL`), and
///    any `DAT_EXPERIMENTAL` conditional outside that folder is not one of the roster's call sites;
/// 4. the stamp is not `"NO"` in base, `"YES"` in the experimental spec and carried by the
///    authored Info.plist — and the bundle running this suite disagrees with how it was compiled.
final class DATExperimentalGuardTests: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)   // <repo>/OpenGlassesTests/<thisfile>.swift
            .deletingLastPathComponent()  // <repo>/OpenGlassesTests
            .deletingLastPathComponent()  // <repo>
    }

    private static let folder = "OpenGlasses/Sources/Glasses/Experimental/"
    private static let laneSpec = "project.experimental.yml"
    private static let experimentalModules = ["MWDATInputs", "MWDATMotion", "MWDATSpeech"]
    /// The compilation condition, as a whole word (not the stamp's `AVENKIN_DAT_EXPERIMENTAL`).
    private static let condition = #"\bDAT_EXPERIMENTAL\b"#

    /// What only the lane may say: the experimental APIs, as whole-word patterns. `Camera.photo`,
    /// `audioCodec` and `audioFramePublisher` are experimental too, though the plan uses none.
    private static let experimentalAPIs: [String] = [
        #"\bVoiceInvocationsStream\b"#, #"\bLaunchApp\b"#, #"\bResponseHandle\b"#,
        #"\bimport\s+MWDATInputs\b"#, #"\bimport\s+MWDATMotion\b"#, #"\bimport\s+MWDATSpeech\b"#,
        #"\baddInputs\b"#, #"\bInputEvent\b"#, #"\bCamera\.photo\b"#, #"\baudioCodec\b"#,
        #"\baudioFramePublisher\b"#,
        // Inputs (P2): its types and calls, which only the probe's lane files may name.
        #"\bremoveInputs\b"#, #"\bInputsConfiguration\b"#, #"\bInputsState\b"#, #"\bInputsError\b"#,
        #"\bInputSource\b"#, #"\bNavDirection\b"#, #"\bCapturePressType\b"#, #"\bDragAction\b"#,
        #"\bconsumeBack\b"#,
    ]

    /// Every `DAT_EXPERIMENTAL` conditional outside the folder, with exactly what it may contain.
    /// Keep it minimal: one start-up call, one Settings section, the Developer panel's Inputs probe
    /// (P2), and the policy's own answer.
    private static let callSites: [(path: String, body: [String])] = [
        ("OpenGlasses/Sources/App/OpenGlassesApp.swift", ["DATExperimentalFeatures.start(appState: self)"]),
        ("OpenGlasses/Sources/App/Views/SettingsView.swift", ["DATExperimentalSettingsSection()"]),
        ("OpenGlasses/Sources/App/Views/DeveloperPanelView.swift", ["InputsProbeSection()"]),
        ("OpenGlasses/Sources/Services/DATExperimentalPolicy.swift", ["return true", "#else", "return false"]),
    ]

    // MARK: - Helpers

    private func text(_ relativePath: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func swiftSources() throws -> [(path: String, text: String)] {
        let root = Self.repoRoot.appendingPathComponent("OpenGlasses/Sources")
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            XCTFail("no sources at \(root.path)"); return []
        }
        var files: [(String, String)] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let relative = String(url.path.dropFirst(Self.repoRoot.path.count + 1))
            files.append((relative, try String(contentsOf: url, encoding: .utf8)))
        }
        XCTAssertGreaterThan(files.count, 500, "the source scan found too few files to be the app")
        return files
    }

    private static func isComment(_ trimmed: String) -> Bool {
        trimmed.hasPrefix("//") || trimmed.hasPrefix("/*") || trimmed.hasPrefix("*")
    }

    private func matches(_ pattern: String, _ line: String) -> Bool {
        line.range(of: pattern, options: .regularExpression) != nil
    }

    /// The bodies of every `#if DAT_EXPERIMENTAL … #endif` in a file, as trimmed non-blank,
    /// non-comment lines, and every other line that mentions the condition.
    private func conditionals(in text: String) -> (blocks: [[String]], strays: [String]) {
        var blocks: [[String]] = []
        var strays: [String] = []
        var current: [String]?
        var depth = 0
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !Self.isComment(line) else { continue }
            if current != nil {
                if line.hasPrefix("#if") { depth += 1 }
                if line.hasPrefix("#endif") {
                    if depth == 0 { blocks.append(current!); current = nil; continue }
                    depth -= 1
                }
                current!.append(line)
                if matches(Self.condition, line) { strays.append(line) }
            } else if line == "#if DAT_EXPERIMENTAL" {
                current = []
                depth = 0
            } else if matches(Self.condition, line) {
                strays.append(line)
            }
        }
        if let current { blocks.append(current); strays.append("unclosed #if DAT_EXPERIMENTAL") }
        return (blocks, strays)
    }

    // MARK: - 1. Specs

    func testOnlyTheLaneSpecNamesAnExperimentalModule() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: Self.repoRoot.path)
            .filter { $0.hasPrefix("project.") && ($0.hasSuffix(".yml") || $0.hasSuffix(".yml.example")) }
        for required in ["project.base.yml", "project.watch.yml", "project.tests.yml", Self.laneSpec] {
            XCTAssertTrue(names.contains(required), "\(required) is missing; update this guard with it")
        }
        for name in names {
            let spec = try text(name)
            if name == Self.laneSpec {
                XCTAssertTrue(spec.contains("product: MWDATInputs"), "\(name) is the lane: it links Inputs")
                XCTAssertFalse(spec.contains("MWDATMotion"), "the plan links no Motion")
                XCTAssertFalse(spec.contains("MWDATSpeech"), "the plan links no Speech")
                XCTAssertTrue(spec.contains(#"SWIFT_ACTIVE_COMPILATION_CONDITIONS: "$(inherited) DEBUG DAT_EXPERIMENTAL""#),
                              "\(name) defines DAT_EXPERIMENTAL in Debug, keeping DEBUG")
                XCTAssertTrue(spec.contains(#"SWIFT_ACTIVE_COMPILATION_CONDITIONS: "$(inherited) DAT_EXPERIMENTAL""#),
                              "\(name) defines DAT_EXPERIMENTAL in Release")
            } else {
                for module in Self.experimentalModules {
                    XCTAssertFalse(spec.contains(module), "\(name) names \(module); only \(Self.laneSpec) may")
                }
                // Whole word: `AVENKIN_DAT_EXPERIMENTAL`, the stamp's setting, is base's too.
                XCTAssertFalse(matches(Self.condition, spec), "\(name) defines the lane's condition")
            }
        }
    }

    // MARK: - 2. The generator

    func testTheGeneratorAddsTheLaneOnlyBehindTheFlagAndNeverUnderCIOrPhoneOnly() throws {
        let script = try text("Scripts/generate-xcodeproj.sh")
        XCTAssertTrue(script.contains(#"dat_experimental="${AVENKIN_DAT_EXPERIMENTAL:-0}""#))
        XCTAssertTrue(script.contains("if [[ \"$dat_experimental\" == \"1\" ]]; then\n    echo \"  - \(Self.laneSpec)\""),
                      "the lane spec is included only when AVENKIN_DAT_EXPERIMENTAL=1")
        XCTAssertEqual(script.components(separatedBy: Self.laneSpec).count - 1, 1,
                       "the lane spec is named once, in its guarded include")
        // The refusal block: CI markers, then phone-only, each exiting.
        let refusal = try XCTUnwrap(script.range(of: "if [[ \"$dat_experimental\" == \"1\" ]]; then\n  for marker in"),
                                    "the generator must refuse the lane under CI")
        let block = String(script[refusal.lowerBound...].prefix(1200))
        for marker in ["CI", "CI_XCODE_CLOUD", "CI_WORKFLOW", "CI_BUILD_ID", "GITHUB_ACTIONS"] {
            XCTAssertTrue(block.range(of: "for marker in [^\\n]*\\b\(marker)\\b", options: .regularExpression) != nil,
                          "the generator must refuse the lane when \(marker) is set")
        }
        XCTAssertTrue(block.contains("if [[ \"$phone_only\" == \"1\" ]]; then"),
                      "the generator must refuse the lane with OPENGLASSES_PHONE_ONLY=1")
        XCTAssertGreaterThanOrEqual(block.components(separatedBy: "exit 1").count - 1, 2,
                                    "both refusals exit")
        XCTAssertTrue(script.contains("TESTFLIGHT ONLY — never submit for review"),
                      "a flagged generation says loudly what it made")
    }

    // MARK: - 3. Sources

    func testExperimentalAPIsAreUsedOnlyInsideTheFolder() throws {
        var offenders: [String] = []
        // One precompiled pass per file first: matching every pattern on every line of every
        // source file took minutes on CI, past the per-test allowance.
        let any = try NSRegularExpression(pattern: Self.experimentalAPIs.joined(separator: "|"))
        for (path, text) in try swiftSources() where !path.hasPrefix(Self.folder) {
            let whole = NSRange(text.startIndex..., in: text)
            guard any.firstMatch(in: text, range: whole) != nil else { continue }
            for line in text.components(separatedBy: .newlines) {
                for pattern in Self.experimentalAPIs where matches(pattern, line) {
                    offenders.append("\(path): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        XCTAssertEqual(offenders, [], "Meta's experimental APIs may be used only in \(Self.folder), under #if DAT_EXPERIMENTAL")
    }

    func testEveryFileInTheFolderIsWrappedWhole() throws {
        let inFolder = try swiftSources().filter { $0.path.hasPrefix(Self.folder) }
        XCTAssertFalse(inFolder.isEmpty, "the experimental folder has gone; update this guard with it")
        for (path, text) in inFolder {
            let lines = text.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !Self.isComment($0) }
            XCTAssertEqual(lines.first, "#if DAT_EXPERIMENTAL", "\(path) must open with #if DAT_EXPERIMENTAL")
            XCTAssertEqual(lines.last, "#endif", "\(path) must close with the #endif of that #if")
            var depth = 0
            for (index, line) in lines.enumerated() {
                if line.hasPrefix("#if") { depth += 1 }
                if line.hasPrefix("#endif") { depth -= 1 }
                if depth == 0, index < lines.count - 1 {
                    XCTFail("\(path): code after the DAT_EXPERIMENTAL block closes (line \(index + 1) of code lines)")
                    break
                }
            }
        }
    }

    func testTheConditionAppearsOutsideTheFolderOnlyAtTheRosterCallSites() throws {
        var found: [String: [[String]]] = [:]
        var strays: [String] = []
        for (path, text) in try swiftSources() where !path.hasPrefix(Self.folder) && matches(Self.condition, text) {
            let scan = conditionals(in: text)
            if !scan.blocks.isEmpty { found[path] = scan.blocks }
            strays += scan.strays.map { "\(path): \($0)" }
        }
        XCTAssertEqual(strays, [], "DAT_EXPERIMENTAL outside \(Self.folder) is only ever `#if DAT_EXPERIMENTAL` at a roster call site")
        XCTAssertEqual(Set(found.keys), Set(Self.callSites.map(\.path)),
                       "a DAT_EXPERIMENTAL call site was added or removed; the roster names each one")
        for site in Self.callSites {
            XCTAssertEqual(found[site.path], [site.body], "\(site.path): the call site holds only its roster line")
        }
    }

    // MARK: - 3b. The Inputs probe's configuration (P2)

    /// The probe asks for the touchpad and the Neural Band and leaves Back to Meta: never the
    /// capture button (Meta's camera), never the action button, never `consumeBack: true`, and never the SDK's default configuration, which
    /// is every source with Back consumed. One configuration, written once, used by every add.
    func testTheInputsProbeAsksForTheTouchpadAndBandAndLeavesBackToMeta() throws {
        XCTAssertEqual(InputsProbePolicy.origins, [.captouch, .neuralBand, .neuralBandDrag])
        XCTAssertFalse(InputsProbePolicy.origins.contains(.captureButton))
        XCTAssertFalse(InputsProbePolicy.origins.contains(.actionButton))
        XCTAssertFalse(InputsProbePolicy.consumesBack)
        XCTAssertEqual(InputsProbePolicy.timeLimit, .seconds(300))

        let inFolder = try swiftSources().filter { $0.path.hasPrefix(Self.folder) }
        var configurations: [String] = []
        var adds: [String] = []
        for (path, text) in inFolder {
            for raw in text.components(separatedBy: .newlines) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard !Self.isComment(line) else { continue }
                if line.contains("InputsConfiguration(") { configurations.append("\(path): \(line)") }
                if matches(#"\baddInputs\("#, line) { adds.append("\(path): \(line)") }
                XCTAssertFalse(matches(#"consumeBack:\s*true"#, line), "\(path): \(line)")
            }
        }
        XCTAssertEqual(configurations, [
            "\(Self.folder)MetaInputsSource.swift: static let sdk = InputsConfiguration(sources: [.captouch, .neuralBand, .neuralBandDrag], consumeBack: false)",
        ], "the probe's one configuration is the touchpad and the band with Back left to Meta")
        XCTAssertEqual(adds, [
            "\(Self.folder)MetaInputsSource.swift: added = try session.addInputs(configuration: InputsProbeConfiguration.sdk)",
        ], "Inputs is added once, with the probe's configuration, never the SDK's default")
    }

    // MARK: - 4. The stamp

    func testTheStampIsNoInBaseYesInTheLaneAndCarriedByTheInfoPlist() throws {
        XCTAssertTrue(try text("project.base.yml").contains(#"AVENKIN_DAT_EXPERIMENTAL: "NO""#))
        XCTAssertTrue(try text(Self.laneSpec).contains(#"AVENKIN_DAT_EXPERIMENTAL: "YES""#))
        let data = try Data(contentsOf: Self.repoRoot.appendingPathComponent("OpenGlasses/Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist[AppBuildIdentity.datExperimentalKey] as? String, "$(AVENKIN_DAT_EXPERIMENTAL)")
    }

    /// The bundle hosting this suite was stamped the way it was compiled. In the ordinary run that
    /// is "NO" and no experimental code; in a flagged run, both "YES".
    func testTheRunningBuildsStampMatchesHowItWasCompiled() {
        let stamp = Bundle.main.object(forInfoDictionaryKey: AppBuildIdentity.datExperimentalKey) as? String
        #if DAT_EXPERIMENTAL
        XCTAssertEqual(stamp, "YES")
        XCTAssertTrue(DATExperimentalPolicy.isCompiledIn)
        #else
        XCTAssertEqual(stamp, "NO")
        XCTAssertFalse(DATExperimentalPolicy.isCompiledIn)
        #endif
        XCTAssertEqual(AppBuildIdentity.current.datExperimental, DATExperimentalPolicy.isCompiledIn)
    }
}
