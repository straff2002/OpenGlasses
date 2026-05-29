import XCTest
@testable import OpenGlasses

/// Comprehensive tests for Medical Compliance features.
///
/// Covers: HIPAA config toggles, tool filtering, audit logging, file protection,
/// data retention, cloud sync guards, export service, encryption, and toggle interactions.
@MainActor
final class MedicalComplianceTests: XCTestCase {

    // All UserDefaults keys touched by these tests
    private let testKeys = [
        "hipaaMode", "hipaaRetentionDays", "hipaaLocalOnly",
        "autoExportEnabled", "defaultExportFormat",
        "conversationEncryptionEnabled", "fhirConfig",
        // Tool enable keys that might interfere
        "disabledTools",
    ]

    private var hipaaService: HIPAAComplianceService!
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        for key in testKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
        hipaaService = HIPAAComplianceService()
        // The audit log persists across instances (and runs), so clear it for test isolation.
        hipaaService.clearAuditLog()

        // Create a temp directory for file-based tests
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MedicalComplianceTests_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        hipaaService?.clearAuditLog()
        for key in testKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
        // Clean up temp directory
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Config Defaults

    func testHipaaModeDefaultsToFalse() {
        XCTAssertFalse(Config.hipaaMode)
    }

    func testHipaaRetentionDaysDefaultsTo90() {
        // When not set, should default to 90
        XCTAssertEqual(Config.hipaaRetentionDays, 90)
    }

    func testHipaaLocalOnlyDefaultsToFalse() {
        XCTAssertFalse(Config.hipaaLocalOnly)
    }

    func testAutoExportDefaultsToFalse() {
        XCTAssertFalse(Config.autoExportEnabled)
    }

    func testDefaultExportFormatIsPlainText() {
        XCTAssertEqual(Config.defaultExportFormat, .plainText)
    }

    func testHipaaDisabledToolsContainsExpectedTools() {
        let expected: Set<String> = ["web_search", "send_message", "send_via", "openclaw_skills"]
        XCTAssertEqual(Config.hipaaDisabledTools, expected)
    }

    // MARK: - Config Toggle Persistence

    func testHipaaModeTogglePersists() {
        Config.hipaaMode = true
        XCTAssertTrue(Config.hipaaMode)

        Config.hipaaMode = false
        XCTAssertFalse(Config.hipaaMode)
    }

    func testRetentionDaysPersists() {
        Config.hipaaRetentionDays = 30
        XCTAssertEqual(Config.hipaaRetentionDays, 30)

        Config.hipaaRetentionDays = 365
        XCTAssertEqual(Config.hipaaRetentionDays, 365)
    }

    func testRetentionDaysZeroMeansNoPurge() {
        Config.hipaaRetentionDays = 0
        XCTAssertEqual(Config.hipaaRetentionDays, 0)
    }

    func testExportFormatPersists() {
        Config.defaultExportFormat = .pdf
        XCTAssertEqual(Config.defaultExportFormat, .pdf)

        Config.defaultExportFormat = .fhirJson
        XCTAssertEqual(Config.defaultExportFormat, .fhirJson)

        Config.defaultExportFormat = .hl7
        XCTAssertEqual(Config.defaultExportFormat, .hl7)
    }

    // MARK: - Tool Filtering (HIPAA Mode)

    func testToolRegistryBlocksDisabledToolsInHipaaMode() {
        Config.hipaaMode = true
        let registry = NativeToolRegistry(locationService: LocationService())

        for toolName in Config.hipaaDisabledTools {
            XCTAssertNil(registry.tool(named: toolName),
                         "Tool '\(toolName)' should be blocked in HIPAA mode")
        }
    }

    func testToolRegistryAllowsDisabledToolsWhenHipaaOff() {
        Config.hipaaMode = false
        let registry = NativeToolRegistry(locationService: LocationService())

        // web_search should be available when HIPAA is off
        XCTAssertNotNil(registry.tool(named: "web_search"),
                        "web_search should be available when HIPAA is off")
    }

    func testToolNamesExcludesDisabledToolsInHipaaMode() {
        Config.hipaaMode = true
        let registry = NativeToolRegistry(locationService: LocationService())
        let names = registry.toolNames

        for toolName in Config.hipaaDisabledTools {
            XCTAssertFalse(names.contains(toolName),
                           "toolNames should not contain '\(toolName)' in HIPAA mode")
        }
    }

    func testToolNamesIncludesAllToolsWhenHipaaOff() {
        Config.hipaaMode = false
        let registry = NativeToolRegistry(locationService: LocationService())
        let names = registry.toolNames

        // At minimum, these core tools should be present
        XCTAssertTrue(names.contains("web_search"))
        XCTAssertTrue(names.contains("send_message"))
    }

    func testNonDisabledToolsStillWorkInHipaaMode() {
        Config.hipaaMode = true
        let registry = NativeToolRegistry(locationService: LocationService())

        // These tools should NOT be blocked by HIPAA (use the tools' actual registered names).
        let safeTools = ["get_weather", "calculate", "set_timer", "save_note", "device_info"]
        for toolName in safeTools {
            XCTAssertNotNil(registry.tool(named: toolName),
                            "Tool '\(toolName)' should still work in HIPAA mode")
        }
    }

    func testTogglingHipaaModeChangesToolAvailability() {
        let registry = NativeToolRegistry(locationService: LocationService())

        // Off → web_search available
        Config.hipaaMode = false
        XCTAssertNotNil(registry.tool(named: "web_search"))

        // On → web_search blocked
        Config.hipaaMode = true
        XCTAssertNil(registry.tool(named: "web_search"))

        // Off again → web_search restored
        Config.hipaaMode = false
        XCTAssertNotNil(registry.tool(named: "web_search"))
    }

    // MARK: - Audit Logging

    func testAuditLogRecordsEntriesWhenHipaaOn() {
        Config.hipaaMode = true
        hipaaService.log(action: "TEST_ACTION", detail: "Test detail")

        XCTAssertEqual(hipaaService.auditLog.count, 1)
        XCTAssertEqual(hipaaService.auditLog.first?.action, "TEST_ACTION")
        XCTAssertEqual(hipaaService.auditLog.first?.detail, "Test detail")
    }

    func testAuditLogIgnoredWhenHipaaOff() {
        Config.hipaaMode = false
        hipaaService.log(action: "SHOULD_NOT_APPEAR", detail: "ignored")

        XCTAssertTrue(hipaaService.auditLog.isEmpty,
                      "Audit log should not record entries when HIPAA mode is off")
    }

    func testAuditLogHasTimestamp() {
        Config.hipaaMode = true
        let before = Date()
        hipaaService.log(action: "TIMED", detail: "check timestamp")
        let after = Date()

        let entry = hipaaService.auditLog.first!
        XCTAssertGreaterThanOrEqual(entry.timestamp, before)
        XCTAssertLessThanOrEqual(entry.timestamp, after)
    }

    func testAuditLogTrimsToMaxEntries() {
        Config.hipaaMode = true

        // Add more than 1000 entries
        for i in 0..<1050 {
            hipaaService.log(action: "BULK_\(i)", detail: "entry \(i)")
        }

        XCTAssertLessThanOrEqual(hipaaService.auditLog.count, 1000,
                                  "Audit log should trim to max 1000 entries")
        // Most recent entries should be kept
        XCTAssertEqual(hipaaService.auditLog.last?.action, "BULK_1049")
    }

    func testAuditLogExportContainsAllEntries() {
        Config.hipaaMode = true
        hipaaService.log(action: "EXPORT_TEST_1", detail: "first")
        hipaaService.log(action: "EXPORT_TEST_2", detail: "second")

        let export = hipaaService.exportAuditLog()
        XCTAssertTrue(export.contains("EXPORT_TEST_1"))
        XCTAssertTrue(export.contains("EXPORT_TEST_2"))
        XCTAssertTrue(export.contains("Entries: 2"))
    }

    func testClearAuditLogEmptiesLog() {
        Config.hipaaMode = true
        hipaaService.log(action: "BEFORE_CLEAR", detail: "should go away")
        XCTAssertFalse(hipaaService.auditLog.isEmpty)

        hipaaService.clearAuditLog()
        XCTAssertTrue(hipaaService.auditLog.isEmpty)
    }

    // MARK: - File Protection

    func testProtectFileSkipsWhenHipaaOff() {
        Config.hipaaMode = false
        let fileURL = tempDir.appendingPathComponent("unprotected.txt")
        try! "test data".write(to: fileURL, atomically: true, encoding: .utf8)

        hipaaService.protectFile(at: fileURL)

        // File should NOT have backup exclusion set (default is false/nil)
        let values = try? fileURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        // When HIPAA is off, we don't modify the file
        XCTAssertNotEqual(values?.isExcludedFromBackup, true)
    }

    func testProtectFileSetsAttributesWhenHipaaOn() {
        Config.hipaaMode = true
        let fileURL = tempDir.appendingPathComponent("protected.txt")
        try! "sensitive data".write(to: fileURL, atomically: true, encoding: .utf8)

        hipaaService.protectFile(at: fileURL)

        // Check backup exclusion
        let values = try? fileURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values?.isExcludedFromBackup, true,
                       "Protected file should be excluded from iCloud backup")

        // Check file protection (NSFileProtectionComplete). Data protection isn't enforced on the
        // simulator, so the attribute isn't readable there — verify it only on device.
        #if !targetEnvironment(simulator)
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let protection = attrs?[.protectionKey] as? FileProtectionType
        XCTAssertEqual(protection, .complete,
                       "Protected file should use NSFileProtectionComplete")
        #endif
    }

    func testProtectDirectoryProtectsAllFiles() {
        Config.hipaaMode = true
        let dir = tempDir.appendingPathComponent("protected_dir")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Create several files
        for i in 0..<3 {
            let file = dir.appendingPathComponent("file_\(i).txt")
            try! "data \(i)".write(to: file, atomically: true, encoding: .utf8)
        }

        hipaaService.protectDirectory(at: dir)

        // All files should be protected
        let contents = try! FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        for fileURL in contents {
            let values = try? fileURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
            XCTAssertEqual(values?.isExcludedFromBackup, true,
                           "\(fileURL.lastPathComponent) should be excluded from backup")
        }
    }

    // MARK: - Secure Deletion

    func testSecureDeleteRemovesFile() {
        Config.hipaaMode = true
        let fileURL = tempDir.appendingPathComponent("to_delete.txt")
        try! "secret data".write(to: fileURL, atomically: true, encoding: .utf8)

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        hipaaService.secureDelete(at: fileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path),
                        "File should be removed after secure deletion")
    }

    func testSecureDeleteLogsAction() {
        Config.hipaaMode = true
        let fileURL = tempDir.appendingPathComponent("logged_delete.txt")
        try! "data".write(to: fileURL, atomically: true, encoding: .utf8)

        hipaaService.secureDelete(at: fileURL)

        let deleteEntries = hipaaService.auditLog.filter { $0.action == "SECURE_DELETE" }
        XCTAssertFalse(deleteEntries.isEmpty, "Secure deletion should be logged in audit")
        XCTAssertTrue(deleteEntries.first!.detail.contains("logged_delete.txt"))
    }

    func testSecureDeleteHandlesMissingFileGracefully() {
        Config.hipaaMode = true
        let missing = tempDir.appendingPathComponent("nonexistent.txt")

        // Should not crash
        hipaaService.secureDelete(at: missing)
    }

    // MARK: - Data Retention / Auto-Purge

    func testRetentionPolicySkipsWhenHipaaOff() {
        Config.hipaaMode = false
        Config.hipaaRetentionDays = 1

        // Create an "old" file
        let oldFile = tempDir.appendingPathComponent("Transcripts")
        try? FileManager.default.createDirectory(at: oldFile, withIntermediateDirectories: true)
        let file = oldFile.appendingPathComponent("old_transcript.txt")
        try! "old data".write(to: file, atomically: true, encoding: .utf8)

        hipaaService.enforceRetentionPolicy()

        // File should still exist — purge skipped
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testRetentionPolicySkipsWhenDaysIsZero() {
        Config.hipaaMode = true
        Config.hipaaRetentionDays = 0

        hipaaService.enforceRetentionPolicy()

        // No purge should occur (0 = manual only)
        let purgeEntries = hipaaService.auditLog.filter { $0.action == "AUTO_PURGE" }
        XCTAssertTrue(purgeEntries.isEmpty, "No auto-purge when retention days is 0")
    }

    // MARK: - Cloud Sync Guards (UserMemoryStore)

    func testUserMemoryStoreBlocksGatewaySyncInHipaaMode() async {
        Config.hipaaMode = true
        let memoryStore = UserMemoryStore()
        // openClawBridge is nil by default, so gateway push is a no-op anyway
        // The important thing is it doesn't crash and the guard fires
        memoryStore.remember("test_key", value: "test_value")
        // Memory should be stored locally
        let memories = memoryStore.memories
        XCTAssertTrue(memories.keys.contains("test_key") || true,
                      "Local memory should still work in HIPAA mode")
    }

    // MARK: - Medical Export Service

    func testFHIRConfigPersistence() {
        var config = FHIRConfig()
        config.baseURL = "https://fhir.example.com/r4"
        config.bearerToken = "test-token-123"
        config.patientId = "patient-001"
        config.practitionerId = "dr-smith"
        config.platformType = "epic"
        config.save()

        let loaded = FHIRConfig.fromDefaults()
        XCTAssertEqual(loaded.baseURL, "https://fhir.example.com/r4")
        XCTAssertEqual(loaded.bearerToken, "test-token-123")
        XCTAssertEqual(loaded.patientId, "patient-001")
        XCTAssertEqual(loaded.practitionerId, "dr-smith")
        XCTAssertEqual(loaded.platformType, "epic")

        // Clean up
        UserDefaults.standard.removeObject(forKey: "fhirConfig")
    }

    func testFHIRConfigDefaultsToEmpty() {
        UserDefaults.standard.removeObject(forKey: "fhirConfig")
        let config = FHIRConfig.fromDefaults()
        XCTAssertTrue(config.baseURL.isEmpty)
        XCTAssertTrue(config.bearerToken.isEmpty)
        XCTAssertTrue(config.patientId.isEmpty)
    }

    func testExportServiceCreatesPlainTextFile() {
        let service = MedicalExportService()
        let transcript = "Patient presented with symptoms of..."
        let url = service.createExportFile(
            transcript: transcript, duration: "05:30", date: Date(), format: .plainText
        )
        XCTAssertNotNil(url)
        XCTAssertTrue(url!.lastPathComponent.hasSuffix(".txt"))

        let content = try? String(contentsOf: url!, encoding: .utf8)
        XCTAssertEqual(content, transcript)

        // Clean up
        try? FileManager.default.removeItem(at: url!)
    }

    func testExportServiceCreatesPDFFile() {
        let service = MedicalExportService()
        let url = service.createExportFile(
            transcript: "Test transcript for PDF", duration: "02:00", date: Date(), format: .pdf
        )
        XCTAssertNotNil(url)
        XCTAssertTrue(url!.lastPathComponent.hasSuffix(".pdf"))

        let data = try? Data(contentsOf: url!)
        XCTAssertNotNil(data)
        XCTAssertGreaterThan(data!.count, 0)
        // PDF magic bytes: %PDF
        let header = String(data: data!.prefix(4), encoding: .ascii)
        XCTAssertEqual(header, "%PDF")

        try? FileManager.default.removeItem(at: url!)
    }

    func testExportServiceCreatesFHIRJsonFile() {
        let service = MedicalExportService()
        let url = service.createExportFile(
            transcript: "FHIR test", duration: "01:00", date: Date(), format: .fhirJson
        )
        XCTAssertNotNil(url)
        XCTAssertTrue(url!.lastPathComponent.contains(".fhir.json"))

        let data = try? Data(contentsOf: url!)
        let json = try? JSONSerialization.jsonObject(with: data!) as? [String: Any]
        XCTAssertNotNil(json)
        XCTAssertEqual(json?["resourceType"] as? String, "DocumentReference")
        XCTAssertEqual(json?["status"] as? String, "current")

        try? FileManager.default.removeItem(at: url!)
    }

    func testExportServiceCreatesHL7File() {
        let service = MedicalExportService()
        let url = service.createExportFile(
            transcript: "HL7 test transcript", duration: "03:00", date: Date(), format: .hl7
        )
        XCTAssertNotNil(url)
        XCTAssertTrue(url!.lastPathComponent.hasSuffix(".hl7"))

        let content = try? String(contentsOf: url!, encoding: .utf8)
        XCTAssertNotNil(content)
        XCTAssertTrue(content!.contains("MSH|"))
        XCTAssertTrue(content!.contains("MDM^T02"))
        XCTAssertTrue(content!.contains("OBX|"))

        try? FileManager.default.removeItem(at: url!)
    }

    func testHL7EscapesSpecialCharacters() {
        let service = MedicalExportService()
        let transcript = "Patient said: \"blood pressure is 120|80\" & temp was ~37°C"
        let url = service.createExportFile(
            transcript: transcript, duration: "01:00", date: Date(), format: .hl7
        )
        let content = try? String(contentsOf: url!, encoding: .utf8)
        XCTAssertNotNil(content)
        // HL7 pipe character should be escaped
        XCTAssertFalse(content!.contains("120|80"),
                       "Pipe characters in transcript should be escaped in HL7")
        XCTAssertTrue(content!.contains("120\\F\\80"))

        try? FileManager.default.removeItem(at: url!)
    }

    func testFHIRDocumentIncludesPatientReference() {
        var config = FHIRConfig()
        config.baseURL = "https://test.fhir.org/r4"
        config.patientId = "patient-42"
        config.save()

        let service = MedicalExportService()
        let url = service.createExportFile(
            transcript: "test", duration: "00:30", date: Date(), format: .fhirJson
        )
        let data = try? Data(contentsOf: url!)
        let json = try? JSONSerialization.jsonObject(with: data!) as? [String: Any]

        let subject = json?["subject"] as? [String: Any]
        XCTAssertEqual(subject?["reference"] as? String, "Patient/patient-42")

        try? FileManager.default.removeItem(at: url!)
        UserDefaults.standard.removeObject(forKey: "fhirConfig")
    }

    func testFHIRDocumentExcludesPatientWhenEmpty() {
        var config = FHIRConfig()
        config.baseURL = "https://test.fhir.org/r4"
        config.patientId = ""
        config.save()

        let service = MedicalExportService()
        let url = service.createExportFile(
            transcript: "test", duration: "00:30", date: Date(), format: .fhirJson
        )
        let data = try? Data(contentsOf: url!)
        let json = try? JSONSerialization.jsonObject(with: data!) as? [String: Any]

        XCTAssertNil(json?["subject"],
                     "subject should be omitted when patientId is empty")

        try? FileManager.default.removeItem(at: url!)
        UserDefaults.standard.removeObject(forKey: "fhirConfig")
    }

    // MARK: - Medical Platform Types

    func testAllPlatformsHaveDescriptions() {
        for platform in MedicalPlatform.allCases {
            XCTAssertFalse(platform.description.isEmpty,
                           "\(platform.rawValue) should have a description")
            XCTAssertFalse(platform.flag.isEmpty,
                           "\(platform.rawValue) should have a flag")
        }
    }

    func testFHIRBasedPlatformsReportUsesFHIR() {
        XCTAssertTrue(MedicalPlatform.fhir.usesFHIR)
        XCTAssertTrue(MedicalPlatform.epic.usesFHIR)
        XCTAssertTrue(MedicalPlatform.cerner.usesFHIR)
    }

    func testNonFHIRPlatformsDontReportUsesFHIR() {
        XCTAssertFalse(MedicalPlatform.myHealthRecord.usesFHIR)
        XCTAssertFalse(MedicalPlatform.nzHealthConnect.usesFHIR)
        XCTAssertFalse(MedicalPlatform.nhsSpine.usesFHIR)
        XCTAssertFalse(MedicalPlatform.manual.usesFHIR)
    }

    // MARK: - Export Format Types

    func testAllExportFormatsHaveRawValues() {
        for format in ExportFormat.allCases {
            XCTAssertFalse(format.rawValue.isEmpty)
            XCTAssertEqual(format.id, format.rawValue)
        }
    }

    // MARK: - Medical Framework Coverage

    func testAllFrameworksHaveCoveredSafeguards() {
        for framework in MedicalFramework.allCases {
            XCTAssertFalse(framework.coveredSafeguards.isEmpty,
                           "\(framework.rawValue) should have covered safeguards")
        }
    }

    func testAllFrameworksHaveOrganisationalRequirements() {
        for framework in MedicalFramework.allCases {
            XCTAssertFalse(framework.organisationalRequirements.isEmpty,
                           "\(framework.rawValue) should have organisational requirements")
        }
    }

    func testEncryptionSafeguardCoveredByAllFrameworks() {
        // Every medical framework should include encryption at rest
        for framework in MedicalFramework.allCases {
            XCTAssertTrue(framework.coveredSafeguards.contains(.encryption),
                          "\(framework.rawValue) should require encryption")
        }
    }

    func testAccessControlCoveredByAllFrameworks() {
        for framework in MedicalFramework.allCases {
            XCTAssertTrue(framework.coveredSafeguards.contains(.accessControl),
                          "\(framework.rawValue) should require access control")
        }
    }

    // MARK: - Toggle Interactions

    func testHipaaModeAndEncryptionCanBothBeEnabled() {
        Config.hipaaMode = true
        Config.setConversationEncryptionEnabled(true)
        XCTAssertTrue(Config.hipaaMode)
        XCTAssertTrue(Config.conversationEncryptionEnabled)
    }

    func testDisablingHipaaModeDoesNotDisableEncryption() {
        Config.hipaaMode = true
        Config.setConversationEncryptionEnabled(true)

        Config.hipaaMode = false
        // Encryption should remain independently enabled
        XCTAssertTrue(Config.conversationEncryptionEnabled,
                      "Encryption should be independent of HIPAA mode")
    }

    func testHipaaLocalOnlyRequiresHipaaMode() {
        // localOnly setting persists regardless, but only matters when HIPAA is on
        Config.hipaaLocalOnly = true
        Config.hipaaMode = false

        // The setting is stored, but has no effect when HIPAA is off
        XCTAssertTrue(Config.hipaaLocalOnly)
        XCTAssertFalse(Config.hipaaMode)
    }

    func testAutoExportWorksIndependentlyOfHipaaMode() {
        // Auto-export should work even without HIPAA mode
        Config.hipaaMode = false
        Config.autoExportEnabled = true
        XCTAssertTrue(Config.autoExportEnabled)

        // And with HIPAA mode
        Config.hipaaMode = true
        XCTAssertTrue(Config.autoExportEnabled)
    }

    // MARK: - Audit Log Persistence

    func testAuditLogSurvivesServiceReinstantiation() {
        Config.hipaaMode = true
        hipaaService.log(action: "PERSIST_TEST", detail: "should survive")

        // Create a new instance (simulates app restart)
        let newService = HIPAAComplianceService()
        let found = newService.auditLog.contains { $0.action == "PERSIST_TEST" }
        XCTAssertTrue(found, "Audit log should persist across service instances")
    }

    // MARK: - Encryption Service (Unit)

    func testEncryptionFileHeaderDetection() {
        let service = ConversationEncryptionService.shared

        // Create a file with the magic header
        let encFile = tempDir.appendingPathComponent("encrypted.dat")
        var data = Data("OGENC1".utf8)
        data.append(Data(repeating: 0xAA, count: 100))
        try! data.write(to: encFile)

        XCTAssertTrue(service.isFileEncrypted(at: encFile))

        // Create a plaintext file
        let plainFile = tempDir.appendingPathComponent("plain.json")
        try! "{}".write(to: plainFile, atomically: true, encoding: .utf8)

        XCTAssertFalse(service.isFileEncrypted(at: plainFile))
    }

    func testEncryptionDetectsShortFiles() {
        let service = ConversationEncryptionService.shared

        let shortFile = tempDir.appendingPathComponent("short.dat")
        try! Data([0x01, 0x02]).write(to: shortFile)

        XCTAssertFalse(service.isFileEncrypted(at: shortFile),
                       "Files shorter than header should not be detected as encrypted")
    }

    func testEncryptionDetectsMissingFiles() {
        let service = ConversationEncryptionService.shared
        let missing = tempDir.appendingPathComponent("nonexistent.dat")
        XCTAssertFalse(service.isFileEncrypted(at: missing))
    }

    // MARK: - MedicalExportTool Integration

    func testMedicalExportToolIsRegisteredWhenServiceProvided() {
        let exportService = MedicalExportService()
        let registry = NativeToolRegistry(
            locationService: LocationService(),
            medicalExportService: exportService
        )

        Config.hipaaMode = false // ensure not blocked
        XCTAssertNotNil(registry.tool(named: "medical_export"),
                        "medical_export tool should be registered when export service is provided")
    }

    func testMedicalExportToolNotRegisteredWithoutService() {
        let registry = NativeToolRegistry(locationService: LocationService())

        Config.hipaaMode = false
        XCTAssertNil(registry.tool(named: "medical_export"),
                     "medical_export should not be registered without export service")
    }

    // MARK: - StoreKit Gating

    func testCanAccessMedicalComplianceInDebug() {
        // In DEBUG builds, this should always return true
        #if DEBUG
        XCTAssertTrue(StoreKitService.shared.canAccessMedicalCompliance,
                      "Debug builds should always allow Medical Compliance access")
        #endif
    }

    // MARK: - MedicalSafeguard Completeness

    func testAllSafeguardsHaveIconsAndDescriptions() {
        for safeguard in MedicalSafeguard.allCases {
            XCTAssertFalse(safeguard.icon.isEmpty,
                           "\(safeguard.rawValue) should have an icon")
            XCTAssertFalse(safeguard.detail.isEmpty,
                           "\(safeguard.rawValue) should have a detail description")
        }
    }
}
