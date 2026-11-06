import Foundation

/// One lesson of the band check (Plan KP §5).
///
/// On a store build the app sees the Neural Band only as button presses on the Display, so every
/// lesson offered is made of buttons. `back` is declared so the result, the report and the lesson
/// list have a place for it, and is never offered: a store build cannot observe the band's back
/// gesture. It waits for the TestFlight-only experimental lane (Plan JV P0, and P2's Inputs `back`),
/// where it is built only under `DAT_EXPERIMENTAL`, in `Sources/Glasses/Experimental/`.
enum BandLesson: String, Codable, CaseIterable, Equatable {
    /// One button, "Press me", pressed three times.
    case select
    /// Two buttons side by side: press the one marked ●, which moves each time.
    case move
    /// Six buttons, the launcher's shape: press them in the order shown.
    case list
    /// The band's back gesture (TestFlight lane only). Never offered on this build.
    case back

    /// The lessons a run offers, in order. Lesson 4 is not among them (see the type's note).
    static let offered: [BandLesson] = [.select, .move, .list]

    /// Presses a lesson asks for.
    var requiredPresses: Int {
        switch self {
        case .select, .move, .back: return 3
        case .list: return BandPractice.listOrder.count
        }
    }

    /// How the card and the phone page name it.
    var title: String {
        switch self {
        case .select: return String(localized: "Select", comment: "Band check lesson: press one button.")
        case .move: return String(localized: "Move", comment: "Band check lesson: press the marked one of two buttons.")
        case .list: return String(localized: "A list", comment: "Band check lesson: press six buttons in order.")
        case .back: return String(localized: "Back", comment: "Band check lesson: the band's back gesture.")
        }
    }

    /// What the wearer is asked to do.
    var instruction: String {
        switch self {
        case .select: return String(localized: "Press the button three times.")
        case .move: return String(localized: "Press the button marked ●.")
        case .list: return String(localized: "Press the buttons in order, 1 to 6.")
        case .back: return String(localized: "Use the band's back gesture.")
        }
    }
}

/// The band check's state (Plan KP §5): which lesson, how far into it, and what arrived. Pure, so
/// every rule is tested without a Display: presses come in as the id of the button pressed.
///
/// **Ids carry the frame.** Every button's id names the lesson and step it was drawn for
/// (`band.<lesson>.<step>.<slot>`). A press whose id is not of the frame now asked for came from
/// an older frame (the card had already moved on) and is stale: dropped, and counted only as
/// stale, never as wrong. This is the same rule as §2's revision gate, which the session applies
/// first, at the level of the press itself.
struct BandPractice: Equatable {
    /// Lesson 3's buttons in their places: the number on each button is its place in the order.
    /// Laid out so the path goes down, back up, and across both rows (two rows of three on the
    /// launcher's shape): 1 top middle, 2 below it, 3 top left, 4 bottom right, 5 top right,
    /// 6 bottom left.
    static let listOrder: [Int] = [3, 1, 5, 6, 2, 4]

    /// The done button on the last screen. Not a lesson press.
    static let doneID = "band.done"

    /// What one press did.
    enum Outcome: Equatable {
        /// The right button: the lesson moved on a step.
        case advanced
        /// The right button, and it was the lesson's last press.
        case lessonPassed(BandLesson)
        /// The right button, and it was the last press of the last lesson.
        case finished
        /// A button of the frame asked for, but not the one asked for. Recorded, not advanced.
        case wrong
        /// A button from an older frame, or not one of ours. Dropped.
        case stale
    }

    let lessons: [BandLesson]
    private(set) var lessonIndex = 0
    /// Right presses in the current lesson.
    private(set) var step = 0
    /// Right presses, per lesson, in `lessons` order.
    private(set) var arrived: [Int]
    /// Wrong presses, per lesson.
    private(set) var wrong: [Int]
    private(set) var stalePresses = 0
    /// When each press that counted (right or wrong) arrived, oldest first.
    private(set) var pressTimes: [Date] = []

    init(lessons: [BandLesson] = BandLesson.offered) {
        // Lesson 4 is never offered on this build, whatever a caller passes.
        let offered = lessons.filter { $0 != .back }
        self.lessons = offered.isEmpty ? BandLesson.offered : offered
        arrived = Array(repeating: 0, count: self.lessons.count)
        wrong = Array(repeating: 0, count: self.lessons.count)
    }

    var isFinished: Bool { lessonIndex >= lessons.count }
    var currentLesson: BandLesson? { isFinished ? nil : lessons[lessonIndex] }
    var lessonsPassed: Int { zip(lessons, arrived).filter { $1 >= $0.requiredPresses }.count }

    /// The slot of the button the current step asks for.
    var targetSlot: Int? {
        guard let lesson = currentLesson else { return nil }
        return Self.targetSlot(lesson: lesson, step: step)
    }

    /// Lesson 2's marked button starts on the right (the band's focus most likely starts on the
    /// first button, so the first press already needs a move) and swaps sides on every press.
    /// Lesson 3's is the place holding the next number.
    static func targetSlot(lesson: BandLesson, step: Int) -> Int {
        switch lesson {
        case .select, .back: return 0
        case .move: return step % 2 == 0 ? 1 : 0
        case .list: return listOrder.firstIndex(of: step + 1) ?? 0
        }
    }

    /// The buttons a lesson's step shows.
    static func slotCount(_ lesson: BandLesson) -> Int {
        switch lesson {
        case .select, .back: return 1
        case .move: return 2
        case .list: return listOrder.count
        }
    }

    static func itemID(lesson: Int, step: Int, slot: Int) -> String { "band.\(lesson).\(step).\(slot)" }

    /// The (lesson, step, slot) an id was drawn for, or nil when it is not a lesson button.
    static func parse(_ id: String) -> (lesson: Int, step: Int, slot: Int)? {
        let parts = id.split(separator: ".")
        guard parts.count == 4, parts[0] == "band",
              let lesson = Int(parts[1]), let step = Int(parts[2]), let slot = Int(parts[3]) else { return nil }
        return (lesson, step, slot)
    }

    /// A press on the button `id`, arriving at `at`.
    mutating func press(_ id: String, at: Date) -> Outcome {
        guard let lesson = currentLesson, let pressed = Self.parse(id),
              pressed.lesson == lessonIndex, pressed.step == step,
              (0..<Self.slotCount(lesson)).contains(pressed.slot) else {
            stalePresses += 1
            return .stale
        }
        pressTimes.append(at)
        guard pressed.slot == Self.targetSlot(lesson: lesson, step: step) else {
            wrong[lessonIndex] += 1
            return .wrong
        }
        arrived[lessonIndex] += 1
        step += 1
        guard step >= lesson.requiredPresses else { return .advanced }
        lessonIndex += 1
        step = 0
        return isFinished ? .finished : .lessonPassed(lesson)
    }

    /// A press dropped before it reached the lesson: §2's revision gate found a newer frame.
    mutating func noteStalePress() {
        stalePresses += 1
    }

    /// Time between consecutive presses that counted, in milliseconds.
    var intervalsMs: [Int] {
        zip(pressTimes, pressTimes.dropFirst()).map { Int(($1.timeIntervalSince($0) * 1000).rounded()) }
    }

    /// The run as the report keeps it.
    func result(ending: BandCheckResult.Ending, backend: String, at: Date) -> BandCheckResult {
        BandCheckResult(
            endedAt: at, ending: ending, backend: backend,
            lessons: lessons.indices.map {
                BandCheckResult.Lesson(lesson: lessons[$0], required: lessons[$0].requiredPresses,
                                       arrived: arrived[$0], wrong: wrong[$0])
            },
            stalePresses: stalePresses,
            intervalsMs: Array(intervalsMs.suffix(BandCheckResult.maxIntervals)))
    }
}

/// Builds the band check's `HUDScreen`s (Plan KP §5). Pure: a press is reported by its item id.
///
/// | Lesson | Lines | Buttons |
/// |---|---|---|
/// | 1 · Select | passed lessons, "1 of 3 · Select", the instruction, ●○○ | Press me |
/// | 2 · Move | the same | ● · ○ (the marked one moves) |
/// | 3 · A list | the same, six dots | six numbered buttons; pressed ones show ✓ |
/// | done | "✓ Select ✓ Move ✓ A list", where the results went | Done |
enum BandPracticeCardBuilder {
    static var title: String { String(localized: "Practise the band") }

    static func screen(for practice: BandPractice, onPress: @escaping (String) -> Void) -> HUDScreen {
        guard let lesson = practice.currentLesson else { return finished(practice, onPress: onPress) }
        let index = practice.lessonIndex
        var lines: [HUDLine] = []
        if let passed = passedLine(practice) { lines.append(HUDLine(passed, emphasis: .meta)) }
        lines.append(HUDLine(String(localized: "\(index + 1) of \(practice.lessons.count) · \(lesson.title)",
                                    comment: "Band check: which lesson, e.g. '2 of 3 · Move'."),
                             emphasis: .meta))
        lines.append(HUDLine(lesson.instruction, emphasis: .secondary))
        lines.append(HUDLine(dots(filled: practice.step, of: lesson.requiredPresses)))

        let target = practice.targetSlot ?? 0
        let items: [HUDItem] = (0..<BandPractice.slotCount(lesson)).map { slot in
            let id = BandPractice.itemID(lesson: index, step: practice.step, slot: slot)
            let label: String
            var style = HUDButtonStyle.secondary
            switch lesson {
            case .select, .back:
                label = String(localized: "Press me")
                style = .primary
            case .move:
                label = slot == target ? "●" : "○"
                if slot == target { style = .primary }
            case .list:
                let number = BandPractice.listOrder[slot]
                label = number <= practice.step ? "✓" : "\(number)"
            }
            return HUDItem(id: id, label: label, style: style) { onPress(id) }
        }
        return HUDScreen(title: title, lines: lines, items: items)
    }

    /// Filled dots for the presses that arrived, open ones for the rest.
    static func dots(filled: Int, of total: Int) -> String {
        let done = min(max(filled, 0), total)
        return String(repeating: "●", count: done) + String(repeating: "○", count: total - done)
    }

    private static func passedLine(_ practice: BandPractice) -> String? {
        let passed = practice.lessons.prefix(practice.lessonIndex).map { "✓ \($0.title)" }
        return passed.isEmpty ? nil : passed.joined(separator: " ")
    }

    private static func finished(_ practice: BandPractice, onPress: @escaping (String) -> Void) -> HUDScreen {
        let lines = [
            HUDLine(passedLine(practice) ?? "", icon: .success),
            HUDLine(String(localized: "The band reached every button. The results are in your support report."),
                    emphasis: .secondary),
        ]
        let done = HUDItem(id: BandPractice.doneID, label: String(localized: "Done"), icon: .success,
                           style: .primary) { onPress(BandPractice.doneID) }
        return HUDScreen(title: title, lines: lines, items: [done])
    }
}

/// The last band check, as the support report keeps it (Plan KP §5): which lessons passed, the
/// presses asked for that never arrived, the wrong and the stale ones, the time between presses,
/// and the backend. Counts, case names and milliseconds: nothing about the wearer.
struct BandCheckResult: Codable, Equatable {
    enum Ending: String, Codable, Equatable {
        /// Every lesson passed.
        case finished
        /// Stop on the phone.
        case stopped
        /// No press for the card's lifetime.
        case timedOut
        /// Something else took the lens (a task card, a menu, the HUD turned off).
        case interrupted
    }

    struct Lesson: Codable, Equatable {
        let lesson: BandLesson
        let required: Int
        let arrived: Int
        let wrong: Int
        var passed: Bool { arrived >= required }
        var missing: Int { max(0, required - arrived) }
    }

    /// The report keeps the newest intervals only.
    static let maxIntervals = 40

    let endedAt: Date
    let ending: Ending
    /// The display backend's token (`metaRayBan`, `evenG2`).
    let backend: String
    let lessons: [Lesson]
    let stalePresses: Int
    let intervalsMs: [Int]

    var lessonsPassed: Int { lessons.filter(\.passed).count }
    /// Presses the run asked for that never arrived.
    var pressesNotArrived: Int { lessons.reduce(0) { $0 + $1.missing } }
    var wrongPresses: Int { lessons.reduce(0) { $0 + $1.wrong } }
}

/// The support report's **Band check** section (Plan KP §5).
enum BandCheckReport {
    static func lines(for result: BandCheckResult?, timeZone: TimeZone = .current) -> [String] {
        guard let result else { return ["Band check: not run on this phone"] }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let passed = result.lessons.filter(\.passed).map(\.lesson.rawValue)
        var lines = [
            "Band check (last run \(formatter.string(from: result.endedAt)), backend \(result.backend), \(result.ending.rawValue)):",
            "  Lessons passed: \(result.lessonsPassed) of \(result.lessons.count)"
                + (passed.isEmpty ? "" : " (\(passed.joined(separator: ", ")))"),
            "  Presses asked for that didn't arrive: \(result.pressesNotArrived)"
                + perLesson(result.lessons.map { ($0.lesson, $0.missing) }),
            "  Wrong presses: \(result.wrongPresses)" + perLesson(result.lessons.map { ($0.lesson, $0.wrong) }),
            "  Stale presses dropped: \(result.stalePresses)",
        ]
        lines.append("  Time between presses: " + intervalSummary(result.intervalsMs))
        return lines
    }

    private static func perLesson(_ counts: [(BandLesson, Int)]) -> String {
        let nonZero = counts.filter { $0.1 > 0 }.map { "\($0.0.rawValue) \($0.1)" }
        return nonZero.isEmpty ? "" : " (\(nonZero.joined(separator: ", ")))"
    }

    static func intervalSummary(_ intervals: [Int]) -> String {
        guard !intervals.isEmpty else { return "none" }
        let sorted = intervals.sorted()
        let median = sorted.count % 2 == 1
            ? sorted[sorted.count / 2]
            : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        return "\(sorted.count) gaps, median \(median) ms, fastest \(sorted[0]) ms, slowest \(sorted[sorted.count - 1]) ms"
    }
}

/// Keeps the last band check only, in the app's preferences (Plan KP §5). One value, replaced by
/// every run; counts and timings only.
struct BandCheckStore {
    static let key = "bandCheckLastRun"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> BandCheckResult? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(BandCheckResult.self, from: data)
    }

    func save(_ result: BandCheckResult) {
        guard let data = try? JSONEncoder().encode(result) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
