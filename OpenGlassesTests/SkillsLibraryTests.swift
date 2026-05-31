import XCTest
@testable import OpenGlasses

/// Plan Q, Slice 3: skills-library export/import. ClawHub imports must arrive **disabled** (their
/// content is injected into the system prompt); voice skills round-trip through the versioned envelope.
@MainActor
final class SkillsLibraryTests: XCTestCase {

    private let clawSlug = "plan-q-test-skill"
    private let voiceTrigger = "plan q test trigger"

    override func tearDown() {
        InstalledSkillStore.shared.uninstall(slug: clawSlug)
        _ = VoiceSkillStore.shared.delete(trigger: voiceTrigger)
        super.tearDown()
    }

    func testImportedClawHubSkillsArriveDisabled() throws {
        let store = InstalledSkillStore.shared
        store.uninstall(slug: clawSlug)

        // Exported file claims the skill is enabled — import must NOT trust that.
        let item = InstalledSkillStore.InstalledSkill(
            slug: clawSlug, name: "Test Skill", description: "desc", version: "1.0.0",
            content: "---\nname: test\n---\nDo a thing.", compatibility: .compatible,
            installedAt: Date(), enabled: true)
        let data = try SkillsLibraryIO.encoder().encode(SkillsLibraryEnvelope(items: [item]))

        let count = try store.importLibrary(data)
        XCTAssertEqual(count, 1)
        let imported = try XCTUnwrap(store.installedSkills.first { $0.slug == clawSlug })
        XCTAssertFalse(imported.enabled, "Imported skills must be disabled pending review.")
    }

    func testClawHubPreviewDoesNotMutateStore() throws {
        let store = InstalledSkillStore.shared
        store.uninstall(slug: clawSlug)
        let item = InstalledSkillStore.InstalledSkill(
            slug: clawSlug, name: "Test", description: "d", version: "1.0.0",
            content: "Body", compatibility: .compatible, installedAt: Date(), enabled: false)
        let data = try SkillsLibraryIO.encoder().encode(SkillsLibraryEnvelope(items: [item]))

        let preview = try store.previewImport(data)
        XCTAssertEqual(preview.count, 1)
        XCTAssertFalse(store.isInstalled(clawSlug), "Preview must not install anything.")
    }

    func testVoiceSkillsRoundTrip() throws {
        let store = VoiceSkillStore.shared
        _ = store.delete(trigger: voiceTrigger)

        let skill = VoiceSkill(id: UUID().uuidString, trigger: voiceTrigger,
                               instruction: "do thing", createdAt: Date())
        let data = try SkillsLibraryIO.encoder().encode(SkillsLibraryEnvelope(items: [skill]))

        XCTAssertEqual(try store.importLibrary(data), 1)
        XCTAssertTrue(store.all().contains { $0.trigger == voiceTrigger })

        let exported = try store.exportLibraryData()
        let decoded = try SkillsLibraryIO.decoder().decode(SkillsLibraryEnvelope<VoiceSkill>.self, from: exported)
        XCTAssertEqual(decoded.schemaVersion, SkillsLibraryIO.schemaVersion)
        XCTAssertTrue(decoded.items.contains { $0.trigger == voiceTrigger })
    }
}
