import XCTest
@testable import OpenGlasses

/// W03.1 — the inventory is only worth having if it cannot quietly fall behind the code.
///
/// Two claims are checked here. The first is *exhaustiveness*: the sources are scraped for every
/// file that opens SQLite, writes into the app container, encodes structured content into
/// preferences, or adds a Keychain item, and every one of them must be either a registered store's
/// owner or on a short, reasoned exempt list. The second is *truth*: for the stores that can be
/// built over a temporary directory, the protection and backup attributes are read back off a real
/// file and compared with what the registry claims, so a case cannot describe protection its owner
/// does not apply.
final class DataStoreRegistryTests: XCTestCase {

    // MARK: - Source anchor
    //
    // `#filePath` is the repo anchor: baked in at compile time, so it resolves the same on a
    // developer machine and in CI, and the simulator shares the host filesystem.

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)   // <repo>/OpenGlassesTests/<thisfile>.swift
            .deletingLastPathComponent()  // <repo>/OpenGlassesTests
            .deletingLastPathComponent()  // <repo>
    }

    private static var sourcePaths: [String] {
        let root = repoRoot.appendingPathComponent("OpenGlasses/Sources")
        let subpaths = (try? FileManager.default.subpathsOfDirectory(atPath: root.path)) ?? []
        return subpaths.filter { $0.hasSuffix(".swift") }.map { "OpenGlasses/Sources/\($0)" }.sorted()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    /// Files that persist something but are deliberately not registry entries, and why.
    ///
    /// Kept short on purpose: the reason a scrape is worth running is that "we decided this one
    /// does not count" has to be written down where the next person will read it.
    private static let exempt: [String: String] = [
        // Mechanisms, not stores. The stores that use them are registered under their own owners.
        "OpenGlasses/Sources/Services/Persistence/JSONStore.swift":
            "the shared JSON write mechanism; its callers are registered individually",
        "OpenGlasses/Sources/Services/Export/ProtectedExportFileStore.swift":
            "the shared protected-export mechanism; its three families are registered",
        "OpenGlasses/Sources/Services/KeychainService.swift":
            "the Keychain wrapper itself; its item families are registered separately",
        "OpenGlasses/Sources/Services/Siri/SiriContentAdapters.swift":
            "builds the records SpotlightIndexService donates; holds nothing of its own",

        // Downloaded assets, not anybody's data.
        "OpenGlasses/Sources/Services/LocalizationManager.swift":
            "downloaded language packs",
        "OpenGlasses/Sources/Services/LocalInference/LocalModelRepository.swift":
            "downloaded model weights",
        "OpenGlasses/Sources/Services/LocalInference/LocalModelSelection.swift":
            "which model is selected — a preference over downloaded assets",
        "OpenGlasses/Sources/Services/GeminiLive/GeminiLiveModelCatalog.swift":
            "cached list of the provider's own model names",

        // UI state with no content in it.
        "OpenGlasses/Sources/Services/NativeTools/PomodoroTool.swift":
            "a timer's start time and length",
        "OpenGlasses/Sources/Services/MyDay/MyDayDismissals.swift":
            "which cards the wearer dismissed today",
        "OpenGlasses/Sources/Services/SettingsJourney/SettingsJourneyStore.swift":
            "onboarding progress flags",
        "OpenGlasses/Sources/Services/ShortcutsCatalog.swift":
            "the app's own shortcut definitions, not the wearer's data",

        // Test-only.
        "OpenGlasses/Sources/Utils/UITestSupport.swift":
            "Debug-only UI-test seeding",
    ]

    // MARK: - Exhaustiveness

    private func assertRegisteredOrExempt(_ paths: [String], kind: String) {
        let registered = SensitiveStore.registeredPaths
        for path in paths {
            if registered.contains(path) || Self.exempt[path] != nil { continue }
            XCTFail("\(kind): \(path) persists data but no SensitiveStore case owns it. "
                    + "Register it in DataStoreRegistry, or add it to the exempt list with a reason.")
        }
    }

    func testEverySQLiteOwnerIsRegistered() throws {
        let openers = try Self.sourcePaths.filter { try source($0).contains("sqlite3_open") }
        XCTAssertGreaterThanOrEqual(openers.count, 5, "sanity: the scan should be finding databases")
        assertRegisteredOrExempt(openers, kind: "SQLite")
    }

    func testEveryContainerFileWriterIsRegistered() throws {
        let containers = ["documentDirectory", "applicationSupportDirectory", "cachesDirectory"]
        let writers = try Self.sourcePaths.filter { path in
            let text = try source(path)
            guard containers.contains(where: { text.contains($0) }) else { return false }
            return text.contains(".write(to:") || text.contains("createFile(atPath")
        }
        XCTAssertGreaterThanOrEqual(writers.count, 10, "sanity: the scan should be finding writers")
        assertRegisteredOrExempt(writers, kind: "container file writer")
    }

    /// Preferences that hold *content* rather than a setting. Encoding a value through
    /// `JSONEncoder` is the tell: a preference is a scalar, and anything that needs a codec is a
    /// record.
    func testEveryStructuredPreferenceOwnerIsRegistered() throws {
        let owners = try Self.sourcePaths.filter { path in
            let text = try source(path)
            return text.contains("UserDefaults")
                && (text.contains("JSONEncoder") || text.contains("JSONDecoder"))
        }
        XCTAssertGreaterThanOrEqual(owners.count, 10, "sanity: the scan should be finding these")
        assertRegisteredOrExempt(owners, kind: "structured preference")
    }

    func testEveryKeychainWriterIsRegistered() throws {
        let writers = try Self.sourcePaths.filter { path in
            let text = try source(path)
            return text.contains("SecItemAdd") || text.contains("SecItemUpdate")
        }
        XCTAssertGreaterThanOrEqual(writers.count, 1)
        assertRegisteredOrExempt(writers, kind: "Keychain")
    }

    func testRegisteredOwnerPathsExistAndDeclareTheirOwner() throws {
        for record in SensitiveStore.all {
            for path in record.ownerPaths {
                let url = Self.repoRoot.appendingPathComponent(path)
                XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                              "\(record.store.rawValue): \(path) does not exist")
                let text = try source(path)
                XCTAssertTrue(text.contains(record.owner),
                              "\(record.store.rawValue): \(path) does not mention its owner \(record.owner)")
            }
        }
    }

    /// A case that names an API has to name one that exists. Otherwise the matrix reads as though
    /// erasure is covered where it is not — the precise failure W03.2 is about.
    func testNamedDeleteAPIsExistInTheirOwner() throws {
        for record in SensitiveStore.all {
            for deletion in [record.deleteAll, record.deleteSubject] {
                guard case .api(let signature) = deletion else { continue }
                // `Type.method(label:)` → look for `func method(` in the owner's sources.
                guard let call = signature.split(separator: ".").last,
                      let name = call.split(separator: "(").first else { continue }
                let bodies = try record.ownerPaths.map { try source($0) }.joined(separator: "\n")
                XCTAssertTrue(bodies.contains("func \(name)"),
                              "\(record.store.rawValue): registry names \(signature) but no "
                                  + "`func \(name)` exists in \(record.ownerPaths.joined(separator: ", "))")
            }
        }
    }

    // MARK: - Coherence

    func testEveryCaseIsRegisteredExactlyOnce() {
        let stores = SensitiveStore.all.map(\.store)
        XCTAssertEqual(Set(stores).count, SensitiveStore.allCases.count)
        for store in SensitiveStore.allCases {
            XCTAssertEqual(store.record.store, store, "\(store.rawValue) returns another case's record")
        }
    }

    func testSubjectLinkageAndSubjectDeletionAgree() {
        for record in SensitiveStore.all {
            if record.subjectLinkage == .none {
                XCTAssertEqual(record.deleteSubject, .notSubjectLinked,
                               "\(record.store.rawValue) has no subject linkage but claims a subject delete")
            }
            if case .notSubjectLinked = record.deleteSubject, record.subjectLinkage == .thirdPartySubject {
                XCTFail("\(record.store.rawValue) holds third-party data but records no subject linkage")
            }
        }
    }

    func testAtLeastOneStorePerThirdPartySubjectClassCanBeErased() {
        let thirdParty = SensitiveStore.all.filter { $0.subjectLinkage == .thirdPartySubject }
        XCTAssertFalse(thirdParty.isEmpty)
        XCTAssertTrue(thirdParty.contains { $0.deleteSubject.isAvailable },
                      "no store holding third-party data offers a subject delete")
    }

    func testRenderedTableCoversEveryCase() {
        let table = SensitiveStore.markdownTable()
        for store in SensitiveStore.allCases {
            XCTAssertTrue(table.contains("| \(store.rawValue) |"), "\(store.rawValue) missing from the matrix")
        }
        XCTAssertFalse(table.contains(FileManager.default.temporaryDirectory.path),
                       "the matrix must describe locations, never carry a live path")
    }

    // MARK: - The generated matrix

    private static let planPath = "docs/plans/ET-iso27701-privacy.md"
    private static let beginMarker = "<!-- BEGIN GENERATED: data-lifecycle-matrix -->"
    private static let endMarker = "<!-- END GENERATED: data-lifecycle-matrix -->"

    /// The privacy plan's data-lifecycle matrix is rendered from the registry, so the document
    /// cannot drift from the code. Run with `TEST_RUNNER_UPDATE_PLAN_DOCS=1` to rewrite it.
    func testPlanMatrixMatchesTheRegistry() throws {
        let url = Self.repoRoot.appendingPathComponent(Self.planPath)
        let document = try String(contentsOf: url, encoding: .utf8)
        guard let begin = document.range(of: Self.beginMarker),
              let end = document.range(of: Self.endMarker) else {
            return XCTFail("\(Self.planPath) has lost its generated-matrix markers")
        }

        let expected = "\n" + SensitiveStore.markdownTable() + "\n"
        let actual = String(document[begin.upperBound..<end.lowerBound])
        guard actual != expected else { return }

        if ProcessInfo.processInfo.environment["UPDATE_PLAN_DOCS"] != nil {
            let updated = document.replacingCharacters(
                in: begin.upperBound..<end.lowerBound, with: expected)
            try updated.write(to: url, atomically: true, encoding: .utf8)
            return
        }
        XCTFail("\(Self.planPath)'s data-lifecycle matrix is stale. Regenerate it with "
                + "TEST_RUNNER_UPDATE_PLAN_DOCS=1 on the xcodebuild invocation.")
    }

    // MARK: - Attribute truth
    //
    // The simulator does not reliably report file protection back, so protection is asserted only
    // where the platform answers. Backup exclusion is reported, so it is asserted unconditionally.

    private var workspace: URL!

    override func setUp() {
        super.setUp()
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("DataStoreRegistryTests_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: workspace)
        super.tearDown()
    }

    /// Compare one real file against the case that describes it.
    private func assertAttributes(of url: URL, match store: SensitiveStore,
                                  file: StaticString = #filePath, line: UInt = #line) throws {
        let record = store.record
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "\(store.rawValue): nothing was written to inspect", file: file, line: line)

        let excluded = (try url.resourceValues(forKeys: [.isExcludedFromBackupKey])).isExcludedFromBackup ?? false
        XCTAssertEqual(excluded, record.backupExcluded,
                       "\(store.rawValue): registry says backupExcluded=\(record.backupExcluded), "
                           + "the file says \(excluded)", file: file, line: line)

        guard let actual = try FileManager.default.attributesOfItem(atPath: url.path)[.protectionKey]
            as? FileProtectionType else { return }   // platform did not answer; nothing to compare
        let expected: FileProtectionType?
        switch record.protection {
        case .complete: expected = .complete
        case .completeUntilFirstUserAuthentication: expected = .completeUntilFirstUserAuthentication
        default: expected = nil                      // the registry claims no explicit attribute
        }
        if let expected {
            XCTAssertEqual(actual, expected, "\(store.rawValue): protection disagrees with the registry",
                           file: file, line: line)
        }
    }

    @MainActor
    func testConversationStoreAttributesMatchTheRegistry() throws {
        let store = ConversationStore(directory: workspace)
        _ = store.startThread(mode: "test")
        store.appendMessage(role: "user", content: "hello")
        try assertAttributes(of: workspace.appendingPathComponent("conversations.json"),
                             match: .conversationThreads)
    }

    @MainActor
    func testFaceDatabaseAttributesMatchTheRegistry() throws {
        let service = FaceRecognitionService(directory: workspace)
        _ = service.forgetFace(name: "nobody")   // forces a save of the (empty) database
        try assertAttributes(of: workspace.appendingPathComponent("known_faces.json"), match: .faces)
    }

    @MainActor
    func testSemanticMemoryDatabaseAttributesMatchTheRegistry() throws {
        let store = SemanticMemoryStore(directory: workspace)
        _ = store.remember("registry_probe", value: "value")
        try assertAttributes(of: workspace.appendingPathComponent("semantic_memory.sqlite"),
                             match: .semanticMemory)
    }

    @MainActor
    func testBrainGraphDatabaseAttributesMatchTheRegistry() throws {
        let store = BrainStore(directory: workspace)
        _ = store.upsertEntity(kind: "person", name: "Registry Probe")
        try assertAttributes(of: workspace.appendingPathComponent("brain.sqlite"), match: .brainGraph)
    }

    @MainActor
    func testUsageDatabaseAttributesMatchTheRegistry() throws {
        let url = workspace.appendingPathComponent("usage.sqlite")
        _ = UsageStore(path: url)
        try assertAttributes(of: url, match: .usage)
    }

    @MainActor
    func testOfflineQueueDatabaseAttributesMatchTheRegistry() throws {
        let url = workspace.appendingPathComponent("offline_queue.sqlite")
        _ = OfflineQueue(path: url)
        try assertAttributes(of: url, match: .offlineQueue)
    }

    @MainActor
    func testEvolvedSkillDatabaseAttributesMatchTheRegistry() throws {
        _ = EvolvedSkillStore(directory: workspace)
        try assertAttributes(of: workspace.appendingPathComponent("evolved_skills.sqlite"),
                             match: .evolvedSkills)
    }

    @MainActor
    func testAgentDocumentAttributesMatchTheRegistry() throws {
        let store = AgentDocumentStore(directory: workspace)
        store.save(.memory, content: "- probe")
        try assertAttributes(of: workspace.appendingPathComponent("memory.md"), match: .agentDocuments)
    }

    @MainActor
    func testOperationJournalAttributesMatchTheRegistry() throws {
        _ = ProtectedOperationJournal(directory: workspace)
        try assertAttributes(of: workspace.appendingPathComponent("operations.json"),
                             match: .operationJournal)
    }

    @MainActor
    func testDocumentCorpusDatabaseAttributesMatchTheRegistry() throws {
        _ = DocumentStore(directory: workspace)
        try assertAttributes(of: workspace.appendingPathComponent("documents.sqlite"),
                             match: .ragDocuments)
    }

    /// A database's `-wal` carries the rows that have not been checkpointed yet, so a posture that
    /// stops at the main file is not the posture the registry claims. W03.3 covers the siblings.
    @MainActor
    func testSQLiteSiblingsCarryTheSamePostureAsTheirDatabase() throws {
        let store = SemanticMemoryStore(directory: workspace)
        _ = store.remember("sibling_probe", value: "value")
        // Re-open: the first open created the database, this one runs with the WAL already there.
        _ = SemanticMemoryStore(directory: workspace)

        let database = workspace.appendingPathComponent("semantic_memory.sqlite")
        var inspected = 0
        for suffix in StoreProtection.sqliteSiblingSuffixes {
            let sibling = URL(fileURLWithPath: database.path + suffix)
            guard FileManager.default.fileExists(atPath: sibling.path) else { continue }
            inspected += 1
            let excluded = (try sibling.resourceValues(forKeys: [.isExcludedFromBackupKey]))
                .isExcludedFromBackup ?? false
            XCTAssertTrue(excluded, "\(sibling.lastPathComponent) is still backed up")
        }
        XCTAssertGreaterThan(inspected, 0, "sanity: WAL mode should have left a sibling to inspect")
    }

    /// The migration case: a database that already exists on a device with no attributes set gets
    /// the posture by being opened, not by being written to again.
    @MainActor
    func testOpeningAnExistingUnprotectedDatabaseAppliesThePosture() throws {
        let url = workspace.appendingPathComponent("usage.sqlite")
        // Stand in for the pre-W03.3 file: created by an older build, backed up, no attribute set.
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data()))
        var before = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = false
        try before.setResourceValues(values)
        XCTAssertFalse((try url.resourceValues(forKeys: [.isExcludedFromBackupKey]))
            .isExcludedFromBackup ?? false)

        _ = UsageStore(path: url)

        try assertAttributes(of: url, match: .usage)
    }

    /// Applying twice must not be a different answer from applying once — this is what makes the
    /// open-time call safe to run on every launch.
    func testApplyingThePostureIsIdempotent() throws {
        let url = workspace.appendingPathComponent("idempotent.sqlite")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8)))
        let first = StoreProtection.applyDatabase(at: url)
        let second = StoreProtection.applyDatabase(at: url)
        XCTAssertEqual(first, second)
        XCTAssertTrue(second.isClean)
        XCTAssertTrue((try url.resourceValues(forKeys: [.isExcludedFromBackupKey]))
            .isExcludedFromBackup ?? false)
    }

    func testApplyingThePostureToAnAbsentFileIsNotAFailure() {
        let outcome = StoreProtection.applyDatabase(
            at: workspace.appendingPathComponent("never-created.sqlite"))
        XCTAssertTrue(outcome.absent)
        XCTAssertEqual(outcome.applied, 0)
        XCTAssertEqual(outcome.failed, 0)
    }

    /// The rule W03.3 applied: a store the subject-erasure walk can reach must not also exist in a
    /// backup, because a backup is a copy the erasure cannot reach.
    func testEveryFileBackedStoreTheErasureWalkReachesIsExcludedFromBackup() {
        let exemptFromTheRule: Set<SensitiveStore> = [
            // Not file-backed by the app: an OS service and preference-backed stores, whose
            // exclusion is not the app's to set. Recorded here rather than quietly skipped.
            .spotlightIndex, .socialContext, .speakerNames, .contextualNotes, .objectMemory,
            // The wearer's own writing, deliberately left restorable; see the registry's note.
            .agentDocuments, .recordings, .capturedPhotos, .recordedSessions, .vaultLedger,
        ]
        for store in SubjectErasureCoordinator.order where !exemptFromTheRule.contains(store) {
            XCTAssertTrue(store.record.backupExcluded,
                          "\(store.rawValue) is reachable by a subject erasure but is still backed up")
        }
    }

    @MainActor
    func testStagedExportAttributesMatchTheRegistry() throws {
        let coordinator = StagedExportCoordinator(
            channel: .agentExport, rootDirectoryName: "unused",
            store: ProtectedExportFileStore(rootDirectoryName: "unused", root: workspace))
        let lease = try coordinator.makeLease(data: Data("x".utf8), fileExtension: "zip",
                                              displayName: "a.zip", fallbackName: "a.zip")
        try assertAttributes(of: lease.fileURL, match: .stagedExports)
        coordinator.release(lease)
    }
}
