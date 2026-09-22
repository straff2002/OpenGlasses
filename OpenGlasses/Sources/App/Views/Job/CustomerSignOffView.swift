import PencilKit
import SwiftUI

/// The customer's signature, taken on the technician's phone (Plan FO P2c).
///
/// Two screens live here. `JobSignOffStepView` is the **technician's** step in the close flow: it
/// shows exactly what the customer would be asked to agree to, and offers three honest answers —
/// hand the phone over, record that the customer declined, or close with no signature at all.
/// `CustomerSignOffSheet` is the **customer's** screen: full width, nothing else on it, no way out
/// by accident.
///
/// What is being recorded is an **acceptance**, not an e-signature in any legal sense, and the copy
/// says so rather than implying more.

// MARK: - The technician's step

struct JobSignOffStepView: View {
    /// The customer summary, exactly as the hand-over sheet will show it.
    let summaryLines: [String]
    let jobNumber: String
    let dateLine: String
    /// The name the customer-facing sheet is headed with. Empty until an organisation profile
    /// sets one, and then the line is simply absent.
    let organisationName: String
    /// Whether the organisation asks for sign-off on every job.
    let required: Bool
    /// The customer's acceptance, with the picture and the strokes when they drew one.
    let onSignOff: (CustomerSignOff, Data?, Data?) -> Void
    /// Record that the customer declined, with the reason given.
    let onDeclined: (String) -> Void
    /// Finish without a signature. Absent when the organisation requires one.
    let onSkip: () -> Void
    /// The sheet was put in front of a customer and closed without an answer.
    let onCancelledHandOver: () -> Void
    let onCancel: () -> Void

    @State private var declining = false
    @State private var declinedReason = ""
    /// True while the phone is in the customer's hands. Held **here**, so the full-screen cover is
    /// presented from this sheet rather than from the page underneath it: two presentations from
    /// one view is how a cover ends up fighting the sheet that raised it.
    @State private var handingOver = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(summaryLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } header: {
                    Text("What the customer will see")
                } footer: {
                    Text("Work done, parts used and time on the job. Your own notes, what the assistant suggested and the pictures' captions stay off this screen.")
                }

                Section {
                    choice("Hand to customer") { handingOver = true }
                        .accessibilityHint("Shows a full-screen page for the customer to read and sign. You can stop it at any time.")

                    if declining {
                        TextField(text: $declinedReason) {
                            Text("Why the customer wouldn't sign")
                        }
                        .font(.callout)
                        .frame(maxWidth: .infinity, minHeight: OGMetrics.minTouchTarget)
                        .accessibilityLabel("Why the customer wouldn't sign")

                        Button("Record the decline") { onDeclined(declinedReason) }
                            .frame(maxWidth: .infinity, minHeight: OGMetrics.minTouchTarget,
                                   alignment: .leading)
                            .disabled(required && declinedReason.trimmingCharacters(
                                in: .whitespacesAndNewlines).isEmpty)
                    } else {
                        choice("The customer declined to sign") { declining = true }
                            .accessibilityHint("Records that you asked and the customer said no.")
                    }

                    if !required {
                        choice("Close without a signature", action: onSkip)
                            .accessibilityHint("Finishes the job. The record will say the customer did not sign.")
                    }
                } header: {
                    Text("Customer sign-off")
                } footer: {
                    Text(required
                         ? SignOffPolicy.blockedReason
                         : "Sign-off is optional. If you skip it, the record says the customer did not sign, and you can still ask on this job's page until the report has been sent.")
                }
            }
            .ogFormStyle()
            .navigationTitle("Customer sign-off")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Keep working") { onCancel() }
                }
            }
            .fullScreenCover(isPresented: $handingOver) {
                CustomerSignOffSheet(
                    organisationName: organisationName,
                    jobNumber: jobNumber,
                    dateLine: dateLine,
                    summaryLines: summaryLines,
                    onDone: { name, comment, png, strokes in
                        handingOver = false
                        onSignOff(CustomerSignOff(customerName: name, comment: comment,
                                                  method: png == nil ? .typed : .drawn,
                                                  summaryLines: summaryLines),
                                  png, strokes)
                    },
                    onCancel: {
                        handingOver = false
                        onCancelledHandOver()
                    })
            }
        }
    }

    private func choice(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .frame(maxWidth: .infinity, minHeight: OGMetrics.minTouchTarget, alignment: .leading)
        }
    }
}

// MARK: - The customer's screen

/// What the customer is handed. Full screen, one job, one summary, one signature.
///
/// The sheet cannot be swiped away and leaving it takes the technician's confirmation, because the
/// phone is in somebody else's hands: an accidental swipe would drop them into the technician's
/// conversation history, which is not theirs to see.
struct CustomerSignOffSheet: View {
    let organisationName: String
    let jobNumber: String
    let dateLine: String
    let summaryLines: [String]
    /// Everything the customer gave: their name, their optional line, the drawing and its strokes.
    let onDone: (_ name: String, _ comment: String, _ png: Data?, _ strokes: Data?) -> Void
    let onCancel: () -> Void

    @Environment(\.appAccent) private var accent
    @State private var name = ""
    @State private var comment = ""
    @State private var drawing = PKDrawing()
    @State private var confirmingCancel = false

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hasDrawing: Bool { !drawing.strokes.isEmpty }
    /// "Done" once something has been drawn, "Confirm" for a customer who types their name
    /// instead. Two words for two different records, so nobody is told they signed when they did
    /// not.
    private var finishTitle: LocalizedStringKey { hasDrawing ? "Done" : "Confirm" }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    summary
                    fields
                    signature
                    Text("Your name and signature are kept with this job's record on this phone and printed on the work order. This is a record of what you agreed to, not a legal e-signature.")
                        .font(.footnote)
                        .foregroundStyle(Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Technician: Guided Access (Settings → Accessibility) locks the phone to this page while the customer signs.")
                        .font(.footnote)
                        .foregroundStyle(Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding()
            }
            // Two words. "Please check and sign" truncated to "Please ch…" between the two
            // toolbar buttons, which is worse than useless on the one screen a stranger reads
            // cold; the sentence it was trying to say is now in the page, where it fits.
            .navigationTitle("Please sign")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { confirmingCancel = true }
                        .accessibilityLabel("Cancel sign-off")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(finishTitle) {
                        onDone(trimmedName, comment.trimmingCharacters(in: .whitespacesAndNewlines),
                               hasDrawing ? signaturePNG() : nil,
                               hasDrawing ? drawing.dataRepresentation() : nil)
                    }
                    .disabled(trimmedName.isEmpty)
                    .accessibilityHint(hasDrawing
                                       ? "Records your signature against this job."
                                       : "Records your name against this job, with no signature.")
                }
            }
            .confirmationDialog("Cancel sign-off?", isPresented: $confirmingCancel,
                                titleVisibility: .visible) {
                Button("Cancel sign-off", role: .destructive) { onCancel() }
                Button("Keep signing", role: .cancel) {}
            } message: {
                Text("Nothing is recorded, and the job stays open.")
            }
        }
        .interactiveDismissDisabled(true)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !organisationName.isEmpty {
                Text(organisationName)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("\(jobNumber) · \(dateLine)")
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Please check what was done, then add your name and sign.")
                .font(.callout)
                .foregroundStyle(Color.primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
        .accessibilityElement(children: .combine)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What was done")
                .font(.headline)
            ForEach(Array(summaryLines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.callout)
                    .foregroundStyle(Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Your name").font(.headline)
                TextField(text: $name) { Text("Name") }
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.name)
                    .frame(minHeight: OGMetrics.minTouchTarget)
                    .accessibilityLabel("Your name")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Anything you'd like to add").font(.headline)
                TextField(text: $comment) { Text("Optional") }
                    .textFieldStyle(.roundedBorder)
                    .frame(minHeight: OGMetrics.minTouchTarget)
                    .accessibilityLabel("Anything you'd like to add, optional")
            }
        }
    }

    private var signature: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Signature").font(.headline)
                Spacer(minLength: 8)
                Button("Clear") { drawing = PKDrawing() }
                    .font(.callout)
                    .foregroundStyle(accent)
                    .frame(minWidth: OGMetrics.minTouchTarget,
                           minHeight: OGMetrics.minTouchTarget, alignment: .trailing)
                    .disabled(!hasDrawing)
                    .accessibilityLabel("Clear the signature")
            }
            SignatureCanvas(drawing: $drawing)
                .frame(height: 180)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
                // Full-strength secondary, not a faded one. The border is the only thing that says
                // where to sign, and `Color.secondary.opacity(0.6)` on this fill measures 1.92:1 —
                // under the 3:1 floor a non-text indicator has to clear. See
                // `JobSignOffContrastTests`, which asserts both numbers so a revert fails there.
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.secondary, lineWidth: 1.5))
                .accessibilityLabel("Signature pad")
                .accessibilityValue(hasDrawing ? "Signed" : "Empty")
                .accessibilityHint("Sign here with a finger or a pencil. If you'd rather not, type your name above and tap Confirm.")
            Text(hasDrawing ? "Signed." : "Sign above, or type your name and tap Confirm.")
                .font(.footnote)
                .foregroundStyle(Color.secondary)
        }
    }

    /// The drawing, flattened onto white.
    ///
    /// Drawn against an explicit white ground rather than left transparent: the picture is printed
    /// into a work order and shown on a page that may be in either appearance, and a transparent
    /// PNG of black ink disappears on the second of those.
    private func signaturePNG() -> Data {
        let bounds = drawing.bounds.isEmpty
            ? CGRect(x: 0, y: 0, width: 600, height: 200)
            : drawing.bounds.insetBy(dx: -12, dy: -12)
        let image = drawing.image(from: bounds, scale: 2)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: image.size, format: format).pngData { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: image.size))
            image.draw(at: .zero)
        }
    }
}

/// The signature pad itself.
///
/// `PKCanvasView` pinned to the light interface style and an explicit black ink, on purpose:
/// PencilKit's default ink adapts to the appearance, so a signature drawn in dark mode renders
/// white — invisible on the white page it is printed onto. The colour of somebody's signature is
/// not a theming decision.
struct SignatureCanvas: UIViewRepresentable {
    @Binding var drawing: PKDrawing

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.drawingPolicy = .anyInput          // a finger is the normal case, not a Pencil
        canvas.tool = PKInkingTool(.pen, color: .black, width: 4)
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.overrideUserInterfaceStyle = .light
        canvas.delegate = context.coordinator
        canvas.drawing = drawing
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        // Only when they differ: assigning on every pass would fight the stroke being drawn.
        if canvas.drawing != drawing { canvas.drawing = drawing }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        private let parent: SignatureCanvas

        init(_ parent: SignatureCanvas) { self.parent = parent }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            parent.drawing = canvasView.drawing
        }
    }
}

// MARK: - What a finished job shows

/// The acceptance on a past job's page: what was agreed to, who agreed, when, and how.
struct CustomerAcceptanceSection: View {
    let signOff: CustomerSignOff
    /// The signature picture, when one was drawn.
    let signatureURL: URL?

    var body: some View {
        Section {
            ForEach(Array(signOff.summaryLines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(signOff.method.label)
                    .font(.subheadline.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                if let reason = signOff.declinedReason, !reason.isEmpty {
                    Text("Reason given: \(reason)")
                        .font(.callout)
                        .foregroundStyle(Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let comment = signOff.comment, !comment.isEmpty {
                    Text("Customer's note: \(comment)")
                        .font(.callout)
                        .foregroundStyle(Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(signOff.attributionLine())
                    .font(.callout)
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .combine)

            if let signatureURL, let image = UIImage(contentsOfFile: signatureURL.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 90)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // The picture is somebody's handwriting, which reads as nothing to a screen
                    // reader — the line above already says who signed and when.
                    .accessibilityLabel("The customer's signature")
            }
        } header: {
            Text(CustomerSignOff.blockTitle)
        } footer: {
            Text(CustomerSignOff.disclaimer)
        }
    }
}
