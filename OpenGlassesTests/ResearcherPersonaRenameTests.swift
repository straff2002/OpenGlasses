import XCTest
@testable import OpenGlasses

/// The Researcher mode shipped under a physicist's name. New installs get the new name from the
/// template; an existing install's untouched copy is renamed once, and anything the wearer changed
/// on it stays theirs.
final class ResearcherPersonaRenameTests: XCTestCase {

    private let personasKey = "savedPersonas"
    private let flagKey = "researcherPersonaRenamed_v1"
    private var saved: [String: Any?] = [:]

    override func setUp() {
        super.setUp()
        for key in [personasKey, flagKey] {
            saved[key] = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    override func tearDown() {
        for key in [personasKey, flagKey] {
            if let value = saved[key] ?? nil { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        saved = [:]
        super.tearDown()
    }

    private func store(_ personas: [Persona]) {
        UserDefaults.standard.set(try! JSONEncoder().encode(personas), forKey: personasKey)
    }

    private func stored() -> [Persona] {
        guard let data = UserDefaults.standard.data(forKey: personasKey) else { return [] }
        return (try? JSONDecoder().decode([Persona].self, from: data)) ?? []
    }

    private func shippedCopy(name: String = "Feynman",
                             alternatives: [String] = ["feynman mode", "hey feynman", "research mode"],
                             soul: String? = "You are Feynman — a rigorous research intelligence named after Richard Feynman.") -> Persona {
        Persona(id: "mode-feynman", name: name, wakePhrase: "hey researcher",
                alternativeWakePhrases: alternatives, modelId: "", presetId: "", enabled: true,
                icon: "atom", isBuiltIn: true, soulOverride: soul)
    }

    func testTemplateIsNamedResearcher() {
        let template = Config.builtInPersonaTemplates().first { $0.id == "mode-feynman" }
        XCTAssertEqual(template?.name, "Researcher")
        XCTAssertEqual(template?.wakePhrase, "hey researcher")
        XCTAssertEqual(template?.alternativeWakePhrases, Config.researcherAlternativeWakePhrases)
        XCTAssertEqual(template?.soulOverride, Config.researcherSoul)
        XCTAssertFalse(Config.researcherSoul.localizedCaseInsensitiveContains("feynman"))
        XCTAssertFalse(Config.researcherAlternativeWakePhrases.contains { $0.contains("feynman") })
    }

    func testUntouchedInstalledCopyIsRenamedWithSoulAndAlternatives() {
        store([shippedCopy()])
        Config.renameResearcherPersonaIfNeeded()
        let persona = stored().first
        XCTAssertEqual(persona?.name, "Researcher")
        XCTAssertEqual(persona?.alternativeWakePhrases, Config.researcherAlternativeWakePhrases)
        XCTAssertEqual(persona?.soulOverride, Config.researcherSoul)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: flagKey))
    }

    func testWearerEditsAreKept() {
        store([shippedCopy(alternatives: ["hey prof"], soul: "You are my study buddy.")])
        Config.renameResearcherPersonaIfNeeded()
        let persona = stored().first
        XCTAssertEqual(persona?.name, "Researcher", "the shipped name still moves")
        XCTAssertEqual(persona?.alternativeWakePhrases, ["hey prof"])
        XCTAssertEqual(persona?.soulOverride, "You are my study buddy.")
    }

    func testRenamedCopyAndOtherPersonasAreLeftAlone() {
        let other = Persona(id: "mode-golf", name: "Feynman", wakePhrase: "hey golf",
                            alternativeWakePhrases: [], modelId: "", presetId: "preset-golf-caddy", enabled: true)
        store([shippedCopy(name: "Dr F"), other])
        Config.renameResearcherPersonaIfNeeded()
        XCTAssertEqual(stored().map(\.name), ["Dr F", "Feynman"])
    }

    func testRunsOnce() {
        store([shippedCopy()])
        Config.renameResearcherPersonaIfNeeded()
        store([shippedCopy()])
        Config.renameResearcherPersonaIfNeeded()
        XCTAssertEqual(stored().first?.name, "Feynman", "second run is a no-op behind the flag")
    }
}
