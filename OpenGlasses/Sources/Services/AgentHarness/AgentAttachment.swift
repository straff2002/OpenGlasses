import Foundation

/// Plan CN — a still handed to a delegated remote-agent run.
///
/// `AgentHarness.start` took two strings, so what reached a remote agent was the on-device model's
/// one-sentence paraphrase of the scene. Dense visual content is exactly where a paraphrase loses
/// most: digits transpose, part numbers normalise into plausible neighbours, small print vanishes —
/// and the agent has no route back to the camera to check.
struct AgentTaskAttachment: Equatable {

    /// Where the frame came from. Not decoration: a pin taken four minutes ago is a different
    /// claim about the world than a live frame, and the receiving agent is told which it has.
    enum Source: Equatable {
        case pinned(at: Date)
        case live
    }

    let jpeg: Data
    let source: Source
    let pixelSize: CGSize

    var byteCount: Int { jpeg.count }
}

/// When a dispatch carries a frame.
///
/// Every rule here exists because the alternative is worse in a specific way, so the table is the
/// documentation. Pure and headless — no UIKit, no camera, no network.
enum AgentAttachmentPolicy {

    enum Decision: Equatable {
        case attach(AgentTaskAttachment.Source)
        case skip(Reason)
    }

    enum Reason: String, Equatable, CaseIterable {
        /// The distinct opt-in is off. The default.
        case disabled
        /// Agent Mode is off, so there is no dispatch to attach to.
        case agentModeOff
        /// HIPAA mode hard-disables outbound frames.
        case hipaaMode
        /// A pin is held but old enough that it no longer describes "now".
        case pinStale
        /// No pin, and the camera isn't running.
        case noFrame
        /// Nothing about the task refers to something visible.
        case notReferential
        /// The frame decoded to something unusable.
        case degenerateFrame
    }

    /// Beyond this a held pin is a forgotten pin, and silently shipping it as the agent's view of
    /// the present is worse than sending nothing.
    static let defaultMaxPinAge: TimeInterval = 120

    /// - Parameters:
    ///   - explicitAttach: the tool's `attach` argument. Overrides the referential matcher in
    ///     **both** directions — the model can see things the matcher cannot, and a wrong guess in
    ///     either direction should be correctable from the call site.
    static func decide(settingEnabled: Bool,
                       agentModeEnabled: Bool,
                       hipaaMode: Bool,
                       pinHeld: Bool,
                       pinAge: TimeInterval?,
                       cameraStreaming: Bool,
                       prompt: String,
                       explicitAttach: Bool? = nil,
                       maxPinAge: TimeInterval = defaultMaxPinAge) -> Decision {
        guard settingEnabled else { return .skip(.disabled) }
        guard agentModeEnabled else { return .skip(.agentModeOff) }
        guard !hipaaMode else { return .skip(.hipaaMode) }

        if explicitAttach == false { return .skip(.notReferential) }

        if pinHeld {
            if let age = pinAge, age >= maxPinAge { return .skip(.pinStale) }
            return .attach(.pinned(at: Date()))
        }

        guard cameraStreaming else { return .skip(.noFrame) }
        if explicitAttach == true { return .attach(.live) }
        return isVisuallyReferential(prompt) ? .attach(.live) : .skip(.notReferential)
    }

    /// Whether a task refers to something the wearer can see.
    ///
    /// Deliberately a *demotable* signal, never authoritative — `explicitAttach` overrides it both
    /// ways. Kept narrow: a false positive ships a frame the agent doesn't need (costly, and a
    /// privacy surface), while a false negative is recoverable by the model asking for the attach.
    static func isVisuallyReferential(_ prompt: String) -> Bool {
        let text = prompt.lowercased()
        let demonstratives = ["this", "that", "these", "those", "here", "in front of me",
                              "i'm looking at", "im looking at", "on screen", "the label",
                              "the sign", "the receipt", "the form", "the serial", "the plate"]
        if demonstratives.contains(where: { text.contains($0) }) { return true }
        let readVerbs = ["read the", "what's on the", "whats on the", "what does the",
                         "transcribe the", "scan the", "look at the"]
        return readVerbs.contains(where: { text.contains($0) })
    }
}

/// The sentence appended to a dispatched prompt when a frame rides along.
///
/// Without it the receiving agent has no way to know whether the image is the current scene or a
/// stock reference, and hedges accordingly — the same lesson as `AsyncDeliveryPhrasing`: the
/// framing around a payload is load-bearing, so it lives in a tested unit rather than being
/// interpolated at the call site.
enum AgentAttachmentPhrasing {

    static func provenance(for source: AgentTaskAttachment.Source, now: Date = Date()) -> String {
        switch source {
        case .live:
            return "Attached is the current view from the wearer's camera, captured just now."
        case .pinned(let pinnedAt):
            let seconds = max(0, Int(now.timeIntervalSince(pinnedAt).rounded()))
            let when = seconds < 5 ? "moments ago" : "\(seconds) seconds ago"
            return "Attached is the view the wearer deliberately froze \(when); "
                 + "it is what they mean by \"this\"."
        }
    }

    /// The dispatched prompt with provenance appended, or the prompt unchanged when nothing rides.
    static func prompt(_ prompt: String, attaching source: AgentTaskAttachment.Source?, now: Date = Date()) -> String {
        guard let source else { return prompt }
        return prompt + "\n\n" + provenance(for: source, now: now)
    }
}
