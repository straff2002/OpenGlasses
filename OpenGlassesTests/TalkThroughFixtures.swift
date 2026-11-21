import XCTest
@testable import OpenGlasses

/// Shared pieces for the talk-through tests (Plan JI §7a, P6b): an invented garden-pump procedure,
/// the running-procedure host over a real runner, a fake of the job's manuals, and a session wired
/// to live hints' fakes.

extension ProcedureRunnerHost: TalkThroughProcedureHost {
    var activeProcedure: Procedure? { runner?.procedure }
    var activeProcedureVisited: [String] { runner?.visited ?? [] }
}

@MainActor
final class FakeTalkThroughManuals: HintJobManualSource {
    var hintJobManuals: HintJobManuals? = HintJobManuals(vaultId: "garden", vaultName: "Garden pumps",
                                                         vaultOnly: false, citationsRequired: false)
    var result: ManualHintSearch = .passages([
        HintPassage(documentId: "pump-guide", documentName: "QMX90 Pump Guide", chunkIndex: 4,
                    text: "Tighten the priming cap by hand until it seats. Do not use a tool on the cap.",
                    citation: "QMX90 Pump Guide, page 12", page: 12),
    ])
    private(set) var queries: [String] = []

    func hintPassages(for question: String, limit: Int) -> ManualHintSearch {
        queries.append(question)
        return result
    }

    func hintManualTitles() -> [String] { ["QMX90 Pump Guide"] }
}

/// A similarity that knows two texts by their words, for tests that need the seam to matter.
@MainActor
final class FakeTalkThroughSimilarity: TalkThroughSimilarity {
    /// (sentence contains, step text contains) → similarity.
    var rules: [(sentence: String, step: String, value: Double)] = []
    private(set) var asked = 0

    func similarity(_ sentence: String, _ stepText: String) -> Double? {
        asked += 1
        for rule in rules where sentence.localizedCaseInsensitiveContains(rule.sentence)
            && stepText.localizedCaseInsensitiveContains(rule.step) {
            return rule.value
        }
        return rules.isEmpty ? nil : 0
    }
}

enum TalkThroughFixtures {

    /// An invented procedure: isolate → drain (expects a reading) → filter → prime (a calculation,
    /// two branches) → run (confirm at the end); reseal on the leak branch.
    static let procedureJSON = #"""
    {"id":"qmx_service","title":"Service the garden pump","version":"1","safety_notes":[],
     "entry_step":"isolate",
     "steps":[
      {"id":"isolate","title":"Isolate the pump",
       "instruction":"Turn the isolator off and unplug the lead.",
       "safety_note":"Unplug the lead before opening the housing.",
       "caution_phrases":["leave it plugged in","skip the isolator"],
       "default_next":"drain"},
      {"id":"drain","title":"Drain the chamber",
       "instruction":"Open the drain plug and let the chamber empty into a bucket.",
       "expected_input":"chamber empty",
       "default_next":"filter"},
      {"id":"filter","title":"Clean the filter basket",
       "instruction":"Lift out the filter basket and rinse the mesh under a tap.",
       "default_next":"prime"},
      {"id":"prime","title":"Prime the pump",
       "instruction":"Fill the priming chamber with water and close the priming cap hand-tight.",
       "calc_ref":{"tool":"domain_calc","op":"flow_rate","hint":"Flow is the bucket volume over the seconds it took to fill."},
       "branches":[{"id":"sealed","condition":"The cap holds water","next":"run"},
                   {"id":"leaking","condition":"Water weeps from the cap","next":"reseal"}],
       "default_next":"run"},
      {"id":"reseal","title":"Reseal the cap",
       "instruction":"Fit a new cap seal and close the cap again.",
       "default_next":"run"},
      {"id":"run","title":"Run the pump",
       "instruction":"Plug in, switch the isolator on and watch the outlet for a steady stream.",
       "terminal":true,"requires_confirmation":true,"outcome":"serviced"}
     ]}
    """#

    static func procedure() throws -> Procedure {
        try JSONDecoder().decode(Procedure.self, from: Data(procedureJSON.utf8))
    }

    /// A one-step procedure whose step takes a yes or no: the procedure needs every yes and no.
    static func yesNoProcedure() -> Procedure {
        Procedure(id: "qmx_check", title: "Check the outlet", version: "1", steps: [
            Procedure.Step(id: "outlet", title: "Check the outlet",
                           instruction: "Is water coming from the outlet?",
                           defaultNext: "rinse",
                           answer: StepAnswer(recordAs: "flowing", kind: .yesNo, label: "water flowing")),
            Procedure.Step(id: "rinse", title: "Rinse the filter basket",
                           instruction: "Rinse the filter basket under a tap.", defaultNext: "done"),
            Procedure.Step(id: "done", title: "Finish", instruction: "Put the lid back.", terminal: true,
                           outcome: "done"),
        ])
    }
}

/// A talk-through session over fakes and a real runner.
@MainActor
final class TalkThroughRig {
    let captions = FakeHintCaptions()
    let manuals = FakeTalkThroughManuals()
    let model = FakeHintModel()
    let lens = FakeHintLens()
    let ear = FakeHintEar()
    let voice = FakeHintVoiceActivity()
    let clock = FakeHintClock(now: Date(timeIntervalSinceReferenceDate: 810_000_000))
    let similarity: TalkThroughSimilarity
    let host: ProcedureRunnerHost
    let logger: SessionLogger
    let root: URL
    let service: TalkThroughService
    private(set) var onDeviceRequests: [Bool] = []

    init(procedure: Procedure? = nil, similarity: TalkThroughSimilarity? = nil,
         lensAvailable: Bool = false) throws {
        root = ProcedureAnswerFixtures.temporaryRoot("TalkThrough")
        logger = ProcedureAnswerFixtures.makeLogger(root: root)
        host = try ProcedureRunnerHost(procedure ?? TalkThroughFixtures.procedure(), logger: logger)
        let similarity = similarity ?? NoTalkThroughSimilarity()
        self.similarity = similarity
        lens.isAvailable = lensAvailable
        model.clock = clock
        service = TalkThroughService(carriers: .init(
            captions: captions, procedure: host, manuals: manuals, model: model, lens: lens, ear: ear,
            voiceActivity: voice, clock: clock, similarity: similarity))
        service.applyOnDeviceRecognition = { [unowned self] in self.onDeviceRequests.append($0) }
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    var visited: [String] { host.activeProcedureVisited }

    /// A finished sentence of narration, then a tick of the session's clock.
    func say(_ text: String) {
        clock.advance(by: 1, ticking: false)
        captions.say(text, at: clock.now)
        clock.advance(by: 0.1)
    }
}
