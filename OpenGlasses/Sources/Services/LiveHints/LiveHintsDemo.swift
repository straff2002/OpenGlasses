import Foundation

/// The demo session (Plan MO §11): a canned two-voice conversation played inside the app, through
/// the same session code as a real one, answering from a bundled sample document. For a first-time
/// wearer, and for App Review, who must see the feature work without a real conversation.
///
/// - The conversation arrives through the `HintCaptionSource` seam (`DemoHintCaptionSource`), on the
///   session's clock: the first question is said 4 s in, so its passage card is up well inside the
///   10 s the plan asks for.
/// - **It never touches the microphone.** No caption service, no mic level: the speech-activity
///   source is `SilentHintVoiceActivity`, which hears nothing.
/// - The sample document is invented. It names no company, product or person, and holds no price.
/// - It searches only the sample document, never the wearer's own.
/// - It never charges the daily allowance.
enum LiveHintsDemo {

    /// One line of the conversation: when it is said, from the start, and by which voice. Voice 0 is
    /// the wearer, voice 1 the visitor asking the questions.
    struct Line: Equatable, Sendable {
        let at: TimeInterval
        let speaker: Int
        let text: String
    }

    static let wearerSpeaker = 0
    static let visitorSpeaker = 1

    static let lines: [Line] = [
        Line(at: 0.5, speaker: visitorSpeaker, text: "Thanks for coming round to look at the garden."),
        Line(at: 2.0, speaker: wearerSpeaker, text: "Happy to. The corner by the fence would suit the studio well."),
        Line(at: 4.0, speaker: visitorSpeaker, text: "How many days does the installation take on site?"),
        Line(at: 11.0, speaker: wearerSpeaker, text: "We would book the days with you well in advance."),
        Line(at: 14.0, speaker: visitorSpeaker, text: "What is the warranty on the roof?"),
        Line(at: 21.0, speaker: wearerSpeaker, text: "Most of the building is covered for a long time."),
        Line(at: 24.0, speaker: visitorSpeaker, text: "Could you tell me whether we need planning permission for it?"),
        Line(at: 31.0, speaker: wearerSpeaker, text: "The survey visit checks that before anything is ordered."),
        Line(at: 34.0, speaker: visitorSpeaker, text: "Will it be warm enough to use in the winter?"),
    ]

    /// The session stops itself this long after the last line, so its card can be read first.
    static let endsAt: TimeInterval = 34.0 + HintLimits.lensCardLifetime

    /// When the first question is asked: what the 10 s target is measured from the start against.
    static var firstQuestionAt: TimeInterval { lines.first { $0.text.hasSuffix("?") }?.at ?? 0 }

    // MARK: - The sample document

    static let documentId = "live-hints-demo-sample"

    static var documentName: String {
        String(localized: "Sample: garden studio",
               comment: "Live hints demo: the name of the invented sample document the demo answers from.")
    }

    /// The sample document's passages, in order. English, like the conversation.
    static let passages: [String] = [
        "What the quote covers. The studio is three by four metres, with one glazed door and two opening windows. It stands on a ground-screw frame, so no concrete is poured.",
        "Delivery and installation. Panels are made to order and arrive about six weeks after the order is confirmed. Installation takes 3 days on site: the base on day one, the walls and roof on day two, and the electrics on day three.",
        "Warranty. The frame and wall panels have a 15-year structural warranty. The roof membrane has a 10-year warranty. Doors and windows are covered for 5 years.",
        "Planning. A studio under two and a half metres high, set at least two metres from the boundary, usually needs no planning application. The survey visit checks the height and the boundary first.",
        "Insulation. Walls, floor and roof are insulated, so the studio stays warm enough to use in winter. A small panel heater comes with it.",
    ]

    static func passage(_ index: Int) -> HintPassage {
        HintPassage(documentId: documentId, documentName: documentName, chunkIndex: index, text: passages[index])
    }

    /// The passage a demo hint's press opens.
    static func passageText(documentId: String, chunkIndex: Int) -> String? {
        guard documentId == self.documentId, passages.indices.contains(chunkIndex) else { return nil }
        return passages[chunkIndex]
    }

    /// The demo's carriers. The lens, the ear, the model, the phone list and the clock are the real
    /// session's kind; the captions, the documents, the mic level and the allowance are the demo's.
    @MainActor
    static func carriers(model: HintModel, lens: HintLensSink, ear: HintEarSink, phoneList: HintPhoneListSink,
                         clock: HintClock) -> (carriers: LiveHintsService.Carriers, captions: DemoHintCaptionSource) {
        let captions = DemoHintCaptionSource(clock: clock)
        let carriers = LiveHintsService.Carriers(
            captions: captions, documents: DemoHintDocuments(), model: model, lens: lens, ear: ear,
            voiceActivity: SilentHintVoiceActivity(), phoneList: phoneList, clock: clock,
            allowance: UnlimitedHintAllowance())
        return (carriers, captions)
    }
}

/// The demo's conversation as captions: each line becomes a final caption at its time, on the
/// session's clock. Nothing is heard and nothing is recognised.
@MainActor
final class DemoHintCaptionSource: HintCaptionSource {
    static let pumpInterval: TimeInterval = 0.25

    private let clock: HintClock
    private let lines: [LiveHintsDemo.Line]
    private let endsAt: TimeInterval
    private(set) var isActive = false
    private(set) var captionHistory: [AmbientCaptionService.CaptionEntry] = []
    let languageCode = "en"
    var onHistoryChanged: (() -> Void)?
    var contextualStrings: [String] = []
    /// The conversation is over and its last card has had its time.
    var onFinished: (() -> Void)?

    private var startedAt: Date?
    private var next = 0
    private var seq: UInt64 = 0
    private var finished = false
    private var cancelPump: (() -> Void)?

    init(clock: HintClock, lines: [LiveHintsDemo.Line] = LiveHintsDemo.lines,
         endsAt: TimeInterval = LiveHintsDemo.endsAt) {
        self.clock = clock
        self.lines = lines
        self.endsAt = endsAt
    }

    func start() {
        guard !isActive else { return }
        isActive = true
        startedAt = clock.now
        next = 0
        finished = false
        captionHistory = []
        cancelPump = clock.repeating(every: Self.pumpInterval) { [weak self] in self?.pump() }
    }

    func stop() {
        cancelPump?()
        cancelPump = nil
        isActive = false
        startedAt = nil
        captionHistory = []
    }

    /// Say every line whose time has come, newest first in the history as captions are.
    func pump() {
        guard isActive, let startedAt else { return }
        let elapsed = clock.now.timeIntervalSince(startedAt)
        var said = false
        while next < lines.count, lines[next].at <= elapsed + HintLimits.timeTolerance {
            seq += 1
            let line = lines[next]
            captionHistory.insert(AmbientCaptionService.CaptionEntry(
                text: line.text, timestamp: startedAt.addingTimeInterval(line.at), seq: seq,
                speaker: line.speaker), at: 0)
            next += 1
            said = true
        }
        if said { onHistoryChanged?() }
        if !finished, elapsed >= endsAt - HintLimits.timeTolerance {
            finished = true
            onFinished?()
        }
    }
}

/// The sample document, searched by shared words: the passages that hold the most of the
/// question's content words, best first. On the phone, with no index.
@MainActor
final class DemoHintDocuments: HintDocumentSearch {
    init() {}

    func passages(for question: String, limit: Int) -> [HintPassage] {
        let terms = Self.terms(question)
        guard !terms.isEmpty else { return [] }
        let scored = LiveHintsDemo.passages.indices.map { index in
            (index, terms.intersection(Self.terms(LiveHintsDemo.passages[index])).count)
        }
        return scored.filter { $0.1 > 0 }
            .sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
            .prefix(max(limit, 0))
            .map { LiveHintsDemo.passage($0.0) }
    }

    func documentTitles() -> [String] { [LiveHintsDemo.documentName] }

    private static func terms(_ text: String) -> Set<String> {
        Set(HintText.contentWords(text).subtracting(HintText.questionWords).map { word in
            word.count > 3 && word.hasSuffix("s") && !word.hasSuffix("ss") ? String(word.dropLast()) : word
        })
    }
}

/// A speech-activity source that hears nothing: the demo's, so no mic is ever opened for it.
@MainActor
final class SilentHintVoiceActivity: HintVoiceActivitySource {
    init() {}
    func start(onChange: @escaping (Bool) -> Void) {}
    func stop() {}
}
