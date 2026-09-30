import XCTest
@testable import OpenGlasses

/// Plan FY F2 — the assistant's default name follows the rename to Avenkin, on new installs and on
/// existing ones, without touching a name anybody chose.
///
/// Earlier builds stored the old default in two places: the first-run persona `Config.savedPersonas`
/// creates, and (in principle) the display-name preference. Changing `AssistantIdentity.defaultName`
/// alone would make that persona look like a name the wearer picked, so an existing install would
/// keep speaking under the old name. `isDefaultName(_:)` and the one-time migration close that.
///
/// The former name is spelled in pieces, as in `StorageIdentifierGuardTests`: the rename is a
/// find-and-replace, and written out whole these expectations would be rewritten along with the code.
final class AssistantNameMigrationTests: XCTestCase {

    private static let legacyName = "Open" + "Glasses"

    private let nameKey = "assistantDisplayName"
    private let personaKey = "activePersonaId"
    private let personasKey = "savedPersonas"
    private let presetKey = "activePromptPresetId"
    private let presetsKey = "savedPromptPresets"
    private let flagKey = "assistantNameMigratedToAvenkin_v1"

    private var saved: [String: Any?] = [:]

    private var allKeys: [String] { [nameKey, personaKey, personasKey, presetKey, presetsKey, flagKey] }

    override func setUp() {
        super.setUp()
        for key in allKeys {
            saved[key] = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    override func tearDown() {
        for key in allKeys {
            if let value = saved[key] ?? nil { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        saved = [:]
        super.tearDown()
    }

    private func persona(_ id: String, _ name: String, wake: String = "openglasses") -> Persona {
        Persona(id: id, name: name, wakePhrase: wake, alternativeWakePhrases: [], modelId: "",
                presetId: "preset-default", enabled: true)
    }

    private func storedPersonaNames() -> [String] {
        guard let data = UserDefaults.standard.data(forKey: personasKey),
              let personas = try? JSONDecoder().decode([Persona].self, from: data) else { return [] }
        return personas.map(\.name)
    }

    // MARK: - The values

    /// The former default must survive the rename script; if it were rewritten to the new name the
    /// migration would silently do nothing.
    func testTheDefaultIsAvenkinAndTheFormerDefaultIsStillRecognised() {
        XCTAssertEqual(AssistantIdentity.defaultName, "Avenkin")
        XCTAssertEqual(AssistantIdentity.legacyDefaultNames, [Self.legacyName],
                       "the former default must stay spelled as earlier builds stored it")
        XCTAssertTrue(AssistantIdentity.isDefaultName("Avenkin"))
        XCTAssertTrue(AssistantIdentity.isDefaultName(Self.legacyName))
        XCTAssertFalse(AssistantIdentity.isDefaultName("openglasses"), "exact match only")
        XCTAssertFalse(AssistantIdentity.isDefaultName("Aria"))
    }

    // MARK: - Fresh install

    func testAFreshInstallSpeaksAsAvenkin() {
        Config.migrateAssistantNameToAvenkinIfNeeded()
        XCTAssertNil(UserDefaults.standard.data(forKey: personasKey),
                     "the migration must not seed personas on a fresh install")

        let personas = Config.savedPersonas              // first-run seeding
        XCTAssertEqual(personas.map(\.name), ["Avenkin"])
        Config.setActivePersonaId(personas[0].id)
        XCTAssertEqual(Config.assistantName, "Avenkin")
        XCTAssertTrue(Config.defaultSystemPrompt.hasPrefix("You are Avenkin, "))
    }

    // MARK: - Existing install

    func testAnExistingInstallWithTheFirstRunPersonaSpeaksAsAndListsAvenkin() {
        let firstRun = persona("p-first-run", Self.legacyName)
        Config.setSavedPersonas([firstRun])
        Config.setActivePersonaId(firstRun.id)

        // Even before the migration has run, the former default is not a chosen name.
        XCTAssertEqual(Config.assistantName, "Avenkin")

        Config.migrateAssistantNameToAvenkinIfNeeded()

        XCTAssertEqual(storedPersonaNames(), ["Avenkin"], "the Personas list shows the new name")
        XCTAssertEqual(Config.assistantName, "Avenkin")
        let migrated = Config.savedPersonas[0]
        XCTAssertEqual(migrated.id, firstRun.id, "the persona is renamed, not replaced")
        XCTAssertEqual(migrated.wakePhrase, firstRun.wakePhrase,
                       "the wake phrase moves in its own migration (P3), not this one")
        XCTAssertTrue(Config.systemPrompt.hasPrefix("You are Avenkin, "))
    }

    func testAStoredFormerDefaultPreferenceIsCleared() {
        UserDefaults.standard.set(Self.legacyName, forKey: nameKey)
        Config.migrateAssistantNameToAvenkinIfNeeded()
        XCTAssertNil(UserDefaults.standard.object(forKey: nameKey))
        XCTAssertEqual(Config.assistantDisplayName, "Avenkin")
        XCTAssertEqual(Config.assistantName, "Avenkin")
    }

    func testAnyOtherPersonaOrTypedNameIsUntouched() {
        let others = [
            persona("p-jarvis", "Jarvis", wake: "hey jarvis"),
            persona("p-lower", "openglasses"),
            persona("p-longer", Self.legacyName + " Pro"),
        ]
        Config.setSavedPersonas(others)
        UserDefaults.standard.set("Aria", forKey: nameKey)

        Config.migrateAssistantNameToAvenkinIfNeeded()

        XCTAssertEqual(storedPersonaNames(), ["Jarvis", "openglasses", Self.legacyName + " Pro"])
        XCTAssertEqual(UserDefaults.standard.string(forKey: nameKey), "Aria")
        Config.setActivePersonaId("p-jarvis")
        XCTAssertEqual(Config.assistantName, "Jarvis")
    }

    func testTheMigrationRunsOnce() {
        Config.setSavedPersonas([persona("p-first-run", Self.legacyName)])
        Config.migrateAssistantNameToAvenkinIfNeeded()
        XCTAssertTrue(UserDefaults.standard.bool(forKey: flagKey))
        XCTAssertEqual(storedPersonaNames(), ["Avenkin"])

        // Someone who renames the persona back afterwards keeps it; a later launch does not
        // rewrite it again.
        Config.setSavedPersonas([persona("p-first-run", Self.legacyName)])
        UserDefaults.standard.set(Self.legacyName, forKey: nameKey)
        Config.migrateAssistantNameToAvenkinIfNeeded()
        XCTAssertEqual(storedPersonaNames(), [Self.legacyName])
        XCTAssertEqual(UserDefaults.standard.string(forKey: nameKey), Self.legacyName)
    }
}
