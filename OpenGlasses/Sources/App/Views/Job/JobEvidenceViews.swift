import AVKit
import PhotosUI
import SwiftUI

/// One evidence thumbnail, loaded off the main thread from the session's own `photos/` directory.
///
/// Files, not a photo library: the session directory is the record, and asking Photos for anything
/// would mean a permission this feature does not need.
struct EvidenceThumbnail: View {
    /// Nil for a clip whose poster frame is missing — the placeholder is drawn instead, rather
    /// than a video being decoded inside a scrolling list.
    let url: URL?
    var side: CGFloat = 72
    /// The glyph the placeholder shows, and what a clip's overlay draws.
    var placeholderSymbol = "photo"

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.15))
                    .overlay {
                        Image(systemName: placeholderSymbol)
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        // Decorative: every thumbnail sits inside a row whose own label already says what the
        // picture is, when it was taken and whether it is going out. A second announcement of
        // "image" would be noise on top of it.
        .accessibilityHidden(true)
        .task(id: url) { await load() }
    }

    private func load() async {
        guard let target = url else { return }
        let side = side
        let loaded = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let data = try? Data(contentsOf: target), let full = UIImage(data: data) else {
                return nil
            }
            // Downsampled here rather than by the view: a grid of full-resolution stills is the
            // classic way a list scrolls badly and then gets a memory warning.
            let scale = min(1, (side * 3) / max(full.size.width, full.size.height))
            guard scale < 1 else { return full }
            let size = CGSize(width: full.size.width * scale, height: full.size.height * scale)
            return UIGraphicsImageRenderer(size: size).image { _ in
                full.draw(in: CGRect(origin: .zero, size: size))
            }
        }.value
        image = loaded
    }
}

/// The plain statement of what the recipient will see of anyone else who was standing there.
///
/// Not a toggle. The face blur is one app-wide setting with no per-job or per-photo override (owner
/// decision, 2026-09-21), the stored copy is already the filtered one, and a second switch here
/// would imply a choice that does not exist.
struct FaceBlurStatusRow: View {
    let line: String
    let detail: String
    let isOn: Bool
    /// Present on the Job tab, absent inside the modal review — a sheet cannot switch tabs.
    var onOpenSettings: (() -> Void)?

    var body: some View {
        Group {
            if let onOpenSettings {
                Button(action: onOpenSettings) { label }
                    .accessibilityHint("Opens Settings, where the blur is turned on and off.")
            } else {
                label
            }
        }
    }

    private var label: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: isOn ? "eye.slash" : "eye")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(line)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.primary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// One piece of evidence as a tile: the picture, or a clip's poster frame with its length on it
/// and a play affordance (Plan FO P2b).
///
/// The badge and the glyph are both drawn, and the row's own accessibility label says "clip" and
/// the length in words — so what kind of thing this is never depends on seeing the overlay.
struct EvidenceMediaTile: View {
    let item: JobMediaItem
    let previewURL: URL?
    var side: CGFloat = 72
    var dimmed = false
    /// Non-nil only where a clip can actually be played — the tile is a button then, and plain
    /// pixels otherwise.
    var onPlay: (() -> Void)?

    var body: some View {
        let tile = EvidenceThumbnail(url: previewURL, side: side,
                                     placeholderSymbol: item.kind == .clip ? "video" : "photo")
            .overlay(alignment: .bottomLeading) { durationBadge }
            .overlay { playGlyph }
            .opacity(dimmed ? 0.55 : 1)
        if item.kind == .clip, let onPlay {
            Button(action: onPlay) { tile }
                .buttonStyle(.plain)
                .frame(minWidth: OGMetrics.minTouchTarget, minHeight: OGMetrics.minTouchTarget)
                .accessibilityLabel("Play this clip")
                .accessibilityHint("Plays it on the phone. Nothing is sent.")
        } else {
            tile
        }
    }

    @ViewBuilder
    private var durationBadge: some View {
        if let badge = item.durationBadge {
            Text(badge)
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                // Opaque fill behind an opaque label: a timecode over a photograph has no
                // background it can rely on, so it brings its own.
                .background(Capsule().fill(Color.black.opacity(0.7)))
                .foregroundStyle(Color.white)
                .padding(4)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var playGlyph: some View {
        if item.kind == .clip {
            Image(systemName: "play.circle.fill")
                .font(.title2)
                .foregroundStyle(Color.white, Color.black.opacity(0.45))
                .accessibilityHidden(true)
        }
    }
}

/// A clip played on the phone, and nowhere else.
struct ClipPlayerSheet: View {
    let url: URL
    let caption: String?
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                VideoPlayer(player: AVPlayer(url: url))
                    .frame(maxWidth: .infinity, minHeight: 240)
                    .accessibilityLabel(caption ?? "Job clip")
                if let caption, !caption.isEmpty {
                    Text(caption)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal)
                }
                Spacer(minLength: 0)
            }
            .navigationTitle("Clip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onDone() }
                }
            }
        }
    }
}

/// The job's photos and clips on the page of an open or a finished job.
///
/// On an open job it also adds them: the phone's own camera, its library, and — through the
/// glasses — a length-capped clip recorded off the blurred frame relay (Plan FO P2b). Both photo
/// routes go through `JobPhotoEvidenceService`, which filters before it stores, because those
/// pixels never pass `CameraService` and nothing else would have.
struct JobPhotosSection: View {
    let review: EvidenceReviewModel
    let selection: EvidenceSelection
    /// Nil on a finished job: evidence is added while the job is open, and not after.
    var onAdd: ((JobMediaItem.Origin, Data) -> Void)?
    var onOpenSettings: (() -> Void)?
    /// The clip recorder, when this is an open job. Nil on a finished one.
    var clips: JobClipRecorder?
    var onRecordClip: (() -> Void)?
    var onStopClip: (() -> Void)?
    let onShare: () -> Void

    @State private var pickerItem: PhotosPickerItem?
    @State private var takingPhoto = false
    @State private var playing: JobMediaItem?

    var body: some View {
        Section {
            if review.isEmpty {
                Text("Nothing recorded on this job yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(review.groups) { group in
                            ForEach(group.rows) { row in
                                thumbnail(row)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                Text(review.summary(for: selection))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            FaceBlurStatusRow(line: review.faceBlurLine, detail: review.faceBlurDetail,
                              isOn: review.faceBlurOn, onOpenSettings: onOpenSettings)

            if let onAdd {
                if let clips, let onRecordClip, let onStopClip {
                    ClipRecordRow(clips: clips, onRecord: onRecordClip, onStop: onStopClip)
                }
                Button("Take a photo for the job") { takingPhoto = true }
                    .frame(maxWidth: .infinity, minHeight: OGMetrics.minTouchTarget, alignment: .leading)
                    .accessibilityHint("Uses the phone's camera. The picture is filed against this job, not sent anywhere.")
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Text("Add from the photo library")
                        .frame(maxWidth: .infinity, minHeight: OGMetrics.minTouchTarget,
                               alignment: .leading)
                }
                .onChange(of: pickerItem) { _, item in
                    guard let item else { return }
                    Task {
                        if let data = try? await item.loadTransferable(type: Data.self) {
                            onAdd(.photoLibrary, data)
                        }
                        pickerItem = nil
                    }
                }
                .sheet(isPresented: $takingPhoto) {
                    PhoneCameraView(prompt: "Photo for the job") { data in
                        takingPhoto = false
                        onAdd(.phoneCamera, data)
                    } onCancel: {
                        takingPhoto = false
                    }
                }
            }

            if !review.isEmpty {
                // The button says what it actually hands out. A job with a clip on it shares a
                // video too, and a label promising only photographs would be describing a
                // different action. Spelled as a branch rather than a ternary so both literals
                // reach the string catalog.
                Group {
                    if review.hasClips {
                        Button("Share full-size photos and clips", action: onShare)
                    } else {
                        Button("Share full-size photos", action: onShare)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: OGMetrics.minTouchTarget, alignment: .leading)
                .disabled(selection.includedCount == 0)
                .accessibilityHint("Opens the share sheet with everything selected, at full size. Nothing is sent until you choose where.")
            }
        } header: {
            Text(review.isEmpty ? review.sectionTitle : "\(review.sectionTitle) — \(review.count)")
        } footer: {
            if !review.isEmpty {
                Text(review.hasClips
                     ? "The report carries smaller copies of the pictures and names each clip. Share sends the originals, exactly as they were stored."
                     : "The report carries smaller copies. Share sends the originals, exactly as they were stored.")
            }
        }
        .sheet(item: $playing) { item in
            ClipPlayerSheet(url: review.url(for: item.id), caption: item.caption) {
                playing = nil
            }
        }
    }

    private func thumbnail(_ row: EvidenceReviewModel.Row) -> some View {
        let entry = selection.entry(for: row.item.id)
        let included = entry?.included ?? false
        return VStack(spacing: 3) {
            EvidenceMediaTile(item: row.item, previewURL: review.previewURL(for: row.item),
                              dimmed: !included,
                              onPlay: { playing = row.item })
                .overlay(alignment: .topTrailing) {
                    if included {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.white, Color.accentColor)
                            .padding(3)
                    }
                }
            if let role = entry?.role {
                Text(role.label).font(.caption2).foregroundStyle(.secondary)
            } else if row.item.filterWasOn {
                Image(systemName: "eye.slash")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(row.spoken(included: included, role: entry?.role))
    }
}

/// The record button, and the countdown while a clip runs (Plan FO P2b).
///
/// The countdown is the point: a clip is capped, and a technician who cannot see how long is left
/// either stops too early or is surprised when it stops itself. It is stated in words for
/// VoiceOver as well, and updates once a second — the granularity the cap is measured in.
struct ClipRecordRow: View {
    @ObservedObject var clips: JobClipRecorder
    let onRecord: () -> Void
    let onStop: () -> Void

    var body: some View {
        if clips.isRecording {
            Button(role: .destructive, action: onStop) {
                HStack {
                    Label("Stop the clip", systemImage: "stop.circle")
                    Spacer(minLength: 8)
                    Text(clips.countdownLabel)
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(Color.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: OGMetrics.minTouchTarget, alignment: .leading)
            }
            .accessibilityLabel("Stop the clip")
            .accessibilityValue("\(Int(clips.remainingSeconds.rounded())) seconds left of the limit")
        } else {
            Button(action: onRecord) {
                Text("Record a clip")
                    .frame(maxWidth: .infinity, minHeight: OGMetrics.minTouchTarget,
                           alignment: .leading)
            }
            .accessibilityHint("Records up to \(Int(JobClipRecorder.defaultCapSeconds.rounded())) seconds from the glasses camera, filed against this job. It has no sound.")
        }
    }
}
