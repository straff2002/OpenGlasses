import Foundation
import ShazamKit
import AVFoundation

/// Identifies currently playing music using ShazamKit.
final class ShazamTool: NativeTool, @unchecked Sendable {
    let name = "identify_song"
    let description = "Identify a song currently playing nearby using Shazam. Listens through the device microphone for a few seconds."
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [:] as [String: Any],
        "required": [] as [String]
    ]

    func execute(args: [String: Any]) async throws -> String {
        let session = SHManagedSession()

        defer { session.cancel() }

        let result = await session.result()

        switch result {
        case .match(let match):
            guard let item = match.mediaItems.first else {
                return "I detected a match but couldn't retrieve song details."
            }
            let title = item.title ?? "Unknown Title"
            let artist = item.artist ?? "Unknown Artist"

            var response = "That song is '\(title)' by \(artist)"
            if let album = item.subtitle {
                response += " from the album \(album)"
            }
            response += "."
            return response

        case .noMatch:
            return "I couldn't identify the song. Make sure music is playing clearly."

        case .error(let error, _):
            PrivacyLog.toolRun(.failed, tool: name, error: SafeErrorSummary(error))
            return "I couldn't identify the song right now. Make sure the app has microphone access and music is playing clearly."
        }
    }
}
