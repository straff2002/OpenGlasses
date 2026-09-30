import AVKit
import SwiftUI

/// One glasses video filed in the app's Recordings folder (Plan GB P4, decision 4).
struct RecordedVideo: Identifiable, Equatable {
    let url: URL
    let date: Date
    let bytes: Int

    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }

    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]

    /// The videos in `directory`, newest first. Pure apart from the directory read: audio, the
    /// transcript sidecars and anything else in the folder are left out.
    static func list(in directory: URL, fileManager: FileManager = .default) -> [RecordedVideo] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let urls = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles]) else { return [] }
        return urls.compactMap { url -> RecordedVideo? in
            guard videoExtensions.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { return nil }
            return RecordedVideo(url: url, date: values.contentModificationDate ?? .distantPast,
                                 bytes: values.fileSize ?? 0)
        }
        .sorted { $0.date == $1.date ? $0.name > $1.name : $0.date > $1.date }
    }
}

struct RecordedVideoRow: View {
    let video: RecordedVideo

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(video.date.formatted(date: .abbreviated, time: .shortened))
            Text(ByteCountFormatter.string(fromByteCount: Int64(video.bytes), countStyle: .file))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Play one video and hand it to the share sheet.
struct RecordedVideoDetailView: View {
    let video: RecordedVideo
    @State private var player: AVPlayer?

    var body: some View {
        VStack(spacing: 16) {
            VideoPlayer(player: player)
                .aspectRatio(9.0 / 16.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
            ShareLink(item: video.url) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)
            Spacer(minLength: 0)
        }
        .padding()
        .navigationTitle(video.date.formatted(date: .abbreviated, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { player = AVPlayer(url: video.url) }
        .onDisappear { player?.pause() }
    }
}
