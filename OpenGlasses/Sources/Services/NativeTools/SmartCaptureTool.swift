import Foundation

/// Turns a glasses-camera capture into structured fields the agent can act on (Plan: capture→action).
/// OCRs on-device, parses by mode (business card / receipt / event flyer), and returns the extracted
/// fields plus a suggested next action — the agent then chains to `contacts`, `calendar`, or
/// `notes_vault` to actually act. Keeping extraction separate avoids new write-permissions here.
@MainActor
final class SmartCaptureTool: NativeTool {
    let name = "smart_capture"
    let description = """
    Capture a business card, receipt, or event flyer through the glasses and extract its key details. \
    Modes: 'contact' (name/company/phone/email — then offer to save via contacts or notes), 'receipt' \
    (merchant/total/date — then offer to log the expense), 'event' (title/date/location — then offer \
    to create a calendar event). Use for "save this card", "log this receipt", "add this event".
    """
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "mode": ["type": "string", "description": "'contact', 'receipt', or 'event'."]
        ],
        "required": ["mode"]
    ]

    private let cameraService: CameraService
    private let ocr: OCRService
    init(cameraService: CameraService, ocr: OCRService = OCRService()) {
        self.cameraService = cameraService
        self.ocr = ocr
    }

    func execute(args: [String: Any]) async throws -> String {
        guard let mode = (args["mode"] as? String)?.lowercased() else {
            return "Specify a mode: 'contact', 'receipt', or 'event'."
        }
        let data: Data?
        if let frame = cameraService.latestFrame, let jpeg = frame.jpegData(compressionQuality: 0.9) {
            data = jpeg
        } else {
            data = try? await cameraService.capturePhoto()
        }
        guard let data else { return "Couldn't capture the image. Hold it steady and try again." }
        let text = await ocr.recognizeText(in: data).text
        guard !text.isEmpty else { return "I couldn't read any text. Move closer or improve the lighting." }

        switch mode {
        case "contact", "card", "business_card":
            let c = CaptureParsers.parseBusinessCard(text)
            return field("Business card", [
                ("Name", c.name), ("Company", c.company), ("Phone", c.phone), ("Email", c.email)
            ], action: "Offer to save this to contacts or the people notes.")
        case "receipt", "expense":
            let r = CaptureParsers.parseReceipt(text)
            return field("Receipt", [
                ("Merchant", r.merchant), ("Total", r.total), ("Date", r.date)
            ], action: "Offer to log this expense (e.g. via notes_vault).")
        case "event", "flyer":
            let e = CaptureParsers.parseEvent(text)
            return field("Event", [
                ("Title", e.title), ("Date", e.date), ("Location", e.location)
            ], action: "Offer to create this with the calendar tool.")
        default:
            return "Unknown mode '\(mode)'. Use 'contact', 'receipt', or 'event'."
        }
    }

    private func field(_ title: String, _ pairs: [(String, String?)], action: String) -> String {
        let lines = pairs.compactMap { key, value in value.map { "\(key): \($0)" } }
        if lines.isEmpty {
            return "\(title): I couldn't extract clear details. Read them to me or try a clearer shot."
        }
        return "\(title) detected:\n" + lines.joined(separator: "\n") + "\n\n[\(action)]"
    }
}
