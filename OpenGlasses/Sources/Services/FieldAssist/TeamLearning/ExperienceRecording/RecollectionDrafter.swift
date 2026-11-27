import Foundation

// MARK: - The model call

/// The one structured extraction behind a drafted case (Plan IM P2). A protocol so the drafting
/// pass is exercised in full against a stub, with no network.
@MainActor
protocol RecollectionDraftModel: AnyObject {
    /// The model's JSON object for one segment, forced through `schema`, or nil when no answer came.
    func extract(system: String, transcript: String, schema: [String: Any]) async -> Data?
}

/// The production model: the app's own stateless structured completion (`LLMService.completeStructured`,
/// Plan AD's path: forced tool use or JSON mode on the cloud providers, prompted JSON on device) for
/// whichever provider the reviewer's device has configured — the organisation's own credentials
/// (decision 1). It never touches the conversation history.
@MainActor
final class LLMRecollectionDraftModel: RecollectionDraftModel {
    private weak var llm: LLMService?

    init(llm: LLMService?) {
        self.llm = llm
    }

    func extract(system: String, transcript: String, schema: [String: Any]) async -> Data? {
        guard let llm,
              let object = await llm.completeStructured(systemPrompt: system, userText: transcript,
                                                         jsonSchema: schema, toolName: RecollectionDraftRules.toolName,
                                                         maxTokens: 2048) else { return nil }
        return try? JSONSerialization.data(withJSONObject: object)
    }
}

// MARK: - The drafting pass

/// What a recording drafted to: the learning drafts and site notes, in segment order, and the
/// segments whose answers were refused.
struct RecollectionDrafts: Equatable, Sendable {

    struct SegmentRefusal: Equatable, Sendable {
        enum Reason: Equatable, Sendable {
            /// The model gave no answer.
            case noAnswer
            /// The answer broke the rules; nothing from it is drafted.
            case refused(RecollectionDraftValidator.Refusal)
        }
        let segment: RecollectionDraft.Span
        let reason: Reason
    }

    var segments: [RecollectionSegmenter.Segment] = []
    var drafts: [RecollectionDraft] = []
    var siteNotes: [RecollectionSiteNote] = []
    var refused: [SegmentRefusal] = []
}

/// Turns an experience recording into drafted `recollection` candidates for a reviewer (Plan IM P2).
///
/// **Where it runs** (decision 1): only on a device the organisation marked as a reviewer's
/// (`Config.teamLearningReviewerDevice`), on that device's own provider, and never under Medical
/// Compliance, which withholds team learnings altogether. The technician's phone only records.
///
/// **What it does:** the pure segmenter cuts the transcript into cases (`RecollectionSegmenter`);
/// each case is one schema-forced extraction (`RecollectionDraftRules.jsonSchema`); every answer is
/// held to the rules (`RecollectionDraftValidator`) before anything is kept. A refused answer drafts
/// nothing for its case and is reported; the other cases are drafted as usual.
///
/// It drafts into values and stores nothing: filing the drafts, moving the recording to `drafted`
/// and the review queue are P3's.
@MainActor
final class RecollectionDrafter {

    struct Context: Equatable, Sendable {
        var isReviewerDevice: Bool
        var medicalComplianceMode: Bool
    }

    enum Refusal: Error, Equatable, Sendable {
        case notReviewerDevice
        case medicalCompliance
        case emptyTranscript

        var message: String {
            switch self {
            case .notReviewerDevice:
                return String(localized: "Experience recordings are drafted on the reviewer's device, not this one.")
            case .medicalCompliance:
                return String(localized: "Experience recordings aren't drafted while Medical Compliance is on.")
            case .emptyTranscript:
                return String(localized: "This recording has no words to draft from.")
            }
        }
    }

    private let model: RecollectionDraftModel
    var context: () -> Context = {
        Context(isReviewerDevice: Config.teamLearningReviewerDevice, medicalComplianceMode: Config.hipaaMode)
    }

    init(model: RecollectionDraftModel) {
        self.model = model
    }

    func draft(_ recording: ExperienceRecording,
               vault: RecollectionDraftValidator.Vault) async -> Result<RecollectionDrafts, Refusal> {
        let context = context()
        guard !context.medicalComplianceMode else { return .failure(.medicalCompliance) }
        guard context.isReviewerDevice else { return .failure(.notReviewerDevice) }
        let segments = RecollectionSegmenter.segments(in: recording.transcript, index: vault.index)
        guard !segments.isEmpty else { return .failure(.emptyTranscript) }

        let transcript = Array(recording.transcript.unicodeScalars)
        var result = RecollectionDrafts(segments: segments)
        for segment in segments {
            let request = RecollectionDraftRules.userText(segment: segment.text, equipmentTypes: vault.equipmentTypes)
            guard let answer = await model.extract(system: RecollectionDraftRules.systemPrompt, transcript: request,
                                                   schema: RecollectionDraftRules.jsonSchema) else {
                result.refused.append(.init(segment: segment.span, reason: .noAnswer))
                continue
            }
            switch RecollectionDraftValidator.validate(answer: answer, segment: segment.span, transcript: transcript,
                                                       duration: recording.duration, recordingID: recording.id,
                                                       vault: vault) {
            case .failure(let refusal):
                result.refused.append(.init(segment: segment.span, reason: .refused(refusal)))
            case .success(let outcome):
                if let draft = outcome.draft { result.drafts.append(draft) }
                if let note = outcome.siteNote { result.siteNotes.append(note) }
            }
        }
        return .success(result)
    }
}

extension RecollectionDraftValidator.Vault {
    /// An installed vault as the drafting pass needs it: its model index, its closed list of
    /// equipment types and its core files. Nil when this device does not have it.
    @MainActor
    static func installed(id: String) -> RecollectionDraftValidator.Vault? {
        guard let target = LearningReviewService.installedVaults().first(where: { $0.id == id }) else { return nil }
        return RecollectionDraftValidator.Vault(index: target.modelIndex, equipmentTypes: target.equipmentTypes ?? [],
                                                coreFiles: VaultRegistry.shared.store(forId: id)?.readAll() ?? [])
    }
}
