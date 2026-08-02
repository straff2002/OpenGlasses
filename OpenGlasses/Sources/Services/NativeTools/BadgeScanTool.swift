import Foundation
import UIKit
import Vision

/// "Scan this badge" — OCR a conference badge into name/title/organization and save the
/// person to the brain store with when/where context (Plan CG). Explicitly user-initiated:
/// this tool only runs on request, never ambiently.
struct BadgeScanTool: NativeTool {
    let name = "scan_badge"
    let description = "Scan a conference badge or name tag the user is looking at. Reads the person's name, title, and organization, and saves them to memory with the time and place. Use when the user says 'scan this badge', 'remember this badge', or 'who is this' while looking at a name tag."

    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [:] as [String: Any],
        "required": [] as [String]
    ]

    let cameraService: CameraService
    let locationService: LocationService
    weak var faceService: FaceRecognitionService?

    init(cameraService: CameraService, locationService: LocationService,
         faceService: FaceRecognitionService? = nil) {
        self.cameraService = cameraService
        self.locationService = locationService
        self.faceService = faceService
    }

    func execute(args: [String: Any]) async throws -> String {
        guard let image = await currentFrame() else {
            return "Could not get a camera frame. Make sure the glasses camera is active and try again."
        }
        guard let cgImage = image.cgImage else {
            return "Could not read the captured frame."
        }

        // OCR and QR run on the same frame, then reconcile: the payload only wins when
        // its name is person-shaped and agrees with what's printed — badge QRs are
        // often the organiser's card or a registration blob, not the wearer.
        let lines = try await recognizeLines(in: cgImage)
        let fields = BadgeFieldParser.parse(lines)
        let payload = scanBarcodePayloads(in: cgImage)
            .compactMap { BadgePayloadParser.parse($0) }
            .first { !$0.isEmpty }
        let reconciliation = BadgeReconciler.reconcile(ocr: fields.isAcceptable ? fields : nil,
                                                       payload: payload)
        let contact = reconciliation.contact

        guard let personName = contact.name else {
            return "I couldn't read a name off that badge. Try getting closer or angling toward the light, then ask again."
        }

        let detail = [contact.title, contact.organization].compactMap { $0 }.joined(separator: ", ")
        let reachable = [contact.phone.map { "phone \($0)" },
                         contact.email.map { "email \($0)" },
                         contact.website.map { "web \($0)" }]
            .compactMap { $0 }.joined(separator: ", ")
        let place = await MainActor.run { locationService.geocodedPlace }
        let met = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short)

        var record = "Met \(personName)"
        if !detail.isEmpty { record += " (\(detail))" }
        if !reachable.isEmpty { record += " — \(reachable)" }
        record += " — badge scanned \(met)"
        if let place, !place.isEmpty { record += " at \(place)" }
        // An untrusted payload still says where the meeting happened (organiser/event
        // card) — keep it as context, clearly separated from the person's own details.
        if let context = reconciliation.context {
            let contextBits = [context.name, context.organization, context.email,
                               context.phone, context.website].compactMap { $0 }
            if !contextBits.isEmpty {
                record += ". Badge QR context (event/organiser card, not \(personName)'s details): "
                    + contextBits.joined(separator: ", ")
            }
        }

        await MainActor.run {
            BrainStore.shared.ingest(text: record, subject: personName, sourceKind: "badge_scan")
        }

        var reply = "Saved \(personName)"
        if !detail.isEmpty { reply += ", \(detail)" }
        if reconciliation.qrTrusted, contact.phone != nil || contact.email != nil {
            reply += ", with contact details from the badge QR"
        }
        reply += "."
        if reconciliation.namesDisagreed {
            reply += " The badge QR named someone else — probably the organiser's card — so I used the printed name and kept the QR as event context."
        } else if reconciliation.context != nil {
            reply += " The badge QR looked like an event card, so I kept it as context."
        }
        if faceService != nil {
            reply += " Say 'remember this person as \(personName)' to link their face too."
        }
        return reply
    }

    // MARK: - Capture + OCR

    private func currentFrame() async -> UIImage? {
        if let latest = await MainActor.run(body: { cameraService.latestFrame }) { return latest }
        if let data = try? await cameraService.capturePhoto() { return UIImage(data: data) }
        return nil
    }

    /// Badge QR/matrix codes on the same frame. Failure is empty, not thrown — the OCR
    /// path stands alone when there's no code.
    private func scanBarcodePayloads(in cgImage: CGImage) -> [String] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr, .aztec, .dataMatrix, .microQR]
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        guard (try? handler.perform([request])) != nil else { return [] }
        return (request.results ?? []).compactMap { $0.payloadStringValue }
    }

    private func recognizeLines(in cgImage: CGImage) async throws -> [RecognizedTextLine] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                let lines = observations.compactMap { obs -> RecognizedTextLine? in
                    guard let top = obs.topCandidates(1).first else { return nil }
                    return RecognizedTextLine(top.string,
                                              boundingBox: obs.boundingBox,
                                              confidence: top.confidence)
                }
                continuation.resume(returning: lines)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false  // names/orgs are exactly what correction mangles

            do {
                try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
