import Foundation

/// Plan MN — the format a procedure uses to take a typed answer on a step (§1) and to let the app
/// decide a branch from it (§2). Both are optional, decoded with `decodeIfPresent` and left out
/// when encoding, so a procedure without them reads and writes exactly as it did, and an older
/// build ignores them and lets the model choose from `condition` as before.
enum ProcedureAnswerFormat {
    /// The first app build that reads `answer` on a step and `when` on a branch. A pack whose
    /// procedures use either sets `minAppBuild` to at least this (§7), and the validator warns
    /// when it does not.
    static let firstAppBuild = 738
}

/// One typed answer on a procedure step (Plan MN §1). One per step at most.
///
/// Every field is kept as written so a procedure round-trips unchanged: the kind is held as its
/// raw name (an unknown kind is the validator's issue, not a decoding failure that would drop the
/// whole procedure), and the number bounds stay `Double` in the file. Comparisons never use them
/// as `Double`: `plausibleRange` and `specRange` turn each bound into an exact `Decimal` built from
/// its shortest text, and a reading is compared as the `Decimal` built from what was entered (§2).
struct StepAnswer: Codable, Equatable {
    enum Kind: String, CaseIterable, Codable {
        case number, choice, text, photo, code
        case yesNo = "yes_no"
    }

    /// One option of a `choice` answer: what is printed (`label`), what a rule names (`id`) and
    /// the words a person may say for it (`says`).
    struct Option: Codable, Equatable {
        let id: String
        let label: String
        let says: [String]?

        init(id: String, label: String, says: [String]? = nil) {
            self.id = id
            self.label = label
            self.says = says
        }
    }

    /// Names the answer in the record and in rules. Snake case, unique within the procedure.
    /// Decoded as empty when missing so the validator can say so.
    let recordAs: String
    /// The kind as written. `kind` is nil when this build does not know it.
    let kindName: String
    /// The short name printed and spoken ("pH").
    let label: String?
    /// Defaults to true: the step needs an answer before `next`.
    let required: Bool?
    /// A critical limit (§3): a spoken answer is read back, an out-of-spec one needs a note.
    let critical: Bool?

    // number
    let unit: String?
    /// 0–3, default 0.
    let decimals: Int?
    /// [lo, hi]: what a reading can be at all. Outside it, the app asks again (decision 1).
    let plausible: [Double]?
    /// [lo, hi]: what a reading should be. Outside it, the reading is recorded as out of spec.
    let spec: [Double]?
    /// Whether the step screen shows the spec as a hint ("3.8 to 4.4").
    let showSpec: Bool?

    // choice
    let options: [Option]?

    // text
    let minLen: Int?
    let maxLen: Int?

    // photo
    let minPhotos: Int?
    let maxPhotos: Int?

    // code
    /// "qr" or "barcode".
    let symbology: String?
    /// When set, a code that does not match is recorded as out of spec.
    let expected: String?

    enum CodingKeys: String, CodingKey {
        case label, required, critical, unit, decimals, plausible, spec, options, symbology, expected
        case recordAs = "record_as"
        case kindName = "kind"
        case showSpec = "show_spec"
        case minLen = "min_len"
        case maxLen = "max_len"
        case minPhotos = "min"
        case maxPhotos = "max"
    }

    init(recordAs: String, kind: Kind, label: String? = nil, required: Bool? = nil,
         critical: Bool? = nil, unit: String? = nil, decimals: Int? = nil,
         plausible: [Double]? = nil, spec: [Double]? = nil, showSpec: Bool? = nil,
         options: [Option]? = nil, minLen: Int? = nil, maxLen: Int? = nil,
         minPhotos: Int? = nil, maxPhotos: Int? = nil,
         symbology: String? = nil, expected: String? = nil) {
        self.init(recordAs: recordAs, kindName: kind.rawValue, label: label, required: required,
                  critical: critical, unit: unit, decimals: decimals, plausible: plausible,
                  spec: spec, showSpec: showSpec, options: options, minLen: minLen,
                  maxLen: maxLen, minPhotos: minPhotos, maxPhotos: maxPhotos,
                  symbology: symbology, expected: expected)
    }

    init(recordAs: String, kindName: String, label: String? = nil, required: Bool? = nil,
         critical: Bool? = nil, unit: String? = nil, decimals: Int? = nil,
         plausible: [Double]? = nil, spec: [Double]? = nil, showSpec: Bool? = nil,
         options: [Option]? = nil, minLen: Int? = nil, maxLen: Int? = nil,
         minPhotos: Int? = nil, maxPhotos: Int? = nil,
         symbology: String? = nil, expected: String? = nil) {
        self.recordAs = recordAs
        self.kindName = kindName
        self.label = label
        self.required = required
        self.critical = critical
        self.unit = unit
        self.decimals = decimals
        self.plausible = plausible
        self.spec = spec
        self.showSpec = showSpec
        self.options = options
        self.minLen = minLen
        self.maxLen = maxLen
        self.minPhotos = minPhotos
        self.maxPhotos = maxPhotos
        self.symbology = symbology
        self.expected = expected
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        recordAs = try c.decodeIfPresent(String.self, forKey: .recordAs) ?? ""
        kindName = try c.decodeIfPresent(String.self, forKey: .kindName) ?? ""
        label = try c.decodeIfPresent(String.self, forKey: .label)
        required = try c.decodeIfPresent(Bool.self, forKey: .required)
        critical = try c.decodeIfPresent(Bool.self, forKey: .critical)
        unit = try c.decodeIfPresent(String.self, forKey: .unit)
        decimals = try c.decodeIfPresent(Int.self, forKey: .decimals)
        plausible = try c.decodeIfPresent([Double].self, forKey: .plausible)
        spec = try c.decodeIfPresent([Double].self, forKey: .spec)
        showSpec = try c.decodeIfPresent(Bool.self, forKey: .showSpec)
        options = try c.decodeIfPresent([Option].self, forKey: .options)
        minLen = try c.decodeIfPresent(Int.self, forKey: .minLen)
        maxLen = try c.decodeIfPresent(Int.self, forKey: .maxLen)
        minPhotos = try c.decodeIfPresent(Int.self, forKey: .minPhotos)
        maxPhotos = try c.decodeIfPresent(Int.self, forKey: .maxPhotos)
        symbology = try c.decodeIfPresent(String.self, forKey: .symbology)
        expected = try c.decodeIfPresent(String.self, forKey: .expected)
    }

    // MARK: - Reading the format

    var kind: Kind? { Kind(rawValue: kindName) }
    var isRequired: Bool { required ?? true }
    var isCritical: Bool { critical == true }
    /// Decimal places a number is rounded to, clamped to 0–3.
    var places: Int { Swift.max(0, Swift.min(3, decimals ?? 0)) }
    /// The name printed and spoken: the label, or the record name with spaces.
    var displayLabel: String {
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? recordAs.replacingOccurrences(of: "_", with: " ") : trimmed
    }

    /// `plausible` as exact decimals, when it is a well-formed pair.
    var plausibleRange: ClosedRange<Decimal>? { Self.range(plausible) }
    /// `spec` as exact decimals, when it is a well-formed pair.
    var specRange: ClosedRange<Decimal>? { Self.range(spec) }

    /// Text length bounds, defaults 1 and 500.
    var textBounds: (min: Int, max: Int) { (minLen ?? 1, maxLen ?? 500) }
    /// Photo count bounds, defaults 1 and 5.
    var photoBounds: (min: Int, max: Int) { (minPhotos ?? 1, maxPhotos ?? 5) }

    /// Whether this answer has a spec a rule's `out_of_spec` can test: a number with `spec`, or a
    /// code with `expected`.
    var hasSpec: Bool {
        switch kind {
        case .number: return specRange != nil
        case .code: return !(expected ?? "").isEmpty
        default: return false
        }
    }

    /// The tap targets for a `choice` or `yes_no` answer, in order: (id, label). Empty for kinds
    /// that are typed, spoken or scanned.
    var buttons: [(id: String, label: String)] {
        switch kind {
        case .choice: return (options ?? []).map { ($0.id, $0.label) }
        case .yesNo: return [("yes", "Yes"), ("no", "No")]
        default: return []
        }
    }

    /// The label of a choice option or a yes/no id, for records and rule text.
    func optionLabel(_ id: String) -> String {
        if kind == .yesNo { return id }
        return options?.first { $0.id == id }?.label ?? id
    }

    /// The spec in words, "3.8 to 4.4", when there is one.
    var specText: String? {
        guard let range = specRange else { return nil }
        return "\(ExactDecimal.text(range.lowerBound)) to \(ExactDecimal.text(range.upperBound))"
    }

    /// The keys written in this answer besides the shared ones — what the validator checks
    /// against the kind ("only that kind's fields are present").
    var kindSpecificKeys: [String] {
        var keys: [String] = []
        if unit != nil { keys.append("unit") }
        if decimals != nil { keys.append("decimals") }
        if plausible != nil { keys.append("plausible") }
        if spec != nil { keys.append("spec") }
        if showSpec != nil { keys.append("show_spec") }
        if options != nil { keys.append("options") }
        if minLen != nil { keys.append("min_len") }
        if maxLen != nil { keys.append("max_len") }
        if minPhotos != nil { keys.append("min") }
        if maxPhotos != nil { keys.append("max") }
        if symbology != nil { keys.append("symbology") }
        if expected != nil { keys.append("expected") }
        return keys
    }

    /// The kind-specific keys each kind may carry.
    static func allowedKeys(for kind: Kind) -> Set<String> {
        switch kind {
        case .number: return ["unit", "decimals", "plausible", "spec", "show_spec"]
        case .choice: return ["options"]
        case .yesNo: return []
        case .text: return ["min_len", "max_len"]
        case .photo: return ["min", "max"]
        case .code: return ["symbology", "expected"]
        }
    }

    private static func range(_ pair: [Double]?) -> ClosedRange<Decimal>? {
        guard let pair, pair.count == 2 else { return nil }
        let lo = ExactDecimal.from(pair[0]), hi = ExactDecimal.from(pair[1])
        return lo <= hi ? lo...hi : nil
    }
}

/// A small rule on a branch (Plan MN §2): a test on an answer, or `all` / `any` / `not` of rules.
/// JSON, not a string language, so nothing has to parse text that could be misread.
///
/// Decoding is lenient on purpose: a rule this build cannot read becomes `.malformed(reason)`
/// rather than failing the procedure, so the validator names the problem at import, and the
/// runner treats it as a test that does not hold.
indirect enum BranchRule: Equatable {
    case test(Test)
    case all([BranchRule])
    case any([BranchRule])
    case not(BranchRule)
    case malformed(String)

    enum Op: String, CaseIterable {
        case eq, ne, lt, lte, gt, gte, between, outside, present
        case inList = "in"
        case isAnswer = "is"
        case outOfSpec = "out_of_spec"
    }

    /// What a test compares against.
    enum Operand: Equatable {
        case number(Double)
        case text(String)
        case pair(Double, Double)
        case list([String])
        case flag(Bool)
    }

    /// `{ "answer": "<record_as>", <op>: <value> }`.
    struct Test: Equatable {
        let answer: String
        let op: Op
        let operand: Operand
    }

    /// Combinator levels: a test is 0, `all`/`any`/`not` add one. The validator allows three.
    var depth: Int {
        switch self {
        case .test, .malformed: return 0
        case .all(let rules), .any(let rules): return 1 + (rules.map(\.depth).max() ?? 0)
        case .not(let rule): return 1 + rule.depth
        }
    }

    /// Every test in the rule, in order.
    var tests: [Test] {
        switch self {
        case .test(let test): return [test]
        case .malformed: return []
        case .all(let rules), .any(let rules): return rules.flatMap(\.tests)
        case .not(let rule): return rule.tests
        }
    }

    /// Every reason this rule could not be read, in order.
    var malformedReasons: [String] {
        switch self {
        case .test: return []
        case .malformed(let reason): return [reason]
        case .all(let rules), .any(let rules): return rules.flatMap(\.malformedReasons)
        case .not(let rule): return rule.malformedReasons
        }
    }

    /// The answers the rule names.
    var answersNamed: [String] { tests.map(\.answer) }
}

extension BranchRule: Codable {
    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    private static let combinators: Set<String> = ["all", "any", "not"]

    init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: Key.self) else {
            self = .malformed("a rule is an object: a test on an answer, or all, any or not")
            return
        }
        let names = Set(c.allKeys.map(\.stringValue))
        let combinator = names.intersection(Self.combinators)
        if !combinator.isEmpty {
            guard combinator.count == 1, names.count == 1, let name = combinator.first else {
                self = .malformed("a combination names one of all, any or not, and nothing else")
                return
            }
            if name == "not" {
                guard let rule = try? c.decode(BranchRule.self, forKey: Key("not")) else {
                    self = .malformed("'not' holds one rule"); return
                }
                self = .not(rule)
                return
            }
            guard let rules = try? c.decode([BranchRule].self, forKey: Key(name)), !rules.isEmpty else {
                self = .malformed("'\(name)' holds a list of at least one rule"); return
            }
            self = name == "all" ? .all(rules) : .any(rules)
            return
        }
        guard names.contains("answer") else {
            self = .malformed("a test names the answer it reads ('answer')")
            return
        }
        guard let answer = try? c.decode(String.self, forKey: Key("answer")) else {
            self = .malformed("'answer' is the record_as name of an answer"); return
        }
        let opNames = names.subtracting(["answer"])
        guard opNames.count == 1, let opName = opNames.first else {
            self = .malformed(opNames.isEmpty
                ? "the test on '\(answer)' names no comparison"
                : "the test on '\(answer)' names more than one comparison (\(opNames.sorted().joined(separator: ", ")))")
            return
        }
        guard let op = Op(rawValue: opName) else {
            self = .malformed("unknown comparison '\(opName)' on '\(answer)'"); return
        }
        let key = Key(opName)
        let operand: Operand?
        switch op {
        case .eq, .ne:
            if let number = try? c.decode(Double.self, forKey: key) { operand = .number(number) }
            else { operand = (try? c.decode(String.self, forKey: key)).map(Operand.text) }
        case .lt, .lte, .gt, .gte:
            operand = (try? c.decode(Double.self, forKey: key)).map(Operand.number)
        case .between, .outside:
            if let pair = try? c.decode([Double].self, forKey: key), pair.count == 2 {
                operand = .pair(pair[0], pair[1])
            } else { operand = nil }
        case .inList:
            operand = (try? c.decode([String].self, forKey: key)).map(Operand.list)
        case .isAnswer:
            operand = (try? c.decode(String.self, forKey: key)).map(Operand.text)
        case .outOfSpec, .present:
            operand = (try? c.decode(Bool.self, forKey: key)).map(Operand.flag)
        }
        guard let operand else {
            self = .malformed("'\(opName)' on '\(answer)' needs \(Self.operandShape(op))")
            return
        }
        self = .test(Test(answer: answer, op: op, operand: operand))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .test(let test):
            try c.encode(test.answer, forKey: Key("answer"))
            let key = Key(test.op.rawValue)
            switch test.operand {
            case .number(let n): try c.encode(n, forKey: key)
            case .text(let s): try c.encode(s, forKey: key)
            case .pair(let lo, let hi): try c.encode([lo, hi], forKey: key)
            case .list(let ids): try c.encode(ids, forKey: key)
            case .flag(let b): try c.encode(b, forKey: key)
            }
        case .all(let rules): try c.encode(rules, forKey: Key("all"))
        case .any(let rules): try c.encode(rules, forKey: Key("any"))
        case .not(let rule): try c.encode(rule, forKey: Key("not"))
        case .malformed(let reason): try c.encode(reason, forKey: Key("malformed"))
        }
    }

    static func operandShape(_ op: Op) -> String {
        switch op {
        case .eq, .ne: return "a number or an id"
        case .lt, .lte, .gt, .gte: return "a number"
        case .between, .outside: return "[lo, hi]"
        case .inList: return "a list of option ids"
        case .isAnswer: return "\"yes\" or \"no\""
        case .outOfSpec, .present: return "true or false"
        }
    }
}

/// Exact decimal arithmetic for readings (Plan MN §2): a bound is the `Decimal` of its shortest
/// text ("4.4", never 4.4000000000000004), and a reading is the `Decimal` of what was entered,
/// rounded to the step's places.
enum ExactDecimal {
    private static let posix = Locale(identifier: "en_US_POSIX")

    /// The exact decimal a JSON number was written as. Swift prints a `Double` as the shortest
    /// text that reads back to it, which is the text the author wrote.
    static func from(_ value: Double) -> Decimal {
        Decimal(string: "\(value)", locale: posix) ?? Decimal(value)
    }

    /// A decimal from plain ASCII text ("-4.20"). Nil for anything else.
    static func parse(_ text: String) -> Decimal? {
        guard text.range(of: #"^[-+]?\d+(\.\d+)?$"#, options: .regularExpression) != nil else { return nil }
        return Decimal(string: text, locale: posix)
    }

    /// Rounded half away from zero to `places`.
    static func rounded(_ value: Decimal, places: Int) -> Decimal {
        var input = value
        var result = Decimal()
        NSDecimalRound(&result, &input, places, .plain)
        return result
    }

    /// "4.60" at 2 places; "5" at 0.
    static func text(_ value: Decimal, places: Int) -> String {
        let plain = text(rounded(value, places: places))
        guard places > 0 else { return plain }
        let parts = plain.split(separator: ".", maxSplits: 1).map(String.init)
        let fraction = parts.count > 1 ? parts[1] : ""
        return parts[0] + "." + fraction + String(repeating: "0", count: max(0, places - fraction.count))
    }

    /// The decimal as written, with no padding ("4.4").
    static func text(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).description(withLocale: posix)
    }

    /// One unit in the last place at `places`: 0.01 at 2.
    static func unit(places: Int) -> Decimal {
        var unit = Decimal(1)
        for _ in 0..<max(0, places) { unit /= 10 }
        return unit
    }
}
