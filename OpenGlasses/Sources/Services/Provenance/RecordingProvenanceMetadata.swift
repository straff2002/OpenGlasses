import AVFoundation
import Foundation

/// The marker a recording carries when the assistant's synthetic voice may be in it (Plan HQ P1
/// item 3).
///
/// Live speech is played from memory and never written, so there is nothing to mark there. It
/// becomes a file only when "Include Assistant Voice" lets the assistant's phone-speaker voice
/// into a recording; from that moment the file says so, in metadata any player or library reads
/// back: a description and the software that made it. A recording made with the setting off
/// carries no claim — the gate silenced the voice, and a marker would say something untrue.
///
/// The claim is "may contain", and it is decided once, at the start, because `AVAssetWriter` takes
/// its metadata before the first sample. Whether the assistant then actually spoke out of the
/// phone speaker is not known yet; "may" is the truthful word for that.
enum RecordingProvenanceMetadata {
    /// The description a recording carries when the assistant's voice may be in it. A fixed
    /// English sentence: it is a machine-readable marker in the file, not interface copy.
    static let synthesizedSpeechDescription = "May contain synthetic speech from Avenkin AI."

    /// The software identity written beside it.
    static var softwareIdentity: String { "Avenkin \(AIProvenance.currentAppVersion)" }

    /// The metadata items for a recording: the description and the software, or nothing at all
    /// when the assistant's voice cannot be in it.
    ///
    /// Common-key identifiers, so the writer maps them into the container's own key space — iTunes
    /// atoms in both MP4 and M4A — and a reader finds them as `commonKeyDescription` and
    /// `commonKeySoftware` whichever file it opens.
    static func items(assistantVoiceMayBeIncluded: Bool) -> [AVMetadataItem] {
        guard assistantVoiceMayBeIncluded else { return [] }
        return [
            item(.commonIdentifierDescription, synthesizedSpeechDescription),
            item(.commonIdentifierSoftware, softwareIdentity),
        ]
    }

    /// Set the writer's metadata. Must be called before `startWriting()`.
    static func apply(to writer: AVAssetWriter, assistantVoiceMayBeIncluded: Bool) {
        let items = items(assistantVoiceMayBeIncluded: assistantVoiceMayBeIncluded)
        guard !items.isEmpty else { return }
        writer.metadata = items
    }

    private static func item(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value as NSString
        item.extendedLanguageTag = "und"
        return item
    }
}
