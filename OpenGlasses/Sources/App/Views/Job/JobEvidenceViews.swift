import PhotosUI
import SwiftUI

/// One evidence thumbnail, loaded off the main thread from the session's own `photos/` directory.
///
/// Files, not a photo library: the session directory is the record, and asking Photos for anything
/// would mean a permission this feature does not need.
struct EvidenceThumbnail: View {
    let url: URL
    var side: CGFloat = 72

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
                        Image(systemName: "photo")
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
        let target = url
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

/// The job's photos on the page of an open or a finished job.
///
/// On an open job it also adds them: the phone's own camera, and its library. Both go through
/// `JobPhotoEvidenceService`, which filters before it stores — those pixels never pass
/// `CameraService`, so nothing else would have.
struct JobPhotosSection: View {
    let review: EvidenceReviewModel
    let selection: EvidenceSelection
    /// Nil on a finished job: evidence is added while the job is open, and not after.
    var onAdd: ((JobMediaItem.Origin, Data) -> Void)?
    var onOpenSettings: (() -> Void)?
    let onShare: () -> Void

    @State private var pickerItem: PhotosPickerItem?
    @State private var takingPhoto = false

    var body: some View {
        Section {
            if review.isEmpty {
                Text("No photos on this job yet.")
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
                Button("Share full-size photos", action: onShare)
                    .frame(maxWidth: .infinity, minHeight: OGMetrics.minTouchTarget, alignment: .leading)
                    .disabled(selection.includedCount == 0)
                    .accessibilityHint("Opens the share sheet with the selected pictures at full size. Nothing is sent until you choose where.")
            }
        } header: {
            Text(review.isEmpty ? "Photos" : "Photos — \(review.count)")
        } footer: {
            if !review.isEmpty {
                Text("The report carries smaller copies. Share sends the originals, exactly as they were stored.")
            }
        }
    }

    private func thumbnail(_ row: EvidenceReviewModel.Row) -> some View {
        let entry = selection.entry(for: row.item.id)
        let included = entry?.included ?? false
        return VStack(spacing: 3) {
            EvidenceThumbnail(url: review.url(for: row.item.id))
                .overlay(alignment: .topTrailing) {
                    if included {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.white, Color.accentColor)
                            .padding(3)
                    }
                }
                .opacity(included ? 1 : 0.55)
            if let role = entry?.role {
                Text(role.label).font(.caption2).foregroundStyle(.secondary)
            } else if row.item.filterWasOn {
                Image(systemName: "eye.slash")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.spoken(included: included, role: entry?.role))
    }
}
