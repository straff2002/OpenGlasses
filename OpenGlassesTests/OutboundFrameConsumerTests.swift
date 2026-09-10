import XCTest
@testable import OpenGlasses

/// W04.1 — the test that catches the *next* bypass.
///
/// Every other privacy-filter test asks "does the filter behave correctly when it is called?".
/// This one asks the question those cannot: "is it called everywhere it needs to be?" The two
/// defects this surface has actually shipped were both of that shape — a blur with no call sites at
/// all (Plan CO Item 0), and a recording path that kept subscribing to the raw camera publisher
/// after the app-side one had been moved onto the blur relay. Neither could have been caught by a
/// behavioural test of `PrivacyFilterService`, because in both cases the service was blameless.
///
/// So this reads the source. It finds every frame subscription and every `filtered(_:for:)` call in
/// `OpenGlasses/Sources`, resolves the type that owns each one, and fails if that type is not on the
/// `OutboundFrameConsumer` roster or the short exempt list below. Adding a consumer means adding a
/// case; tapping the raw camera publisher means arguing for it here.
final class OutboundFrameConsumerTests: XCTestCase {

    // MARK: - Source scraping

    /// `#filePath` is baked in at compile time, so this resolves identically on a developer machine
    /// and in CI without the test bundle needing the sources as a resource.
    private static var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)   // <repo>/OpenGlassesTests/<thisfile>.swift
            .deletingLastPathComponent()  // <repo>/OpenGlassesTests
            .deletingLastPathComponent()  // <repo>
            .appendingPathComponent("OpenGlasses/Sources")
    }

    /// Types that appear in a frame-tap search but are not consumers of frames.
    ///
    /// Kept short on purpose: every entry is a place the roster deliberately does not describe, and
    /// a long list here would be the roster quietly losing its meaning.
    private static let exemptTypes: Set<String> = [
        // Declares `framePublisher` and `onVideoFrame` and sends on them. The source of every
        // frame in the app, so it cannot be a consumer of one.
        "CameraService",
        // Listens to the Meta SDK's `videoFramePublisher` and feeds `CameraService`. Strictly
        // upstream of the relay and of every consumer.
        "MetaCameraBackend",
        // The roster itself: its documentation names the APIs being searched for.
        "OutboundFrameConsumer",
        // Declares the still-reader seam and its default convenience. A protocol is not a consumer.
        "FilteredStillProviding",
        // Declares the blur-a-still-I-already-hold seam, for the same reason.
        "StillImageFiltering",
        // The blur itself. It is what the chokepoint calls, not something that taps a frame.
        "PrivacyFilterService",
    ]

    /// One frame-tap reference found in the sources.
    private struct Hit {
        let file: String
        let line: Int
        let type: String
        let text: String
    }

    /// The taps worth policing. `filtered(` catches the chokepoint call sites; the publisher names
    /// catch every subscription; `onVideoFrame` catches the single-slot raw callback, which is the
    /// easiest of the three to wire up without noticing it is unfiltered.
    private static let tapPatterns = [
        "framePublisher",
        "videoFramePublisher",
        "outboundFrames.publisher",
        ".filtered(",
        "onVideoFrame",
        // W04.1: the still half. `latestFrame` is the raw accessor the gap was made of;
        // `filteredStill(` is the chokepoint that replaced it. Both are taps, and a type doing
        // either has to be on the roster.
        "latestFrame",
        "filteredStill(",
        "filteredOrUnavailable(",
    ]

    /// Reads a Swift file and returns each tap reference with the top-level type that encloses it.
    ///
    /// Comment lines are skipped: this surface is heavily documented and cross-referenced, and a
    /// doc comment naming `framePublisher` is a reference, not a subscription. Declarations of the
    /// searched API (`let framePublisher =`, `func filtered(`) are code but not taps either, and the
    /// declaring types are on the exempt list above.
    private func hits(in file: URL) throws -> [Hit] {
        let contents = try String(contentsOf: file, encoding: .utf8)
        var currentType = "<file scope>"
        var found: [Hit] = []

        for (index, rawLine) in contents.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // Only column-zero declarations count. A nested `struct KnownFace` inside
            // `FaceRecognitionService` would otherwise be credited with its enclosing type's
            // subscriptions, and the roster would be policing a name nobody wrote down.
            if rawLine == line, let declared = Self.declaredType(in: line) { currentType = declared }
            guard !line.hasPrefix("//"), !line.hasPrefix("*"), !line.hasPrefix("/*") else { continue }
            guard Self.tapPatterns.contains(where: { line.contains($0) }) else { continue }
            found.append(Hit(file: file.lastPathComponent, line: index + 1,
                             type: currentType, text: line))
        }
        return found
    }

    /// The name of a top-level type declared on `line`, if it declares one. Nested types are
    /// deliberately not tracked — the owner an auditor cares about is the outermost one.
    private static func declaredType(in line: String) -> String? {
        let keywords = ["final class ", "class ", "struct ", "enum ", "actor ", "protocol ",
                        "extension "]
        let modifiers = ["", "private ", "public ", "internal ", "fileprivate ", "final "]
        for keyword in keywords {
            for modifier in modifiers where line.hasPrefix(modifier + keyword) {
                let rest = line.dropFirst((modifier + keyword).count)
                let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
                if !name.isEmpty { return String(name) }
            }
        }
        return nil
    }

    private func allHits() throws -> [Hit] {
        let root = Self.sourcesRoot
        guard let enumerator = FileManager.default.enumerator(at: root,
                                                              includingPropertiesForKeys: nil) else {
            XCTFail("Could not enumerate \(root.path)")
            return []
        }
        var result: [Hit] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            result.append(contentsOf: try hits(in: url))
        }
        return result
    }

    // MARK: - The exhaustiveness claim

    /// The scrape must actually be finding things. Without this, a broken path or a renamed API
    /// would turn every assertion below into a vacuous pass — the classic way a guard test dies.
    func testTheScrapeFindsTheKnownTaps() throws {
        let found = try allHits()
        XCTAssertGreaterThan(found.count, 20,
                             "Expected the frame-tap scrape to find the known call sites; found \(found.count)")
        let types = Set(found.map(\.type))
        for expected in ["AppState", "CameraService", "FaceRecognitionService",
                         "WebRTCStreamingService", "StructuredVisionService", "CapturePhotoTool",
                         "DwellCaptureService"] {
            XCTAssertTrue(types.contains(expected),
                          "Scrape missed \(expected) — the source walk or the patterns are broken")
        }
    }

    /// Every type that touches camera frames is on the roster or explicitly exempt.
    func testEveryFrameTapBelongsToAKnownConsumer() throws {
        let known = OutboundFrameConsumer.owningTypes.union(Self.exemptTypes)
        let unaccounted = try allHits().filter { !known.contains($0.type) }
        let described = unaccounted.map { "\($0.file):\($0.line) [\($0.type)] \($0.text)" }
        XCTAssertTrue(unaccounted.isEmpty, """
            These types consume camera frames but are not on the OutboundFrameConsumer roster. \
            Add a case (with its scope and mechanism) or justify an exemption:
            \(described.joined(separator: "\n"))
            """)
    }

    /// The rule the roster exists to enforce: a new outbound consumer subscribes to the relay,
    /// never to `CameraService.framePublisher`. Only the relay itself and the consumers whose scope
    /// says the blur must not be applied to them may read the raw tap.
    func testOnlyTheRelayAndExemptConsumersReadTheRawCameraTap() throws {
        let allowed = OutboundFrameConsumer.typesAllowedOnTheRawCameraTap.union(Self.exemptTypes)
        let raw = try allHits().filter { hit in
            (hit.text.contains("cameraService.framePublisher")
             || hit.text.contains("camera.framePublisher")
             || hit.text.contains("cameraService.onVideoFrame"))
        }
        XCTAssertFalse(raw.isEmpty, "The raw-tap search matched nothing — the guard is vacuous")
        let violations = raw.filter { !allowed.contains($0.type) }
        XCTAssertTrue(violations.isEmpty, """
            These types subscribe to the unfiltered camera stream directly. Subscribe to \
            AppState.outboundFrames.publisher instead, or add an exempt OutboundFrameConsumer case:
            \(violations.map { "\($0.file):\($0.line) [\($0.type)] \($0.text)" }.joined(separator: "\n"))
            """)
    }

    /// The specific regression W04.1 fixed: a recording started by voice used to bypass the blur.
    /// Asserted against the source because the tool resolves its frame source at execution time
    /// through `AppStateProvider`, which a headless test cannot stand up.
    func testToolStartedRecordingUsesTheBlurRelay() throws {
        let path = Self.sourcesRoot
            .appendingPathComponent("Services/NativeTools/VideoRecordingTool.swift")
        let source = try String(contentsOf: path, encoding: .utf8)
        XCTAssertTrue(source.contains("outboundFrames.publisher"),
                      "video_recording must record from the privacy-filtered relay")
        let code = source.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") }
        XCTAssertFalse(code.contains(where: { $0.contains("camera.framePublisher") }),
                       "video_recording must not read the raw camera publisher")
    }

    // MARK: - Roster coherence

    /// A case cannot claim a mechanism its scope contradicts. These are the invariants that make
    /// the roster meaningful rather than decorative.
    func testEveryConsumerMechanismAgreesWithItsScope() {
        for consumer in OutboundFrameConsumer.allCases {
            switch consumer.mechanism {
            case .relay:
                guard let scope = consumer.scope else {
                    return XCTFail("\(consumer.rawValue): relay-fed but has no scope")
                }
                XCTAssertTrue(scope.isFiltered, "\(consumer.rawValue) is relay-fed but unfiltered")
                XCTAssertTrue(scope.usesOutboundRelay,
                              "\(consumer.rawValue) is relay-fed but its scope says otherwise")
                XCTAssertEqual(consumer.tap, .outboundRelay,
                               "\(consumer.rawValue) is relay-fed but taps \(consumer.tap.rawValue)")
            case .chokepoint:
                guard let scope = consumer.scope else {
                    return XCTFail("\(consumer.rawValue): chokepoint-filtered but has no scope")
                }
                XCTAssertTrue(scope.isFiltered, "\(consumer.rawValue) filters at a chokepoint but its scope is exempt")
                XCTAssertFalse(scope.usesOutboundRelay,
                               "\(consumer.rawValue) should be relay-fed, not chokepoint-filtered")
            case .exemptByScope:
                guard let scope = consumer.scope else {
                    return XCTFail("\(consumer.rawValue): exempt but has no scope to be exempt under")
                }
                XCTAssertFalse(scope.isFiltered,
                               "\(consumer.rawValue) is listed exempt but its scope says filter it")
            case .relayInput:
                XCTAssertNil(consumer.scope,
                             "\(consumer.rawValue) is the blur pass itself and has no consumer scope")
                XCTAssertEqual(consumer.tap, .rawCameraPublisher)
            }
        }
    }

    /// Every filtered scope has at least one consumer, and every consumer scope is a real one.
    /// A scope with no consumer is either dead policy or a consumer nobody wrote down.
    func testEveryScopeHasAtLeastOneConsumer() {
        let covered = Set(OutboundFrameConsumer.allCases.compactMap(\.scope))
        let missing = PrivacyFilterScope.allCases.filter { !covered.contains($0) }
        XCTAssertTrue(missing.isEmpty,
                      "No consumer is listed for: \(missing.map(\.rawValue).joined(separator: ", "))")
    }

    /// Nothing on the raw camera tap may be a filtered scope — that combination is precisely a
    /// bypass, and it is the one the roster exists to make unrepresentable by accident.
    func testNothingOnTheRawTapClaimsToBeFiltered() {
        for consumer in OutboundFrameConsumer.allCases
        where consumer.tap == .rawCameraPublisher || consumer.tap == .rawCameraCallback {
            guard let scope = consumer.scope else { continue }   // the relay input
            if consumer.mechanism == .chokepoint { continue }    // filters the frame it receives
            XCTAssertFalse(scope.isFiltered, """
                \(consumer.rawValue) reads the unfiltered camera tap under a scope that says it \
                must be filtered, and does not filter at a chokepoint. That is a bypass.
                """)
        }
    }

    func testRosterEntriesAreUnique() {
        XCTAssertEqual(Set(OutboundFrameConsumer.allCases.map(\.rawValue)).count,
                       OutboundFrameConsumer.allCases.count)
    }

    // MARK: - Still readers (W04.1)
    //
    // The frame-publisher rules above were the whole guard until W04.1, and they were blind to the
    // way the app actually sends most of its pixels: one still at a time, pulled from
    // `CameraService.latestFrame` and handed to a model, a log, a Photos entry or an HTTP client.
    // Twenty-odd of those call sites existed and six `filtered(_:for:)` calls did — all six in
    // `AppState`. These two tests are what stops that from being true again.

    /// Reading the raw still is allowed only for a consumer the roster records as reading raw
    /// pixels. Everything else asks `filteredStill(for:source:)`.
    func testEveryRawStillReadBelongsToAConsumerWithARawTap() throws {
        let allowed = OutboundFrameConsumer.typesAllowedOnARawStill.union(Self.exemptTypes)
        let rawReads = try allHits().filter { $0.text.contains("latestFrame") }
        XCTAssertFalse(rawReads.isEmpty, "The raw-still search matched nothing — the guard is vacuous")
        let violations = rawReads.filter { !allowed.contains($0.type) }
        XCTAssertTrue(violations.isEmpty, """
            These types read the unfiltered still directly. Use \
            CameraService.filteredStill(for:source:) with the scope this still is for, or add a \
            roster case with a raw tap saying why raw pixels are required:
            \(violations.map { "\($0.file):\($0.line) [\($0.type)] \($0.text)" }.joined(separator: "\n"))
            """)
    }

    /// The sinks a still can leave through. Deliberately named as the *sink*, not as the reader:
    /// the question this test asks is "did these pixels pass the chokepoint on their way out",
    /// and a new sink is exactly the kind of thing that gets added without asking it.
    private static let sinkPatterns = [
        "analyzeFrame(",              // cloud model, free-text
        "analyzeFrameStructured(",    // cloud model, schema
        "GlassesPhotoAlbum.save",     // the Photos library
        "IMAGE_CAPTURED",             // base64 image into a tool result → the model
        "attachPhoto(",               // a Field Assist session log on disk
        "image_b64",                  // served to another process
    ]

    /// How a file can get camera pixels in the first place.
    private static let stillSourcePatterns = [
        "latestFrame", "capturePhoto()", "filteredStill(", "framePublisher", "onVideoFrame",
    ]

    /// The chokepoint calls that satisfy the rule.
    private static let chokepointPatterns = [
        "filteredStill(", "filteredOrUnavailable(", ".filtered(",
    ]

    /// A file that both obtains camera pixels and calls one of those sinks must contain a
    /// chokepoint call. One exemption, and it is the accessor's own home.
    func testFilesThatSendAStillSomewhereGoThroughTheChokepoint() throws {
        let exemptFiles: Set<String> = [
            // Declares `filteredStill(for:source:)` and `capturePhoto()`. Its own photo-library
            // write is the wearer's deliberate shutter press, which is a product decision of its
            // own and is tracked in the W04.1 roadmap row rather than settled here.
            "CameraService.swift",
        ]
        guard let enumerator = FileManager.default.enumerator(at: Self.sourcesRoot,
                                                              includingPropertiesForKeys: nil) else {
            return XCTFail("Could not enumerate sources")
        }
        var checked = 0
        var violations: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let name = url.lastPathComponent
            guard !exemptFiles.contains(name) else { continue }
            let code = try String(contentsOf: url, encoding: .utf8)
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.hasPrefix("//") && !$0.hasPrefix("*") && !$0.hasPrefix("/*") }
                .joined(separator: "\n")
            guard Self.sinkPatterns.contains(where: { code.contains($0) }),
                  Self.stillSourcePatterns.contains(where: { code.contains($0) }) else { continue }
            checked += 1
            if !Self.chokepointPatterns.contains(where: { code.contains($0) }) {
                violations.append(name)
            }
        }
        XCTAssertGreaterThan(checked, 5, "The sink search matched almost nothing — it is vacuous")
        XCTAssertTrue(violations.isEmpty, """
            These files take camera pixels and send them to a model, a log, the Photos library or \
            another process without passing the privacy chokepoint: \(violations.joined(separator: ", "))
            """)
    }

    /// Each new W04.1 scope has to be reachable through the accessor, not merely declared. A scope
    /// nobody requests is policy that does nothing — which is the exact failure CO Item 0 was.
    func testTheStillScopesAreActuallyRequestedInTheSources() throws {
        let root = Self.sourcesRoot
        guard let enumerator = FileManager.default.enumerator(at: root,
                                                              includingPropertiesForKeys: nil) else {
            return XCTFail("Could not enumerate sources")
        }
        var corpus = ""
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            corpus += try String(contentsOf: url, encoding: .utf8)
        }
        for scope: PrivacyFilterScope in [.visionAssessment, .assistiveGuidance, .toolPhotoCapture,
                                          .photoLibrary, .remoteFrameRequest] {
            XCTAssertTrue(corpus.contains(".\(scope.rawValue)"),
                          "No call site asks for \(scope.rawValue) — the scope is dead policy")
        }
    }
}
