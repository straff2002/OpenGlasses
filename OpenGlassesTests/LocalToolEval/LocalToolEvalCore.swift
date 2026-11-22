import Foundation
#if canImport(OpenGlasses)
@testable import OpenGlasses
#endif

/// The local-model tool eval (Plan MQ P0): a versioned corpus, deterministic graders, and a runner
/// that plays a case through the **shipped** `LocalToolLoop`, `LocalOutputPolicy` parser,
/// `OnDeviceArgumentCoercion` and `ManualReadingCheck`.
///
/// The corpus is generated from the Lennox SLP99 example vault by
/// `Scripts/local-tool-eval/generate-corpus.py`, and is mostly Field Assist job turns: running
/// Field Assist on a downloaded model is the point (it is what saves the cloud cost), so a report
/// counts the Field Assist group first and on its own, with the everyday group beside it.
///
/// One core, two runners, one copy. `LocalToolEvalCorpusTests` plays every case's `reference`
/// output through a scripted fake model in CI. The device qualification app
/// (`Scripts/local-model-qualification`, Plan MQ P3) compiles **this file** (and the other files in
/// this folder it lists) and hands the same cases, assembled the same way, to a real model on a
/// phone: only `Environment`'s generation closures differ, so CI and the phone grade identically.
///
/// A reading case (a manual answer, or a question the manual does not answer) asks the model to
/// read passages and return a reading (`Reader`), which `ManualReadingCheck` accepts or declines.
/// CI's scripted model returns the case's scripted reading in that format. A near-miss twin
/// (`Case.isCheckOnly`) tests the check, not a model: its question and passages are the answered
/// case's, so a live runner skips it.
///
/// **Nothing here prints a turn, a passage or an answer.** As in `RetrievalEval`: a report is
/// counts per category and grader, and a bootstrap interval on each pass rate, so it can be pasted
/// into a plan or a PR.
enum LocalToolEval {

    static let corpusVersion = 2
    static let corpusFileName = "local-tool-corpus.v2.jsonl"

    // MARK: - The corpus

    enum Category: String, Decodable, CaseIterable, Sendable {
        case toolChoice, restraint, manualAnswer, notInManual, twoStep, longPrompt, multiTurn, cleanOutput,
             cancellation
    }

    /// Which question a case answers for qualification. Field Assist on a downloaded model is judged
    /// first and on its own; the everyday group (small talk, chatter, the time) sits beside it.
    enum Group: String, Decodable, CaseIterable, Sendable {
        case fieldAssist, everyday
    }

    struct Turn: Decodable, Equatable {
        let role: String
        let content: String
    }

    struct ExpectedCall: Decodable, Equatable {
        let tool: String
        /// Argument names that must be present.
        let required: [String]
        /// Argument values that must match, compared after coercion (a number by value, text
        /// without regard to case or surrounding space).
        let values: [String: String]
    }

    struct Carry: Decodable, Equatable {
        let fromCall: Int
        let fromArgument: String
        let toCall: Int
        let toArgument: String
    }

    struct Expectation: Decodable, Equatable {
        /// The calls, in order. Empty: no tool should run.
        let calls: [ExpectedCall]
        /// For a reading case: whether `ManualReadingCheck` should accept the model's reading.
        var readingAccepted: Bool?
        /// For a two-step case: a value from one call carried into a later one.
        var carry: Carry?
    }

    struct Reading: Decodable, Equatable {
        let found: Bool
        let answer: String
        let passage: String
        let quote: String

        var manualReading: ManualReading {
            ManualReading(found: found, answer: answer, passage: passage, quote: quote)
        }
    }

    enum CancelPoint: String, Decodable, Sendable {
        /// Before the first output: the barge-in lands while the prompt is still being read.
        case decode
        /// After the first round's tool ran, while the next answer is being generated.
        case generation
    }

    struct Case: Decodable {
        let id: String
        let category: Category
        let group: Group
        /// The vault file (or `synthetic`) the case was written from.
        let source: String
        /// For a Field Assist case: the vault whose job context the prompt carries.
        var vault: String?
        let turn: String
        var history: [Turn]?
        let offered: [String]
        let expect: Expectation
        /// What each offered tool returns when the case runs it.
        var results: [String: String]?
        var passages: [String: String]?
        var reading: Reading?
        /// For a long-prompt case: the job context the prompt carries, in estimated tokens.
        var contextTokens: Int?
        var cancel: CancelPoint?
        /// What a passing model emits, raw, one entry per generation.
        var reference: [String]?

        /// A reading case: the model reads passages and the check accepts or declines.
        var isReading: Bool { reading != nil && expect.readingAccepted != nil }

        /// A near-miss twin: the answered case's question and passages, with a scripted reading
        /// that makes up a value. It shows the check declining a made-up value; a real model reading
        /// the same passages should answer, so only a scripted run measures it.
        var isCheckOnly: Bool { category == .notInManual && reading?.found == true }

        /// The case's earlier turns in the loop's roles, as both runners hand them over.
        var loopHistory: [LocalToolLoop.Message] {
            (history ?? []).map { $0.role == "assistant" ? .assistant($0.content) : .user($0.content) }
        }
    }

    // MARK: - Selection

    /// Which cases a run takes. Field Assist first and on its own, with the categories whose
    /// floors are judged beside it (everyday restraint and declines ride along; the floors
    /// themselves are judged on Field Assist's own cases).
    struct Selection: Equatable {
        var groups: Set<Group>
        /// Cases of these categories are taken whatever their group.
        var alsoCategories: Set<Category>
        /// Keep the first `limit` selected cases (a smoke run), or all.
        var limit: Int?

        static let qualification = Selection(groups: [.fieldAssist], alsoCategories: [.restraint, .notInManual],
                                             limit: nil)
        static let everything = Selection(groups: Set(Group.allCases), alsoCategories: [], limit: nil)
    }

    /// The cases `selection` takes, in corpus order. `live`: drop the check-only near-miss twins,
    /// which only a scripted reading can fail. Returns how many were dropped for that reason.
    static func select(_ cases: [Case], _ selection: Selection, live: Bool) -> (cases: [Case], checkOnlySkipped: Int) {
        var picked = cases.filter { selection.groups.contains($0.group) || selection.alsoCategories.contains($0.category) }
        var skipped = 0
        if live {
            skipped = picked.filter(\.isCheckOnly).count
            picked.removeAll(where: \.isCheckOnly)
        }
        if let limit = selection.limit, limit >= 0 { picked = Array(picked.prefix(limit)) }
        return (picked, skipped)
    }

    /// Reads JSON lines. Blank lines and `//` lines are skipped; a line that does not decode is
    /// counted, not fatal, so a typo shows up as a number rather than a crash.
    static func loadCorpus(_ text: String) -> (cases: [Case], undecodable: Int) {
        var cases: [Case] = []
        var bad = 0
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("//") else { continue }
            if let decoded = try? JSONDecoder().decode(Case.self, from: Data(trimmed.utf8)) {
                cases.append(decoded)
            } else {
                bad += 1
            }
        }
        return (cases, bad)
    }

    // MARK: - Graders

    /// The deterministic graders. Each answers pass or fail for one property of one run.
    enum Grader: String, CaseIterable, Sendable {
        /// The expected tools were called, in order, and no others.
        case toolName
        /// Every required argument is present.
        case argumentPresence
        /// Every argument reads at its declared type (`OnDeviceArgumentCoercion` refused nothing).
        case argumentTypes
        /// The expected values, after coercion.
        case argumentValues
        /// No call was made twice or after the cap.
        case noRepeats
        /// Nothing in the spoken text is protocol or reasoning markup.
        case cleanText
        /// `ManualReadingCheck` accepted or declined the reading as expected.
        case manualReading
        /// A value from an earlier call reached the later call.
        case carry
        /// The turn stopped when cancelled, within the bound, running nothing after.
        case cancellation
        /// The prompt's job context fits the reference model's budget.
        case contextFits
    }

    /// What one run's generations measured, beside its grades. Counts and numbers only.
    struct Measurements: Equatable, Sendable {
        var generations = 0
        /// Generations that produced no token at all: a template fault (`cleanText` fails).
        var zeroTokenGenerations = 0
        /// Generations that stopped exactly at the token cap: marked cut.
        var cutGenerations = 0
        /// A reading reply that could not be read as a reading (declined, as the app would).
        var readerUnparsed = 0
        /// When the run failed on an error rather than on what the model said: the error's type and
        /// case name only (`errorKind(_:)`), never its message, so the record stays counts and names.
        var errorKind: String?
        var generatedTokens = 0
        /// Per generation the runtime reported on: seconds to read the prompt (time to first token).
        var promptSeconds: [Double] = []
        /// Per generation: generated tokens a second.
        var decodeTokensPerSecond: [Double] = []

        mutating func add(_ stats: LocalGenerationStats?) {
            generations += 1
            guard let stats else { return }
            if stats.isZeroTokens { zeroTokenGenerations += 1 }
            if stats.isCut { cutGenerations += 1 }
            generatedTokens += stats.generatedTokens
            promptSeconds.append(stats.promptSeconds)
            if let rate = stats.decodeTokensPerSecond { decodeTokensPerSecond.append(rate) }
        }
    }

    /// One run of one case.
    struct Run {
        let caseID: String
        let category: Category
        let group: Group
        /// Grader → passed. Only the graders that apply to the case are present.
        let grades: [Grader: Bool]
        var measurements = Measurements()

        var passed: Bool { grades.values.allSatisfy { $0 } }
        /// Some reply stopped at the token cap.
        var wasCut: Bool { measurements.cutGenerations > 0 }
        /// Some reply had no token at all.
        var hadTemplateFault: Bool { measurements.zeroTokenGenerations > 0 }
    }

    /// The markup no spoken answer may carry, whatever parser ran.
    static let leftoverMarkup = ["<tool_call", "</tool_call", "<|tool_call", "<tool_call|>", "<think>", "</think>",
                                 "<|channel", "<channel|>", "<|im_start", "<|im_end", "<start_of_turn", "<end_of_turn"]

    static func isClean(_ text: String) -> Bool {
        let lowered = text.lowercased()
        guard !leftoverMarkup.contains(where: { lowered.contains($0) }) else { return false }
        return LocalOutputPolicy.classify(text).kind == .prose
    }

    static func matches(_ value: Any?, expected: String) -> Bool {
        guard let value else { return false }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
           let wanted = OnDeviceArgumentCoercion.plainNumber(expected) {
            return abs(number.doubleValue - wanted) < 1e-9
        }
        if let bool = value as? Bool { return String(bool) == expected.lowercased() }
        let text = "\(value)".trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let wanted = expected.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text == wanted { return true }
        if let a = OnDeviceArgumentCoercion.plainNumber(text), let b = OnDeviceArgumentCoercion.plainNumber(wanted) {
            return abs(a - b) < 1e-9
        }
        return false
    }

    /// Grade a finished loop against its case. `schema` gives a tool's declared root, from the
    /// registry, so types are checked against what the app really declares. A generation of zero
    /// tokens fails `cleanText`: it is a prompt-format fault, not an answer (Plan MQ H, P3).
    static func grade(_ testCase: Case, outcome: LocalToolLoop.Outcome,
                      schema: (String) -> OnDeviceToolSchema.Node?,
                      measurements: Measurements = Measurements()) -> [Grader: Bool] {
        var grades: [Grader: Bool] = [:]
        let calls = outcome.executed.map(\.call)
        grades[.toolName] = calls.map(\.name) == testCase.expect.calls.map(\.tool)

        if !testCase.expect.calls.isEmpty {
            var present = true
            var typed = true
            var valued = true
            var coercedByCall: [[String: Any]] = []
            for (index, expected) in testCase.expect.calls.enumerated() {
                guard index < calls.count, calls[index].name == expected.tool else {
                    present = false; typed = false; valued = false
                    coercedByCall.append([:])
                    continue
                }
                let call = calls[index]
                var arguments = call.arguments
                if let root = schema(call.name) {
                    let coerced = OnDeviceArgumentCoercion.coerce(call.arguments, to: root)
                    if !coerced.isDispatchable { typed = false }
                    arguments = coerced.arguments
                } else {
                    typed = false
                }
                coercedByCall.append(arguments)
                if !expected.required.allSatisfy({ arguments[$0] != nil }) { present = false }
                for (name, wanted) in expected.values where !matches(arguments[name], expected: wanted) {
                    valued = false
                }
            }
            grades[.argumentPresence] = present
            grades[.argumentTypes] = typed
            grades[.argumentValues] = valued
            if let carry = testCase.expect.carry {
                let from = carry.fromCall < coercedByCall.count ? coercedByCall[carry.fromCall][carry.fromArgument] : nil
                let to = carry.toCall < coercedByCall.count ? coercedByCall[carry.toCall][carry.toArgument] : nil
                grades[.carry] = from.map { matches(to, expected: "\($0)") } ?? false
            }
        }
        let signatures = calls.map(\.signature)
        grades[.noRepeats] = Set(signatures).count == signatures.count && outcome.callsNotRun == 0
        grades[.cleanText] = isClean(outcome.text) && measurements.zeroTokenGenerations == 0
        return grades
    }

    // MARK: - Reading passages

    /// The reading a model is asked for on a reading case: the passages handed over by id, the
    /// question, and one JSON object back (Plan MP's `ManualReading`: found, answer, passage,
    /// quote). `ManualReadingCheck` decides; the model's own `found` is only its claim.
    enum Reader {
        static let instructions = """
            You read passages from a service manual and answer only from them. Reply with one JSON \
            object and nothing else: {"found": true, "answer": "<the answer in one sentence>", \
            "passage": "<the id of the passage you used>", "quote": "<the exact words of that passage \
            you relied on>"}. If the passages do not answer the question, reply {"found": false, \
            "answer": "", "passage": "", "quote": ""}. Never answer from memory.
            """

        struct Request: Equatable {
            let instructions: String
            let prompt: String
        }

        /// The request for `testCase`, passages in id order.
        static func request(for testCase: Case) -> Request {
            let passages = (testCase.passages ?? [:]).sorted { $0.key < $1.key }
                .map { "[\($0.key)]\n\($0.value)" }.joined(separator: "\n\n")
            return Request(instructions: instructions,
                           prompt: "Passages:\n\n\(passages)\n\nQuestion: \(testCase.turn)")
        }

        /// The reading in a reply: the first JSON object in it (a code fence or prose around it is
        /// ignored), or nil when there is none with a boolean `found`.
        static func parse(_ reply: String) -> ManualReading? {
            // Thinking before the reply is not the reply.
            var spoken = reply
            if let thought = spoken.range(of: "</think>", options: .backwards) {
                spoken = String(spoken[thought.upperBound...])
            }
            guard let open = spoken.firstIndex(of: "{"), let close = spoken.lastIndex(of: "}"), open < close else {
                return nil
            }
            guard let object = try? JSONSerialization.jsonObject(with: Data(spoken[open...close].utf8)) as? [String: Any],
                  let found = (object["found"] as? Bool) ?? (object["found"] as? String).flatMap(Bool.init) else {
                return nil
            }
            func text(_ key: String) -> String { (object[key] as? String) ?? (object[key].map { "\($0)" } ?? "") }
            return ManualReading(found: found, answer: text("answer"), passage: text("passage"), quote: text("quote"))
        }

        /// A scripted reading as a model would reply with it.
        static func reply(for reading: Reading) -> String {
            let object: [String: Any] = ["found": reading.found, "answer": reading.answer,
                                         "passage": reading.passage, "quote": reading.quote]
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
            return String(decoding: data, as: UTF8.self)
        }
    }

    // MARK: - The runner

    /// What a runner needs besides the case: a model, and the size of the job context it renders.
    struct Environment {
        /// One generation of the tool loop: the case, the request, and which generation of the run
        /// this is (from 0). The text and any calls the runtime parsed, with its report.
        let generateTurn: (Case, LocalToolLoop.GenerationRequest, Int) async throws -> LocalToolLoop.Generation
        /// One reading of a reading case's passages.
        let read: (Case, Reader.Request) async throws -> LocalToolLoop.Generation
        /// A tool's declared schema root, by name.
        let schema: (String) -> OnDeviceToolSchema.Node?
        /// The model whose window a long-prompt case is checked against.
        let referenceModelID: String
        /// The longest a cancelled turn may take to stop.
        var cancellationBound: TimeInterval = 1.0
        /// A model that runs its own tool loop (Apple's on-device model, whose framework calls the
        /// tools itself): given the case, its history and the same `execute` the shipped loop would
        /// call, it returns the turn's outcome. Nil: the shipped `LocalToolLoop` drives
        /// `generateTurn`.
        var runTurn: ((Case, [LocalToolLoop.Message],
                       @escaping (LocalToolLoop.Call) async throws -> LocalToolLoop.ExecutionResult)
                      async throws -> LocalToolLoop.Outcome)?

        init(generateTurn: @escaping (Case, LocalToolLoop.GenerationRequest, Int) async throws -> LocalToolLoop.Generation,
             read: @escaping (Case, Reader.Request) async throws -> LocalToolLoop.Generation = LocalToolEval.referenceReading,
             schema: @escaping (String) -> OnDeviceToolSchema.Node?,
             referenceModelID: String,
             cancellationBound: TimeInterval = 1.0) {
            self.generateTurn = generateTurn
            self.read = read
            self.schema = schema
            self.referenceModelID = referenceModelID
            self.cancellationBound = cancellationBound
        }

        /// A text-only model: each generation is its raw output, and readings are scripted.
        init(generate: @escaping (Case, LocalToolLoop.GenerationRequest, Int) async throws -> String,
             schema: @escaping (String) -> OnDeviceToolSchema.Node?,
             referenceModelID: String) {
            self.init(generateTurn: { LocalToolLoop.Generation(text: try await generate($0, $1, $2)) },
                      schema: schema, referenceModelID: referenceModelID)
        }
    }

    /// Run one case once and grade it.
    static func run(_ testCase: Case, environment: Environment) async -> Run {
        var grades: [Grader: Bool] = [:]
        let measured = MeasurementLog()

        if let tokens = testCase.contextTokens {
            grades[.contextFits] = tokens <= LocalModelBudget.promptBudget(for: environment.referenceModelID)
        }
        if testCase.isReading, let expected = testCase.expect.readingAccepted {
            do {
                let reply = try await environment.read(testCase, Reader.request(for: testCase))
                measured.add(reply.stats)
                let reading = Reader.parse(reply.text)
                if reading == nil { measured.noteUnparsedReading() }
                // An unreadable reply is declined, as the app declines it.
                let verdict = reading.map { ManualReadingCheck.check($0, passages: testCase.passages ?? [:]) }
                grades[.manualReading] = (verdict?.isAccepted ?? false) == expected
            } catch {
                measured.noteError(error)
                grades[.manualReading] = false
            }
            if measured.value.zeroTokenGenerations > 0 { grades[.cleanText] = false }
            return Run(caseID: testCase.id, category: testCase.category, group: testCase.group, grades: grades,
                       measurements: measured.value)
        }

        let history = testCase.loopHistory
        let offered = Set(testCase.offered)
        let results = testCase.results ?? [:]
        let counter = Counter()
        let executedAfterCancel = Counter()

        // What the shipped loop's dispatcher answers (`LLMService.sendLocalNative`): a tool the
        // turn did not offer, or arguments that can't be read at their types, come back as an error;
        // anything else gets the case's scripted result, framed as a turn frames it.
        let execute: (LocalToolLoop.Call) async throws -> LocalToolLoop.ExecutionResult = { call in
            if Task.isCancelled { _ = executedAfterCancel.next() }
            defer {
                if testCase.cancel == .generation { withUnsafeCurrentTask { $0?.cancel() } }
            }
            guard offered.contains(call.name) else {
                return .init(text: LocalToolLoop.unofferedToolMessage(name: call.name, offered: offered), isError: true)
            }
            if let root = environment.schema(call.name) {
                let coerced = OnDeviceArgumentCoercion.coerce(call.arguments, to: root)
                if let refusal = coerced.refusalMessage { return .init(text: refusal, isError: true) }
            }
            return .init(text: PromptInjectionPolicy.resultForModel(
                toolName: call.name, content: results[call.name] ?? "Done.", isKnownNativeTool: true))
        }

        let started = Date()
        let task = Task { () -> Result<LocalToolLoop.Outcome, Error> in
            do {
                if let runTurn = environment.runTurn {
                    if testCase.cancel == .decode {
                        withUnsafeCurrentTask { $0?.cancel() }
                        try Task.checkCancellation()
                    }
                    return .success(try await runTurn(testCase, history, execute))
                }
                let outcome = try await LocalToolLoop.run(
                    history: history, userMessage: testCase.turn,
                    generateTurn: { request in
                        let index = counter.next()
                        if testCase.cancel == .decode, index == 0 {
                            withUnsafeCurrentTask { $0?.cancel() }
                            try Task.checkCancellation()
                        }
                        let generation = try await environment.generateTurn(testCase, request, index)
                        measured.add(generation.stats)
                        return generation
                    },
                    execute: execute)
                return .success(outcome)
            } catch {
                return .failure(error)
            }
        }
        // A runner that is itself cancelled (the device app leaving the foreground) stops the turn.
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        let elapsed = Date().timeIntervalSince(started)

        switch result {
        case .success(let outcome):
            grades.merge(grade(testCase, outcome: outcome, schema: environment.schema,
                               measurements: measured.value)) { $1 }
            if testCase.cancel != nil { grades[.cancellation] = false }
        case .failure(let error):
            if !(error is CancellationError) || testCase.cancel == nil { measured.noteError(error) }
            if testCase.cancel != nil {
                grades[.cancellation] = error is CancellationError && elapsed <= environment.cancellationBound
                    && executedAfterCancel.value == 0
            } else {
                grades[.toolName] = false
            }
        }
        return Run(caseID: testCase.id, category: testCase.category, group: testCase.group, grades: grades,
                   measurements: measured.value)
    }

    /// A thread-safe count; the loop's closures are not `@Sendable`, but a task may hop threads.
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var value = 0
        func next() -> Int {
            lock.lock(); defer { lock.unlock() }
            defer { value += 1 }
            return value
        }
    }

    /// A run's measurements, collected from closures that may hop threads.
    final class MeasurementLog: @unchecked Sendable {
        private let lock = NSLock()
        private var measurements = Measurements()
        var value: Measurements { lock.lock(); defer { lock.unlock() }; return measurements }
        func add(_ stats: LocalGenerationStats?) { lock.lock(); measurements.add(stats); lock.unlock() }
        func noteUnparsedReading() { lock.lock(); measurements.readerUnparsed += 1; lock.unlock() }
        func noteError(_ error: Error) { lock.lock(); measurements.errorKind = LocalToolEval.errorKind(error); lock.unlock() }
    }

    /// An error's type and, for an enum, its case name; an `NSError`'s domain and code. No message,
    /// no associated value: those can carry a prompt, a template or a path.
    static func errorKind(_ error: Error) -> String {
        let type = String(describing: Swift.type(of: error))
        if error is CancellationError { return type }
        let mirror = Mirror(reflecting: error)
        if mirror.displayStyle == .enum {
            if let child = mirror.children.first, let label = child.label {
                // Whole numbers only (a token count and its limit): never a string or anything else.
                let value = Mirror(reflecting: child.value)
                if let number = child.value as? Int { return type + "." + label + "(\(number))" }
                if value.displayStyle == .tuple, !value.children.isEmpty,
                   value.children.allSatisfy({ $0.value is Int }) {
                    let parts = value.children.map { "\($0.label.map { $0 + ": " } ?? "")\($0.value as! Int)" }
                    return type + "." + label + "(" + parts.joined(separator: ", ") + ")"
                }
                return type + "." + label
            }
            return type + "." + String(describing: error).prefix(while: { $0.isLetter || $0.isNumber })
        }
        let ns = error as NSError
        if type == "NSError" || type.hasPrefix("__") { return ns.domain + "#" + String(ns.code) }
        return type
    }

    /// The scripted fake model CI plays: each case's `reference`, one entry per generation, then
    /// empty output.
    static func referenceModel(_ testCase: Case, _ request: LocalToolLoop.GenerationRequest,
                               _ index: Int) async throws -> String {
        let script = testCase.reference ?? []
        return index < script.count ? script[index] : ""
    }

    /// The scripted reader CI plays: the case's own reading, in the reply format.
    static func referenceReading(_ testCase: Case, _ request: Reader.Request) async throws -> LocalToolLoop.Generation {
        LocalToolLoop.Generation(text: testCase.reading.map(Reader.reply(for:)) ?? "")
    }

    // MARK: - The report

    struct Tally: Equatable {
        var runs = 0
        var passed = 0
    }

    struct Report {
        struct GroupTally {
            var overall = Tally()
            var byCategory: [Category: Tally] = [:]
            var byGrader: [Grader: Tally] = [:]
            var outcomes: [Double] = []
            /// Runs with a reply that stopped at the token cap.
            var cutRuns = 0
            /// Runs with a reply of zero tokens (template faults).
            var templateFaultRuns = 0
            /// Reading runs whose reply could not be read as a reading.
            var readerUnparsedRuns = 0
        }

        var groups: [Group: GroupTally] = [:]
        var overall = Tally()

        mutating func add(_ run: Run) {
            overall.runs += 1
            if run.passed { overall.passed += 1 }
            var group = groups[run.group, default: GroupTally()]
            group.overall.runs += 1
            group.byCategory[run.category, default: Tally()].runs += 1
            if run.passed {
                group.overall.passed += 1
                group.byCategory[run.category, default: Tally()].passed += 1
            }
            for (grader, passed) in run.grades {
                group.byGrader[grader, default: Tally()].runs += 1
                if passed { group.byGrader[grader, default: Tally()].passed += 1 }
            }
            group.outcomes.append(run.passed ? 1 : 0)
            if run.wasCut { group.cutRuns += 1 }
            if run.hadTemplateFault { group.templateFaultRuns += 1 }
            if run.measurements.readerUnparsed > 0 { group.readerUnparsedRuns += 1 }
            groups[run.group] = group
        }

        /// Counts only: each group — Field Assist first — with its pass rate's bootstrap interval,
        /// its categories and its graders.
        func lines() -> [String] {
            var lines = ["local-tool-eval corpus v\(LocalToolEval.corpusVersion): \(overall.passed)/\(overall.runs) runs passed"]
            for groupKey in Group.allCases {
                guard let group = groups[groupKey] else { continue }
                var head = "  \(groupKey.rawValue): \(group.overall.passed)/\(group.overall.runs)"
                if let interval = EvalIntervals.bootstrapInterval(values: group.outcomes) {
                    head += ", pass rate \(interval.formatted())"
                }
                lines.append(head)
                for category in Category.allCases {
                    guard let tally = group.byCategory[category] else { continue }
                    lines.append("    \(category.rawValue): \(tally.passed)/\(tally.runs)")
                }
                for grader in Grader.allCases {
                    guard let tally = group.byGrader[grader] else { continue }
                    lines.append("    grader \(grader.rawValue): \(tally.passed)/\(tally.runs)")
                }
                if group.cutRuns + group.templateFaultRuns + group.readerUnparsedRuns > 0 {
                    lines.append("    cut at the token cap: \(group.cutRuns), zero-token replies: \(group.templateFaultRuns), "
                                 + "readings not parsed: \(group.readerUnparsedRuns)")
                }
            }
            return lines
        }

        /// The judged group's tally for one floor, or nil when no run measured it.
        func tally(for floor: Floor) -> Tally? {
            let group = groups[Floors.judgedGroup] ?? GroupTally()
            let tally: Tally?
            switch floor.measure {
            case .category(let category): tally = group.byCategory[category]
            case .grader(let grader): tally = group.byGrader[grader]
            }
            return tally.flatMap { $0.runs > 0 ? $0 : nil }
        }

        /// Decision 5's floors the report's runs fall below, in `Floors.all` order.
        func floorShortfalls() -> [Floor] {
            Floors.all.filter { floor in
                guard let tally = tally(for: floor) else { return false }
                return Double(tally.passed) < floor.minimum * Double(tally.runs)
            }
        }

        /// The floors no run in the judged group measured. A model is not qualified on a floor it
        /// was never judged on, so a qualification run needs this empty as well as the shortfalls.
        func unjudgedFloors() -> [Floor] {
            Floors.all.filter { tally(for: $0) == nil }
        }

        /// Whether the report clears every floor, each one judged.
        var clearsFloors: Bool { floorShortfalls().isEmpty && unjudgedFloors().isEmpty }
    }

    // MARK: - The floors (decision 5)

    /// One hard floor: a category's or a grader's pass rate in the judged group.
    struct Floor: Equatable {
        enum Measure: Equatable {
            case category(Category)
            case grader(Grader)
        }
        let name: String
        let measure: Measure
        /// The pass rate it must reach, 0 to 1.
        let minimum: Double
    }

    /// The `.toolFriendly` floors the owner fixed on 2026-11-21, before any model was run. Judged
    /// on the Field Assist group, each on its own, never an average. Tool choice (around 0.85) and
    /// two-step (around 0.70) are set after the first phone run (owner, 2026-11-22: phone results
    /// first; the Mac screener is a compile check), so they are not floors yet.
    enum Floors {
        static let judgedGroup: Group = .fieldAssist
        /// A question the manual does not answer is declined, not answered from memory.
        static let notInManualDeclined = 0.95
        /// No protocol or reasoning markup reaches the voice, on any case.
        static let cleanOutput = 1.0
        /// No tool is called when none applies.
        static let restraint = 0.90

        static let all: [Floor] = [
            Floor(name: "not in the manual declined", measure: .category(.notInManual), minimum: notInManualDeclined),
            Floor(name: "clean output", measure: .grader(.cleanText), minimum: cleanOutput),
            Floor(name: "restraint", measure: .category(.restraint), minimum: restraint),
        ]
    }
}
