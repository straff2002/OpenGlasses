import XCTest
@testable import OpenGlasses

/// Plan KY: which bottom strip each tab shows.
final class TabStripPolicyTests: XCTestCase {

    private func lead(_ tab: MainTab, _ edit: (inout TabStripFacts) -> Void = { _ in }) -> TabStripLead? {
        var facts = TabStripFacts()
        edit(&facts)
        return TabStripPolicy.lead(for: tab, facts: facts)
    }

    func testAvenkinAndSettingsCarryTheMicAlone() {
        XCTAssertNil(lead(.voice))
        XCTAssertNil(lead(.settings))
    }

    func testHistoryOffersANewConversationUnlessLocked() {
        XCTAssertEqual(lead(.chat), .newConversation)
        XCTAssertNil(lead(.chat) { $0.historyLocked = true })
    }

    func testJobsOffersNewJobOrTheOpenJobOnTheListOnly() {
        XCTAssertEqual(lead(.job), .newJob)
        XCTAssertEqual(lead(.job) { $0.jobOpen = true }, .openJob)
        XCTAssertNil(lead(.job) { $0.jobOpen = true; $0.jobsAtRoot = false })
        XCTAssertNil(lead(.job) { $0.jobsAtRoot = false })
    }

    func testFieldAssistAsksAManualWhenOneCanBeAsked() {
        XCTAssertEqual(lead(.modes) { $0.modesIsFieldAssist = true; $0.jobOpen = true; $0.askableManuals = 2 },
                       .askManual)
    }

    func testFieldAssistFallsBackToTheJobWhenNoManualCanBeAsked() {
        XCTAssertEqual(lead(.modes) { $0.modesIsFieldAssist = true }, .newJob)
        XCTAssertEqual(lead(.modes) { $0.modesIsFieldAssist = true; $0.jobOpen = true }, .openJob)
    }

    func testModesNamesTheActiveModeWhenThereIsOne() {
        XCTAssertNil(lead(.modes))
        XCTAssertEqual(lead(.modes) { $0.activeModeName = "Jarvis" }, .activeMode)
        XCTAssertEqual(TabStripLead.activeMode.title(modeName: "Jarvis"), "Jarvis")
    }

    func testTheStripStandsAsideForOnboardingTypingAndAnOpenConversation() {
        let none = TabStripFacts()
        for tab in MainTab.allCases {
            XCTAssertFalse(TabStripPolicy.showsStrip(on: tab, facts: none, onboarding: true, typingOnVoice: false),
                           "\(tab) during onboarding")
            XCTAssertTrue(TabStripPolicy.showsStrip(on: tab, facts: none, onboarding: false, typingOnVoice: false),
                          "\(tab) at rest")
        }
        XCTAssertFalse(TabStripPolicy.showsStrip(on: .voice, facts: none, onboarding: false, typingOnVoice: true))
        XCTAssertTrue(TabStripPolicy.showsStrip(on: .job, facts: none, onboarding: false, typingOnVoice: true),
                      "typing on Avenkin is Avenkin's alone")
        var thread = TabStripFacts()
        thread.historyThreadOpen = true
        XCTAssertFalse(TabStripPolicy.showsStrip(on: .chat, facts: thread, onboarding: false, typingOnVoice: false))
        XCTAssertTrue(TabStripPolicy.showsStrip(on: .settings, facts: thread, onboarding: false, typingOnVoice: false))
    }

    func testEveryActionHasASymbolAndWords() {
        for lead in TabStripLead.allCases {
            XCTAssertFalse(lead.systemImage.isEmpty)
            XCTAssertFalse(lead.title(modeName: nil).isEmpty)
        }
    }
}
