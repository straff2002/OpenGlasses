import Foundation

/// Where one kind of data goes when the assistant handles a request.
///
/// Five cases rather than a boolean, because "on device or not" is the question a mixed setup is
/// most easily lied to about. A configured cloud provider, a URL the wearer typed themselves, a
/// feature that is switched off, and a local feature whose model was never downloaded are four
/// different answers, and only the first two mean anything leaves.
enum ProcessingDestination: Equatable {
    /// Handled entirely on this phone or in the glasses. Nothing leaves.
    case onDevice
    /// Sent to a named cloud service.
    case cloud(provider: String)
    /// Sent to an endpoint the wearer configured. **Host only, ever** — a base URL can carry a
    /// path, a query and, for some providers, a key, and this line is read aloud and screenshotted.
    case customEndpoint(host: String)
    /// Switched off. Nothing is handled at all, here or anywhere.
    case disabled
    /// Configured to run on this device, but the files it needs are not downloaded. Not on-device
    /// and not cloud — a promise that cannot currently be kept, which is why it is its own case.
    case unavailable(missingAsset: String)

    /// Whether anything leaves this device for this row.
    var leavesDevice: Bool {
        switch self {
        case .cloud, .customEndpoint: return true
        case .onDevice, .disabled, .unavailable: return false
        }
    }

    /// Whether this row is doing anything at all.
    var isActive: Bool { self != .disabled }

    /// A short, fixed token for a log or a test. Never a host, never a provider key.
    var token: String {
        switch self {
        case .onDevice: return "onDevice"
        case .cloud: return "cloud"
        case .customEndpoint: return "customEndpoint"
        case .disabled: return "disabled"
        case .unavailable: return "unavailable"
        }
    }

    /// How this destination reads in a sentence, e.g. "stays on this device".
    var phrase: String {
        switch self {
        case .onDevice:
            return "stays on this device"
        case .cloud(let provider):
            return "goes to \(provider)"
        case .customEndpoint(let host):
            return "goes to the server you set up, \(host)"
        case .disabled:
            return "is switched off"
        case .unavailable(let asset):
            return "is set to run on this device, but \(asset) hasn't been downloaded yet"
        }
    }
}

/// The five things a request is made of, in the order a wearer meets them.
enum ProcessingRowKind: String, CaseIterable, Identifiable, Equatable {
    case image
    case transcription
    case aiResponse
    case spokenVoice
    case remoteTools

    var id: String { rawValue }

    var title: String {
        switch self {
        case .image: return "What the camera sees"
        case .transcription: return "What you say"
        case .aiResponse: return "The answer"
        case .spokenVoice: return "The voice you hear"
        case .remoteTools: return "Tools on other machines"
        }
    }
}

/// One row of the processing summary.
struct ProcessingRow: Equatable, Identifiable {
    let kind: ProcessingRowKind
    let destination: ProcessingDestination
    /// The one line spoken, and the row's accessibility label. Complete on its own: a row read out
    /// of context still says what it is about and where the data goes.
    let spokenForm: String
    /// The short value shown beside the title.
    let shortValue: String

    var id: String { kind.rawValue }
}

/// What the whole configuration adds up to.
enum ProcessingVerdict: Equatable {
    /// Every active row is handled on this device and every asset it needs is present.
    case fullyOnDevice
    /// Some of it leaves. Carries the rows that do, so the sentence can name them rather than
    /// leaving the wearer to work out which half is which.
    case mixed(rows: [ProcessingRowKind])
    /// Every active row leaves the device.
    case cloud

    var token: String {
        switch self {
        case .fullyOnDevice: return "fullyOnDevice"
        case .mixed: return "mixed"
        case .cloud: return "cloud"
        }
    }
}

/// Plan FF P1/PR8 — what actually happens to a request, composed from what is configured.
///
/// # Why a screen for this
///
/// The app already knows every answer: which model is selected, which voice engine, which
/// recogniser, whether a gateway is live, whether the medical local-only rule is on. What it never
/// did was put them in one place in the wearer's own terms. Someone deciding whether to read a
/// letter, a prescription or a bank statement through these glasses is entitled to know, before
/// they hold it up, which of those five things leaves the phone.
///
/// # The two rules that make it honest
///
/// 1. **Nothing is called fully on-device unless every active row is on-device and its assets are
///    present.** A local model that was never downloaded is `unavailable`, not `onDevice`, and it
///    takes the verdict out of `fullyOnDevice` on its own. Anything else is a promise that breaks
///    the first time the wearer goes offline believing it.
/// 2. **This describes intended routing, not observed traffic.** It is composed from settings. The
///    network monitor is a separate, *observed* record, and it is not a complete packet audit —
///    both surfaces say so in their own copy, because a summary that is quietly taken for proof is
///    worse than no summary.
enum ProcessingSummary {

    /// The composed answer.
    struct Composed: Equatable {
        let rows: [ProcessingRow]
        let verdict: ProcessingVerdict
        /// Named before any offline promise: the downloads that are missing. `nil` when nothing is.
        let offlineLine: String?
        /// Everything above as one spoken paragraph.
        let spoken: String
    }

    /// The sentence both surfaces carry, verbatim, about what this is and is not.
    static let evidenceCaveat =
        "This describes how your settings are configured to route each request. It isn't a record "
        + "of what was actually sent. Network Activity shows requests the app observed, and even "
        + "that is not a complete audit of every packet."

    // MARK: - Composition

    static func compose(facts: ProcessingFacts) -> Composed {
        let rows = ProcessingRowKind.allCases.map { row(for: $0, facts: facts) }
        let verdict = verdict(for: rows)
        let offlineLine = offlineSentence(rows: rows, facts: facts)
        return Composed(rows: rows,
                        verdict: verdict,
                        offlineLine: offlineLine,
                        spoken: spokenSummary(rows: rows, verdict: verdict, offlineLine: offlineLine))
    }

    static func verdict(for rows: [ProcessingRow]) -> ProcessingVerdict {
        let active = rows.filter { $0.destination.isActive }
        // A row that is neither on-device nor leaving — an unavailable asset — is deliberately in
        // neither bucket, so it can satisfy neither "all on device" nor "all cloud".
        if active.allSatisfy({ $0.destination == .onDevice }) { return .fullyOnDevice }
        if active.allSatisfy({ $0.destination.leavesDevice }) { return .cloud }
        return .mixed(rows: active.filter { $0.destination != .onDevice }.map(\.kind))
    }

    // MARK: - Rows

    private static func row(for kind: ProcessingRowKind, facts: ProcessingFacts) -> ProcessingRow {
        let destination = destination(for: kind, facts: facts)
        return ProcessingRow(kind: kind,
                             destination: destination,
                             spokenForm: "\(kind.title): \(destination.phrase).",
                             shortValue: shortValue(destination))
    }

    private static func destination(for kind: ProcessingRowKind,
                                    facts: ProcessingFacts) -> ProcessingDestination {
        let configured = configuredDestination(for: kind, facts: facts)
        // Medical Compliance's local-only rule does not reroute a cloud request quietly — it stops
        // it. A row that would leave the device therefore reads as switched off while the rule is
        // on, which is what the wearer will actually experience.
        if facts.medicalLocalOnly, configured.leavesDevice { return .disabled }
        return configured
    }

    private static func configuredDestination(for kind: ProcessingRowKind,
                                              facts: ProcessingFacts) -> ProcessingDestination {
        switch kind {
        case .image:
            // A live session streams frames to its own provider. Outside one, frames only leave if
            // the selected model can actually take them.
            if let live = facts.liveProviderName { return .cloud(provider: live) }
            guard facts.modelAcceptsImages else { return .disabled }
            return modelDestination(facts)
        case .transcription:
            if let live = facts.liveProviderName { return .cloud(provider: live) }
            if facts.diarizationEnabled, let vendor = facts.diarizationProviderName {
                return .cloud(provider: vendor)
            }
            if facts.speechRecognitionOnDevice {
                guard facts.speechRecognitionAssetPresent else {
                    return .unavailable(missingAsset: facts.speechRecognitionAssetName)
                }
                return .onDevice
            }
            return .cloud(provider: facts.speechRecognitionProviderName)
        case .aiResponse:
            if let live = facts.liveProviderName { return .cloud(provider: live) }
            return modelDestination(facts)
        case .spokenVoice:
            // In a live session the provider speaks: the audio comes back from the same socket the
            // question went out on, and the configured voice engine is not in that path.
            if let live = facts.liveProviderName { return .cloud(provider: live) }
            switch facts.voiceEngine {
            case .system:
                return .onDevice
            case .kokoro:
                // No `unavailable` case here: `TTSEngineSelector` has already fallen back to the
                // iOS voice when the model is absent, so this row reports what will actually
                // speak. The missing download is named in the offline line instead, where it is
                // advice rather than a contradiction of the voice the wearer is about to hear.
                return .onDevice
            case .elevenLabs:
                return .cloud(provider: "ElevenLabs")
            }
        case .remoteTools:
            guard facts.remoteToolsEnabled else { return .disabled }
            if let host = facts.remoteToolHost { return .customEndpoint(host: host) }
            return .cloud(provider: facts.remoteToolProviderName)
        }
    }

    private static func modelDestination(_ facts: ProcessingFacts) -> ProcessingDestination {
        switch facts.modelKind {
        case .onDevice:
            guard facts.modelAssetPresent else {
                return .unavailable(missingAsset: facts.modelAssetName)
            }
            return .onDevice
        case .cloud:
            return .cloud(provider: facts.modelProviderName)
        case .customEndpoint:
            guard let host = facts.modelHost else { return .cloud(provider: facts.modelProviderName) }
            return .customEndpoint(host: host)
        }
    }

    // MARK: - Copy

    private static func shortValue(_ destination: ProcessingDestination) -> String {
        switch destination {
        case .onDevice: return "On this device"
        case .cloud(let provider): return provider
        case .customEndpoint(let host): return host
        case .disabled: return "Off"
        case .unavailable: return "Not downloaded"
        }
    }

    /// What has to be downloaded before this setup could work with no network — named **before**
    /// any offline promise, which is the whole point of the line.
    ///
    /// Two sources, because there are two ways to be short of an asset. A row configured to run on
    /// this device whose files are missing is already broken and says so in its own line. A row
    /// that currently goes to the cloud is not broken — but if the on-device alternative is not
    /// installed either, there is nothing to fall back to, and a wearer planning to go offline
    /// needs to know that before they are somewhere with no signal.
    private static func offlineSentence(rows: [ProcessingRow], facts: ProcessingFacts) -> String? {
        var missing: [String] = rows.compactMap { row in
            if case .unavailable(let asset) = row.destination { return asset }
            return nil
        }
        for row in rows where row.destination.leavesDevice {
            switch row.kind {
            case .transcription where !facts.speechRecognitionAssetPresent:
                missing.append(facts.speechRecognitionAssetName)
            case .spokenVoice where !facts.kokoroInstalled:
                missing.append(facts.kokoroAssetName)
            default:
                break
            }
        }
        let unique = missing.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        guard !unique.isEmpty else { return nil }
        return "Before you can use this offline, download \(list(unique))."
    }

    /// The verdict, in a sentence.
    ///
    /// The mixed case reads the rows rather than only their names, because "leaves this device"
    /// and "is set to run here and isn't downloaded" are both reasons a row is not on-device and
    /// only one of them is an egress. Collapsing them would put a row that sends nothing into a
    /// sentence about sending.
    static func verdictSentence(_ verdict: ProcessingVerdict, rows: [ProcessingRow]) -> String {
        switch verdict {
        case .fullyOnDevice:
            // The vacuous case is real: Medical Compliance's local-only rule can switch off every
            // row that would leave the device, and "everything is handled on this device" would be
            // a strange thing to say about a setup that is handling nothing.
            guard rows.contains(where: { $0.destination == .onDevice }) else {
                return "Nothing that would leave this device is switched on."
            }
            return "Everything that's switched on is handled on this device."
        case .cloud:
            return "Everything that's switched on is handled in the cloud."
        case .mixed:
            let leaving = rows.filter { $0.destination.leavesDevice }.map(\.kind.title)
            let pending = rows.compactMap { row -> String? in
                if case .unavailable = row.destination { return row.kind.title }
                return nil
            }
            // Named as mixed, in the first four words, because this is the verdict a wearer is
            // most likely to be told wrongly.
            var sentence = "This is a mixed setup."
            if !leaving.isEmpty {
                sentence += " \(list(leaving)) \(leaving.count == 1 ? "leaves" : "leave") this device."
            }
            if !pending.isEmpty {
                sentence += " \(list(pending)) \(pending.count == 1 ? "is" : "are") set to run here, "
                    + "but the files needed for that aren't downloaded."
            }
            let onDevice = rows.filter { $0.destination == .onDevice }.map(\.kind.title)
            if !onDevice.isEmpty {
                sentence += " \(list(onDevice)) \(onDevice.count == 1 ? "stays" : "stay") on this device."
            }
            return sentence
        }
    }

    private static func list(_ names: [String]) -> String {
        guard !names.isEmpty else { return "" }
        if names.count == 1 { return names[0] }
        return names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
    }

    private static func spokenSummary(rows: [ProcessingRow],
                                      verdict: ProcessingVerdict,
                                      offlineLine: String?) -> String {
        var parts = [verdictSentence(verdict, rows: rows)]
        parts.append(contentsOf: rows.map(\.spokenForm))
        if let offlineLine { parts.append(offlineLine) }
        parts.append(evidenceCaveat)
        return parts.joined(separator: " ")
    }
}
