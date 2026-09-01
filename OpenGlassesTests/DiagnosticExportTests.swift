import XCTest
@testable import OpenGlasses

/// Plan DM P3 — the in-memory diagnostic ring and the consented export built from it.
///
/// Three properties are worth a test here, and they are the three the plan asks for: the ring is
/// bounded and ordered and safe to write to from any thread; the preview the wearer approves is
/// byte-for-byte the file that gets written; and a bundle lives in a protected session that is
/// deleted whichever way the share ends.
final class DiagnosticRingTests: XCTestCase {

    private func event(_ n: Int) -> PrivacyEvent {
        PrivacyEvent(.tools, .toolDispatch, [.init(.count, .count(n))])
    }

    func testRingKeepsTheMostRecentEventsInOrder() {
        let ring = DiagnosticRing(capacity: 5)
        for index in 1...12 {
            ring.record(event(index), line: "line-\(index)")
        }

        let lines = ring.entries.map(\.line)
        XCTAssertEqual(lines, ["line-8", "line-9", "line-10", "line-11", "line-12"],
                       "the ring must hold the newest `capacity` entries, oldest first")
        XCTAssertEqual(ring.count, 5)
    }

    func testRingBelowCapacityHoldsEverything() {
        let ring = DiagnosticRing(capacity: 500)
        for index in 1...10 { ring.record(event(index), line: "line-\(index)") }
        XCTAssertEqual(ring.count, 10)
        XCTAssertEqual(ring.entries.first?.line, "line-1")
        XCTAssertEqual(ring.entries.last?.line, "line-10")
    }

    func testEntriesCarryCategoryNameAndTimestamp() {
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)
        let ring = DiagnosticRing(capacity: 4, clock: { fixed })
        ring.record(PrivacyLog.qrScanned(payload: .url, bytes: 42), line: "encoded")

        let entry = try? XCTUnwrap(ring.entries.first)
        XCTAssertEqual(entry?.category, .capture)
        XCTAssertEqual(entry?.name, .qrScanned)
        XCTAssertEqual(entry?.timestamp, fixed)
    }

    func testClearEmptiesTheRing() {
        let ring = DiagnosticRing(capacity: 4)
        ring.record(event(1), line: "a")
        ring.clear()
        XCTAssertTrue(ring.entries.isEmpty)
    }

    /// The ring is written from whichever thread logged, so concurrent writes must neither lose
    /// entries nor exceed the bound.
    func testConcurrentWritesStayBoundedAndComplete() {
        let ring = DiagnosticRing(capacity: 100)
        let queue = DispatchQueue(label: "canary.ring", attributes: .concurrent)
        let group = DispatchGroup()

        for index in 0..<500 {
            queue.async(group: group) { ring.record(self.event(index), line: "line-\(index)") }
        }
        group.wait()

        XCTAssertEqual(ring.count, 100, "the bound must hold under concurrency")
        XCTAssertEqual(Set(ring.entries.map(\.line)).count, 100, "no entry may be written twice")
    }

    /// Attaching subscribes to the real facade; detaching actually stops it.
    func testAttachRecordsRealEventsAndDetachStops() {
        let ring = DiagnosticRing(capacity: 50)
        ring.attach()
        defer { ring.detach() }
        XCTAssertTrue(ring.isAttached)

        PrivacyLog.toolDispatch(.native, tool: "probe_tool")
        XCTAssertEqual(ring.count, 1)
        XCTAssertTrue(ring.entries.first?.line.contains("probe_tool") == true)

        ring.attach()  // idempotent — must not double-record
        PrivacyLog.toolDispatch(.native, tool: "probe_tool")
        XCTAssertEqual(ring.count, 2)

        ring.detach()
        PrivacyLog.toolDispatch(.native, tool: "probe_tool")
        XCTAssertEqual(ring.count, 2)
        XCTAssertFalse(ring.isAttached)
    }
}

// MARK: - The document

final class DiagnosticExportBuilderTests: XCTestCase {

    private let environment = DiagnosticExportEnvironment(
        appVersion: "2026.9", buildNumber: "354",
        systemName: "iOS", systemVersion: "26.0", deviceModel: "iPhone17,1")

    private func entries(_ count: Int) -> [DiagnosticRing.Entry] {
        (0..<count).map { index in
            DiagnosticRing.Entry(timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                                 category: .tools, name: .toolRun,
                                 line: "[tools] toolRun event=succeeded tool=web_search elapsed=1.5s")
        }
    }

    func testPreviewIsExactlyWhatGetsWritten() throws {
        let document = DiagnosticExportBuilder.build(entries: entries(3), environment: environment)
        // Every event line appears in the body, and the body is the single representation.
        for line in document.eventLines {
            XCTAssertTrue(document.body.contains(line))
        }
        for line in document.headerLines where !line.isEmpty {
            XCTAssertTrue(document.body.contains(line))
        }
        XCTAssertEqual(document.eventCount, 3)
    }

    func testEventLinesCarryATimestampAndTheEncodedEvent() throws {
        let document = DiagnosticExportBuilder.build(entries: entries(1), environment: environment,
                                                     timeZone: TimeZone(identifier: "UTC")!)
        let line = try XCTUnwrap(document.eventLines.first)
        XCTAssertTrue(line.hasPrefix("22:13:20.000"), "got \(line)")
        XCTAssertTrue(line.contains("[tools] toolRun event=succeeded"))
    }

    func testHeaderStatesWhatTheFileIsAndIsNot() {
        let document = DiagnosticExportBuilder.build(entries: entries(2), environment: environment)
        let header = document.headerLines.joined(separator: " ")
        XCTAssertTrue(header.contains("2026.9"))
        XCTAssertTrue(header.contains("iPhone17,1"))
        XCTAssertTrue(header.contains("no conversation content"))
        XCTAssertTrue(header.contains("2 events from this session"))
        // P3.4: the honest note about `.private` log fields must travel with the file.
        XCTAssertTrue(header.lowercased().contains("does not make the value safe to send"))
    }

    func testAFullRingSaysSoRatherThanImplyingNothingElseHappened() {
        let full = DiagnosticExportBuilder.build(entries: entries(10), environment: environment,
                                                 capacity: 10)
        XCTAssertTrue(full.ringWasFull)
        XCTAssertTrue(full.body.contains("the oldest were dropped"))

        let partial = DiagnosticExportBuilder.build(entries: entries(3), environment: environment,
                                                    capacity: 10)
        XCTAssertFalse(partial.ringWasFull)
        XCTAssertFalse(partial.body.contains("the oldest were dropped"))
    }

    func testEmptyRingProducesAnHonestDocument() {
        let document = DiagnosticExportBuilder.build(entries: [], environment: environment)
        XCTAssertTrue(document.body.contains("(no events recorded yet)"))
        XCTAssertEqual(document.eventCount, 0)
    }

    /// The defence-in-depth pass P0.5 kept `LogRedaction` for. Nothing that reaches the builder
    /// should contain a token — the ring holds encoded events, and no field of one can be a URL —
    /// so this is the belt to the type system's braces, and it has to actually run.
    func testFinalRedactionPassMasksATokenThatSomehowSurvived() {
        let planted = DiagnosticRing.Entry(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            category: .capture, name: .qrFetchLoaded,
            line: #"[capture] qrFetchLoaded host=https://x.example.test/a?token=CANARY-7f3a-SECRET"#)
        let document = DiagnosticExportBuilder.build(entries: [planted], environment: environment)

        XCTAssertFalse(document.body.contains("CANARY-7f3a-SECRET"),
                       "the final redaction pass must mask a token value")
        XCTAssertTrue(document.body.contains("token=***"))
    }

    func testDisplayNameIsADateAndNothingElse() {
        let name = DiagnosticExportBuilder.displayName(now: Date(timeIntervalSince1970: 1_700_000_000),
                                                       timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(name, "openglasses-diagnostics-2023-11-14-2213.txt")
    }
}

// MARK: - The protected session

@MainActor
final class DiagnosticExportCoordinatorTests: XCTestCase {

    /// Records what the protector was asked to protect, and can be made to fail either half.
    private final class RecordingProtector: ProtectedExportProtecting {
        enum Failure { case directory, file }
        var failure: Failure?
        private(set) var protected: [URL] = []

        func protect(_ url: URL) throws {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            if failure == .directory && isDirectory { throw ProtectedExportFault.setupFailed }
            if failure == .file && !isDirectory { throw ProtectedExportFault.setupFailed }
            protected.append(url)
            try FileProtectionApplier().protect(url)
        }
    }

    private var root: URL!
    private var protector: RecordingProtector!
    private var coordinator: DiagnosticExportCoordinator!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiagnosticExportTests_\(UUID().uuidString)")
        protector = RecordingProtector()
        coordinator = DiagnosticExportCoordinator(
            store: ProtectedExportFileStore(rootDirectoryName: "DiagnosticExports",
                                            root: root, protector: protector))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func document(_ text: String = "diagnostics") -> DiagnosticExportDocument {
        DiagnosticExportBuilder.build(
            entries: [DiagnosticRing.Entry(timestamp: Date(), category: .tools, name: .toolRun,
                                           line: "[tools] toolRun event=succeeded \(text)")],
            environment: .unknown)
    }

    func testTheFileHoldsExactlyThePreviewedBytes() throws {
        let previewed = document()
        let lease = try coordinator.makeLease(document: previewed)
        defer { coordinator.release(lease) }

        let written = try String(contentsOf: lease.fileURL, encoding: .utf8)
        XCTAssertEqual(written, previewed.body,
                       "the file must be the preview — nothing appended after consent")
    }

    func testTheBundleIsProtectedAndBackupExcludedUnderTheRoot() throws {
        let lease = try coordinator.makeLease(document: document())
        defer { coordinator.release(lease) }

        XCTAssertTrue(ProtectedExportFileStore.isContained(lease.fileURL, within: root))
        XCTAssertTrue(protector.protected.contains { $0.path == lease.sessionDirectory.path })
        XCTAssertTrue(protector.protected.contains { $0.path == lease.fileURL.path })
        XCTAssertLessThan(protector.protected.firstIndex { $0.path == lease.sessionDirectory.path }!,
                          protector.protected.firstIndex { $0.path == lease.fileURL.path }!,
                          "the directory is protected before it can hold anything")

        for url in [lease.sessionDirectory, lease.fileURL] {
            let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
            XCTAssertEqual(values.isExcludedFromBackup, true)
        }
        if let protection = try FileManager.default.attributesOfItem(atPath: lease.fileURL.path)[.protectionKey]
            as? FileProtectionType {
            XCTAssertEqual(protection, .complete)
        }
    }

    func testOnDiskNameIsAUUIDNotTheDisplayName() throws {
        let lease = try coordinator.makeLease(document: document(),
                                              displayName: "my-diagnostics-2026.txt")
        defer { coordinator.release(lease) }
        let stem = lease.fileURL.deletingPathExtension().lastPathComponent
        XCTAssertNotNil(UUID(uuidString: stem), "on-disk name must be a bare UUID, got \(stem)")
        XCTAssertEqual(lease.displayName, "my-diagnostics-2026.txt")
    }

    func testTraversalDisplayNamesCannotEscapeTheRoot() throws {
        for hostile in ["../../etc/passwd", "/etc/passwd", "../"] {
            let lease = try coordinator.makeLease(document: document(), displayName: hostile)
            XCTAssertTrue(ProtectedExportFileStore.isContained(lease.fileURL, within: root))
            XCTAssertFalse(lease.displayName.contains("/"))
            XCTAssertFalse(lease.displayName.contains(".."))
            coordinator.release(lease)
        }
    }

    func testEverySharedOutcomeRemovesTheFile() throws {
        for outcome in [DiagnosticExportCoordinator.ShareOutcome.completed, .cancelled, .failed] {
            let lease = try coordinator.makeLease(document: document())
            coordinator.beginShare(lease)
            coordinator.finishShare(lease, outcome: outcome)
            XCTAssertFalse(FileManager.default.fileExists(atPath: lease.sessionDirectory.path),
                           "\(outcome) must delete the bundle")
            XCTAssertEqual(coordinator.activeLeaseCount, 0)
        }
    }

    func testDoubleReleaseIsHarmless() throws {
        let lease = try coordinator.makeLease(document: document())
        coordinator.release(lease)
        coordinator.release(lease)
        XCTAssertEqual(coordinator.activeLeaseCount, 0)
    }

    func testBackgroundingReleasesWhatNoShareHolds() throws {
        let shared = try coordinator.makeLease(document: document())
        let abandoned = try coordinator.makeLease(document: document())
        coordinator.beginShare(shared)

        coordinator.handleBackground()

        XCTAssertTrue(FileManager.default.fileExists(atPath: shared.fileURL.path),
                      "a bundle held by an onscreen share survives backgrounding")
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.sessionDirectory.path))
        coordinator.finishShare(shared, outcome: .completed)
    }

    func testScavengeRemovesACrashAbandonedBundlePastTTL() throws {
        let store = ProtectedExportFileStore(rootDirectoryName: "DiagnosticExports",
                                             root: root, protector: protector)
        let session = try store.createSession(fileExtension: "txt") { url in
            try Data("stale".utf8).write(to: url)
        }
        // A different store instance is what a later launch has: it owns nothing here.
        let nextLaunch = DiagnosticExportCoordinator(
            store: ProtectedExportFileStore(rootDirectoryName: "DiagnosticExports",
                                            root: root, protector: RecordingProtector()),
            clock: { Date().addingTimeInterval(7200) })
        nextLaunch.scavenge()
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.directory.path))
    }

    func testScavengeSparesABundleInsideTheRecoveryWindow() throws {
        let lease = try coordinator.makeLease(document: document())
        coordinator.scavenge()
        XCTAssertTrue(FileManager.default.fileExists(atPath: lease.fileURL.path))
        coordinator.release(lease)
    }

    func testAProtectionFailureLeavesNothingBehind() {
        protector.failure = .file
        XCTAssertThrowsError(try coordinator.makeLease(document: document()))
        let remaining = (try? FileManager.default.contentsOfDirectory(at: root,
                                                                     includingPropertiesForKeys: nil)) ?? []
        XCTAssertTrue(remaining.isEmpty, "a bundle that could not be protected must not survive")
    }

    /// The end-to-end privacy claim: drive real subsystems with the canary corpus, export the ring
    /// that recorded them, and read the file back off disk.
    func testACanaryDrivenThroughTheAppNeverReachesAnExportFile() async throws {
        let ring = DiagnosticRing(capacity: 500)
        ring.attach()
        defer { ring.detach() }

        // Real subsystems, canary-bearing input — the same corpus `PrivacyCanaryTests` drives.
        let registry = NativeToolRegistry(locationService: LocationService())
        registry.register(ExportProbeTool())
        let router = NativeToolRouter(registry: registry)
        router.toolTimeoutSeconds = 5
        _ = await router.handleToolCall(name: "export_probe",
                                        args: ["payload": PrivacyCanary.toolArguments])
        AmbientCaptionService().insertVisualNote(PrivacyCanary.transcript)
        PrivacyLog.qrFetchBlocked(.refused(URLFetchGuard.Rejection
            .privateOrReservedHost(PrivacyCanary.url)))

        XCTAssertFalse(ring.entries.isEmpty, "the ring recorded nothing — the probe is vacuous")

        let document = DiagnosticExportBuilder.build(entries: ring.entries, environment: .unknown,
                                                     capacity: ring.capacity)
        let lease = try coordinator.makeLease(document: document)
        defer { coordinator.release(lease) }

        let written = try String(contentsOf: lease.fileURL, encoding: .utf8)
        XCTAssertFalse(written.uppercased().contains(PrivacyCanary.stem),
                       "a canary reached the export file:\n\(written)")
        for canary in PrivacyCanary.all {
            XCTAssertFalse(written.contains(canary))
        }
        XCTAssertTrue(written.contains("export_probe"),
                      "the export must still describe what happened")
    }
}

/// Returns a canary-bearing result through the real tool router.
private struct ExportProbeTool: NativeTool {
    let name = "export_probe"
    let description = "test fixture"
    let parametersSchema: [String: Any] = ["type": "object", "properties": [:] as [String: Any]]

    func execute(args: [String: Any]) async throws -> String {
        PrivacyCanary.toolResult
    }
}
