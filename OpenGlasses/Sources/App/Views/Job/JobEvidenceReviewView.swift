import SwiftUI

/// Choosing what the customer sees, at the moment the job is closed (Plan FO P2a).
///
/// The step sits in front of the close confirmation, because closing is what makes the record
/// final — and because `JobTabModel.closeJob` takes the work record before the session ends, which
/// is the only point at which the selection can still be written onto it.
///
/// **Skipping is one tap**, and it is not the same as excluding everything: a skipped review sends
/// the text-only record the app has always sent. Fault/Fix marking is offered and never asked for.
/// Everything here can also be said out loud — see `EvidenceReviewVoiceState`, which the Job tab
/// drives with the same selection value this screen edits.
struct JobEvidenceReviewView: View {
    let review: EvidenceReviewModel
    @Binding var selection: EvidenceSelection
    /// Start the spoken walk: each picture read out with its caption, answered yes or no.
    let onReadOutLoud: () -> Void
    /// Close the job, sending the pictures chosen here.
    let onClose: () -> Void
    /// Close the job with the text-only record.
    let onSkip: () -> Void
    let onShare: () -> Void
    let onCancel: () -> Void

    @Environment(\.appAccent) private var accent
    @State private var editingCaption: String?

    var body: some View {
        NavigationStack {
            List {
                blurSection
                ForEach(review.groups) { group in
                    section(group)
                }
                actionsSection
            }
            .ogFormStyle()
            .navigationTitle("Photos for the report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Keep working") { onCancel() }
                }
            }
        }
    }

    // MARK: - What the recipient will see

    private var blurSection: some View {
        Section {
            FaceBlurStatusRow(line: review.faceBlurLine, detail: review.faceBlurDetail,
                              isOn: review.faceBlurOn)
            Text(review.summary(for: selection))
                .font(.subheadline.weight(.medium))
        } header: {
            Text("Before it goes out")
        }
    }

    // MARK: - The grid, by task

    private func section(_ group: EvidenceReviewModel.Group) -> some View {
        Section {
            ForEach(group.rows) { row in
                item(row)
            }
        } header: {
            Text(group.title)
        }
    }

    @ViewBuilder
    private func item(_ row: EvidenceReviewModel.Row) -> some View {
        let entry = selection.entry(for: row.item.id)
        let included = entry?.included ?? false
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                EvidenceThumbnail(url: review.url(for: row.item.id), side: 64)
                    .opacity(included ? 1 : 0.55)
                // When and how it was taken leads this line — **not** the caption, which lives in
                // the editable row below and nowhere else. Printing it in both places made a
                // three-photo job read like a six-photo one and left the technician with two
                // things that looked like the caption when only one of them was editable.
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(row.item.timeLabel) · \(row.item.origin.shortLabel)")
                        .font(.subheadline)
                        .foregroundStyle(Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if row.item.filterWasOn {
                        Text(EvidenceReviewModel.blurredItemLabel)
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                    }
                }
                Spacer(minLength: 4)
                Button {
                    selection.setIncluded(!included, for: row.item.id)
                } label: {
                    Image(systemName: included ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(included ? accent : Color.secondary)
                        .frame(minWidth: OGMetrics.minTouchTarget,
                               minHeight: OGMetrics.minTouchTarget)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(included ? "Included" : "Not included")
                .accessibilityHint("Double-tap to change whether this picture goes with the report.")
            }

            HStack(spacing: 8) {
                roleButton(.fault, for: row.item.id, current: entry?.role)
                roleButton(.fix, for: row.item.id, current: entry?.role)
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(row.spoken(included: included, role: entry?.role))

        // The caption editor is **its own list row**, the way the job-number field on the empty
        // state is. Nested beside the thumbnail it got only its text's height — about 20pt, under
        // the 44pt pointer target — because nothing there stretches it; as a row of its own the
        // list gives it the standard height and the full width. That matters more here than in
        // most places: this is edited with gloves on, standing in front of a machine.
        TextField(text: captionBinding(for: row.item.id)) {
            Text("Caption for this picture")
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, minHeight: OGMetrics.minTouchTarget)
        .contentShape(Rectangle())
        .accessibilityLabel("Caption for this picture")
        .accessibilityHint("What this photograph shows. It is printed under the picture in the report.")
    }

    /// One tap marks, a second clears it. Never required: a job with no marks at all prints its
    /// pictures in capture order, which is a perfectly good report.
    private func roleButton(_ role: EvidenceSelection.Role, for itemId: String,
                            current: EvidenceSelection.Role?) -> some View {
        let isOn = current == role
        return Button {
            selection.setRole(role, for: itemId)
        } label: {
            Text(role.label)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(minHeight: OGMetrics.minTouchTarget - 16)
                // Both states carry the primary label: `.secondary` on a `.secondary` capsule
                // measured 3.3:1 in light appearance, under WCAG AA for 12-point text. What
                // separates marked from unmarked is the fill — the accent against a plain grey —
                // and, for anyone not reading colour at all, the accessibility label below, which
                // says "marked" or "not marked" in words.
                .background(Capsule().fill(isOn ? accent.opacity(0.28)
                                                : Color.secondary.opacity(0.18)))
                .foregroundStyle(Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(role.label) — \(isOn ? "marked" : "not marked")")
        .accessibilityHint("Optional. Marks what this picture shows, and groups it in the report.")
    }

    private func captionBinding(for itemId: String) -> Binding<String> {
        Binding(
            get: { selection.entry(for: itemId)?.caption ?? "" },
            set: { selection.setCaption($0, for: itemId) })
    }

    // MARK: - The four things you can do

    private var actionsSection: some View {
        Section {
            choice("Include all") { selection.includeAll() }
                .accessibilityHint("Ticks every picture on this job.")

            choice("Read them out one at a time", action: onReadOutLoud)
                .accessibilityHint("Reads each picture's caption and waits for yes or no. You can also just say \u{201C}include all\u{201D} or \u{201C}skip photos\u{201D}.")

            choice("Share full-size photos", action: onShare)
                .disabled(selection.includedCount == 0)
                .accessibilityHint("Opens the share sheet with the selected pictures at full size.")

            Button("Close job and send these", role: .destructive, action: onClose)
                .frame(maxWidth: .infinity, minHeight: OGMetrics.minTouchTarget, alignment: .leading)

            choice("Skip photos and close the job", action: onSkip)
                .accessibilityHint("Closes the job and sends the written record on its own, with no pictures.")
        } header: {
            Text("Finish the job")
        } footer: {
            Text("Time stops, the record is finished, and the job's conversation is closed with it. You can still send the report afterwards, and it will carry exactly these pictures.")
        }
    }

    private func choice(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .frame(maxWidth: .infinity, minHeight: OGMetrics.minTouchTarget, alignment: .leading)
        }
    }
}
