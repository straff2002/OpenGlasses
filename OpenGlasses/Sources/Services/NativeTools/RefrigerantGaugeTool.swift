import Foundation

/// `refrigerant_gauges` — "what's my superheat?" with the camera on a manifold or a digital gauge
/// set, answered in one step (Plan IS P1).
///
/// One still, filtered at the chokepoint under `.visionAssessment` (it goes to a cloud model with
/// the instrument-reading schema attached, and the same filtered bytes are what the job keeps), is
/// read by `instrument_reading`. `RefrigerantGaugeChain` then assigns the roles from the gauges'
/// own labels, asks what it cannot tell, and runs the same saturation lookup `domain_calc` uses.
/// The answer is in the technician's units (`RefrigerationUnitsSetting`), and each reading is
/// recorded on the open job with the photo, the method and the refrigerant's source.
///
/// A follow-up that answers this tool's question ("the left one is suction") reuses the same
/// photograph (`reuse_last_capture`), so the answer and the record describe one frame.
@MainActor
final class RefrigerantGaugeTool: NativeTool {
    let name = "refrigerant_gauges"
    let description = """
    Superheat and subcooling straight from the gauges: reads the manifold or digital gauge set in \
    view of the camera (\(GlassesSupportPolicy.toolCameraSource)), tells suction from liquid \
    by the gauges' own LOW/HIGH, colour or SUCTION/LIQUID labels, and computes from the bundled \
    CoolProp tables in the technician's units. Use it for "what's my superheat/subcool?" with gauges \
    in view. Pass 'refrigerant' only from the nameplate or the technician — never assume one; \
    without it the answer is pressures only. Line temperatures come from a probe in the picture or \
    from what the technician says ('suction_line_temp_f' / '_c'). When this tool asks which gauge \
    is which, call it again with the answer ('suction_gauge': 'left', or the value shown) and \
    'reuse_last_capture': true. Readings are recorded on the open job with the photo. When no \
    picture can be taken or the reading is unusable, this tool offers voice instead: take the \
    pressures and line temperatures the technician says to domain_calc ('superheat' / 'subcool'), \
    which checks and records them the same way.
    """

    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "calculation": [
                "type": "string",
                "enum": ["superheat", "subcool", "both"],
                "description": "What was asked for. Default 'both'."
            ],
            "refrigerant": [
                "type": "string",
                "description": "Refrigerant designation, only from the nameplate or the technician (e.g. R-410A). Omit if unknown."
            ],
            "refrigerant_source": [
                "type": "string",
                "enum": ["nameplate", "technician"],
                "description": "Where 'refrigerant' came from."
            ],
            "suction_line_temp_f": ["type": "number", "description": "Suction line temperature the technician said (°F)."],
            "suction_line_temp_c": ["type": "number", "description": "Suction line temperature the technician said (°C)."],
            "liquid_line_temp_f": ["type": "number", "description": "Liquid line temperature the technician said (°F)."],
            "liquid_line_temp_c": ["type": "number", "description": "Liquid line temperature the technician said (°C)."],
            "suction_gauge": [
                "type": "string",
                "description": "The technician's answer: which gauge is suction — 'left', 'middle', 'right', or the value it shows."
            ],
            "liquid_gauge": [
                "type": "string",
                "description": "The technician's answer: which gauge is on the liquid line — a position or the value it shows."
            ],
            "discharge_gauge": [
                "type": "string",
                "description": "The technician's answer: which gauge is on the discharge line."
            ],
            "suction_probe": [
                "type": "string",
                "description": "The technician's answer: which probe is on the suction line — a position, the value it shows, or 'probe' when there is one."
            ],
            "liquid_probe": [
                "type": "string",
                "description": "The technician's answer: which probe is on the liquid line."
            ],
            "application": [
                "type": "string",
                "enum": ["cooling", "heating", "refrigeration"],
                "description": "What the system is doing, if the technician said: comfort cooling (AC or heat pump cooling), heat pump heating, or refrigeration."
            ],
            "reuse_last_capture": [
                "type": "boolean",
                "description": "True when answering this tool's own question, so the same photo is used."
            ],
            "altitude_ft": ["type": "number", "description": "Optional site altitude (feet) to correct gauge pressure."],
            "altitude_m": ["type": "number", "description": "Optional site altitude (metres) to correct gauge pressure."]
        ],
        "required": [] as [String]
    ]

    /// How long a photograph stays answerable by a follow-up.
    static let captureLifetime: TimeInterval = 10 * 60

    /// Typed as the privacy chokepoint (W04.1): the still goes to a cloud model and onto the job,
    /// and both copies are the filtered one.
    private let cameraService: any FilteredStillProviding
    /// Where the photo and the readings are filed; the shared session service in the app.
    private let recorder: any RefrigerantReadingFiling
    /// The instrument-reading assessment of a JPEG. The live structured-vision service by default;
    /// a test injects a fixture so no model is called.
    private let assess: @MainActor (Data) async throws -> AssessmentCard
    private let units: @MainActor () -> RefrigerationUnits
    private let fieldAssistActive: @MainActor () -> Bool
    private let bundle: Bundle
    private let now: () -> Date

    /// The last photograph and what it read, for a follow-up answer.
    private struct Capture {
        let readings: [InstrumentReading]
        let photoId: String?
        let takenAt: Date
        var recordedKeys: Set<String> = []
    }
    private var lastCapture: Capture?

    init(cameraService: any FilteredStillProviding,
         recorder: any RefrigerantReadingFiling,
         assess: (@MainActor (Data) async throws -> AssessmentCard)? = nil,
         units: (@MainActor () -> RefrigerationUnits)? = nil,
         fieldAssistActive: (@MainActor () -> Bool)? = nil,
         bundle: Bundle = .main,
         now: @escaping () -> Date = { Date() }) {
        self.cameraService = cameraService
        self.recorder = recorder
        self.assess = assess ?? { data in
            try await StructuredVisionService.shared.assess(kind: "instrument_reading", imageData: data,
                                                            note: "Refrigerant manifold or digital gauge set.")
        }
        self.units = units ?? { RefrigerationUnitsSetting.current }
        self.fieldAssistActive = fieldAssistActive ?? { Config.fieldAssistActive }
        self.bundle = bundle
        self.now = now
    }

    func execute(args: [String: Any]) async throws -> String {
        guard fieldAssistActive() else {
            return "Field Assist is disabled. Enable it in Settings → Field Assist."
        }
        var request = RefrigerantGaugeChain.Request()
        switch Self.site(args) {
        case .success(let site):
            request.atmosphere = site.atmosphere
            request.altitudeText = site.altitudeText
        case .failure(let problem):
            return problem.text
        }
        request.calculations = Self.calculations(args["calculation"] as? String)
        request.refrigerant = refrigerant(args)
        request.spokenLines = Self.spokenLines(args)
        request.hints = Self.hints(args)
        request.application = (args["application"] as? String)
            .flatMap { InstrumentPlausibility.RefrigerantApplication(rawValue: $0.lowercased()) } ?? .unspecified
        request.units = units()

        let capture: Capture
        if Self.bool(args["reuse_last_capture"]), let last = lastCapture,
           now().timeIntervalSince(last.takenAt) <= Self.captureLifetime {
            capture = last
        } else {
            switch await takeCapture() {
            case .success(let fresh): capture = fresh
            // No picture, or one that read as nothing: the existing line, then the voice way on.
            case .failure(let problem): return problem.text + " " + Self.voiceOffer(request.calculations)
            }
        }

        let outcome = RefrigerantGaugeChain.run(readings: capture.readings, request: request) { [bundle] designation in
            SaturationTableCatalog.table(for: designation, bundle: bundle)
        }
        var reply = outcome.text
        if outcome.asksRecapture && outcome.answered.isEmpty {
            // Nothing could be worked out from the picture; saying the values is the other way.
            reply += " " + Self.voiceOffer(request.calculations)
        }
        if let note = record(outcome.recordable, capture: capture, refrigerant: request.refrigerant) {
            reply += " " + note
        }
        return reply
    }

    // MARK: - The voice fallback

    /// The way on when the picture gave nothing: the values the calculation needs, said aloud,
    /// which the model takes to `domain_calc`.
    static func voiceOffer(_ calculations: [RefrigerantLineCalculation.Kind]) -> String {
        switch Set(calculations) {
        case [.superheat]:
            return "Or tell me the suction pressure and suction line temperature and I'll work it out."
        case [.subcool]:
            return "Or tell me the liquid pressure and liquid line temperature and I'll work it out."
        default:
            return "Or tell me the suction and liquid pressures and line temperatures and I'll work it out."
        }
    }

    // MARK: - The photograph

    private struct Problem: Error { let text: String }

    private func takeCapture() async -> Result<Capture, Problem> {
        // Fails closed: an unavailable filter returns `.unavailable`, never the source pixels.
        // `.photoOnly`, as `SharpStillCapture` does: on glasses the cached frame is the throttled
        // stream frame, too soft for a needle or a small digit, so a reading takes a fresh full
        // still. On the phone there is no cached frame, so nothing changes there.
        guard let jpeg = await cameraService.filteredStill(for: .visionAssessment, source: .photoOnly)
            .jpegData(compressionQuality: SharpStillCapture.jpegQuality) else {
            return .failure(Problem(text: "I couldn't get a picture from the camera. Point it at the gauges and try again."))
        }
        let card: AssessmentCard
        do {
            card = try await assess(jpeg)
        } catch {
            return .failure(Problem(text: "The gauge reading didn't come back usable. Try again with a steadier, closer view of the gauges."))
        }
        // The same filtered bytes the model saw are what the job keeps.
        var photoId: String?
        if recorder.isOpenForEvidence {
            photoId = recorder.attachPhoto(jpeg, caption: "Gauge reading", origin: .photoLog,
                                           filterWasOn: Config.privacyFilterEnabled)?.lastPathComponent
        }
        let capture = Capture(readings: card.readings, photoId: photoId, takenAt: now())
        lastCapture = capture
        return .success(capture)
    }

    // MARK: - Recording

    /// Files what the chain says is worth keeping, once per photograph, and says so.
    private func record(_ readings: [RefrigerantGaugeChain.RecordableReading], capture: Capture,
                        refrigerant: RefrigerantIdentity?) -> String? {
        let fresh = readings.filter { !capture.recordedKeys.contains($0.key) }
        guard !fresh.isEmpty else { return nil }
        guard recorder.isOpenForEvidence else { return "Not recorded: no job is open." }
        var recorded = 0
        var keys = capture.recordedKeys
        for reading in fresh {
            let saved = recorder.recordInstrumentReading(
                quantity: reading.quantity, value: reading.value, unit: reading.unit,
                method: reading.fromInstrument ? SpokenReading.instrumentReadingMethod : nil,
                photoId: reading.fromInstrument ? capture.photoId : nil,
                refrigerant: refrigerant?.designation, refrigerantSource: refrigerant?.source.rawValue,
                at: now())
            if saved != nil {
                recorded += 1
                keys.insert(reading.key)
            }
        }
        if var last = lastCapture, last.takenAt == capture.takenAt {
            last.recordedKeys = keys
            lastCapture = last
        }
        guard recorded > 0 else { return nil }
        return recorded == 1 ? "Recorded 1 reading on the job." : "Recorded \(recorded) readings on the job."
    }

    // MARK: - Arguments

    /// The refrigerant from the technician or the nameplate, else the job's recorded one, else none.
    private func refrigerant(_ args: [String: Any]) -> RefrigerantIdentity? {
        if let raw = (args["refrigerant"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let source: RefrigerantSource = (args["refrigerant_source"] as? String)?.lowercased() == "nameplate"
                ? .nameplate : .technician
            return RefrigerantIdentity(designation: SaturationTableCatalog.designation(for: raw) ?? raw, source: source)
        }
        if let field = recorder.activeRefrigerant {
            return RefrigerantIdentity(designation: SaturationTableCatalog.designation(for: field.value) ?? field.value,
                                       source: RefrigerantSource(identity: field.source))
        }
        return nil
    }

    private static func calculations(_ raw: String?) -> [RefrigerantLineCalculation.Kind] {
        switch raw?.lowercased() {
        case "superheat": return [.superheat]
        case "subcool", "subcooling": return [.subcool]
        default: return [.superheat, .subcool]
        }
    }

    private static func spokenLines(_ args: [String: Any]) -> [ProbeLine: RefrigerantGaugeChain.LineTemperature] {
        var lines: [ProbeLine: RefrigerantGaugeChain.LineTemperature] = [:]
        for line in [ProbeLine.suction, .liquid] {
            if let f = number(args["\(line.rawValue)_line_temp_f"]) {
                lines[line] = .init(value: f, scale: .fahrenheit)
            } else if let c = number(args["\(line.rawValue)_line_temp_c"]) {
                lines[line] = .init(value: c, scale: .celsius)
            }
        }
        return lines
    }

    private static func hints(_ args: [String: Any]) -> GaugeRoleResolver.Hints {
        var hints = GaugeRoleResolver.Hints()
        for role in GaugeRole.allCases {
            if let text = hintText(args["\(role.rawValue)_gauge"]) { hints.gauges[role] = text }
        }
        for line in [ProbeLine.suction, .liquid] {
            if let text = hintText(args["\(line.rawValue)_probe"]) { hints.probes[line] = text }
        }
        return hints
    }

    private static func hintText(_ value: Any?) -> String? {
        if let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { return text }
        if let number = number(value) { return DomainCalcTool.oneDecimal(number) }
        return nil
    }

    private struct Site {
        let atmosphere: Atmosphere
        let altitudeText: String?
    }

    private static func site(_ args: [String: Any]) -> Result<Site, Problem> {
        let refusal = Problem(text: "The altitude is outside what the correction accepts (−500 m to 6,000 m, about −1,640 ft to 19,690 ft).")
        if let metres = number(args["altitude_m"]) {
            guard let atmosphere = Atmosphere.at(altitudeMetres: metres) else { return .failure(refusal) }
            return .success(Site(atmosphere: atmosphere, altitudeText: "\(Int(metres.rounded())) m"))
        }
        if let feet = number(args["altitude_ft"]) {
            guard let atmosphere = Atmosphere.at(altitudeFeet: feet) else { return .failure(refusal) }
            return .success(Site(atmosphere: atmosphere, altitudeText: "\(Int(feet.rounded())) ft"))
        }
        return .success(Site(atmosphere: .seaLevel, altitudeText: nil))
    }

    private static func number(_ value: Any?) -> Double? {
        let parsed: Double?
        if let d = value as? Double { parsed = d }
        else if let i = value as? Int { parsed = Double(i) }
        else if let s = value as? String { parsed = Double(s.trimmingCharacters(in: .whitespaces)) }
        else { parsed = nil }
        guard let parsed, parsed.isFinite else { return nil }
        return parsed
    }

    private static func bool(_ value: Any?) -> Bool {
        if let b = value as? Bool { return b }
        if let s = value as? String { return ["true", "yes", "1"].contains(s.lowercased()) }
        if let n = value as? NSNumber { return n.boolValue }
        return false
    }
}
