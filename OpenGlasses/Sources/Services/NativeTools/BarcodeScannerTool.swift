import Foundation
import Vision
import UIKit

/// Scans QR codes and barcodes from the glasses camera.
/// Uses Vision framework VNDetectBarcodesRequest for on-device detection.
struct BarcodeScannerTool: NativeTool {
    let name = "scan_code"
    let description = "Scan QR codes or barcodes from the camera. Returns the decoded content (URLs, text, product codes). Works offline."

    let cameraService: any FilteredStillProviding

    var parametersSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "type": [
                    "type": "string",
                    "description": "Code type to scan: 'qr', 'barcode', or 'any' (default). 'any' detects all types.",
                ],
            ],
            "required": [],
        ]
    }

    func execute(args: [String: Any]) async throws -> String {
        let scanType = (args["type"] as? String ?? "any").lowercased()

        // Barcode decoding is an on-device Vision pass that emits a string, so the on-device
        // scope passes the pixels through — but the still comes from the chokepoint like every
        // other (W04.1).
        guard let frame = await cameraService.filteredStill(for: .onDeviceVision).image else {
            return "No picture from the camera. Point it at the code and try again."
        }

        guard let cgImage = frame.cgImage else {
            return "Couldn't process the camera image."
        }

        // Set up barcode detection
        let request = VNDetectBarcodesRequest()

        // Filter by type if specified
        switch scanType {
        case "qr":
            request.symbologies = [.qr]
        case "barcode":
            // Data Matrix too: a medicine or vaccine carton carries its GS1 code as one (Plan MY §5).
            request.symbologies = [.ean8, .ean13, .upce, .code39, .code93, .code128, .itf14, .pdf417, .dataMatrix]
        default:
            // Detect all types
            break
        }

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            try handler.perform([request])
        } catch {
            return "Barcode detection failed: \(error.localizedDescription)"
        }

        guard let results = request.results, !results.isEmpty else {
            return "No codes detected in the current view. Try pointing the camera directly at a QR code or barcode."
        }

        // Process results
        var decoded: [String] = []
        for observation in results {
            let typeStr = symbologyName(observation.symbology)
            if let payload = observation.payloadStringValue {
                decoded.append("\(typeStr): \(payload)" + Self.gs1Fields(payload))
            }
        }

        if decoded.isEmpty {
            return "Detected \(results.count) code(s) but couldn't decode them. Try getting closer or adjusting the angle."
        }

        if decoded.count == 1 {
            let result = decoded[0]
            // Check if it's a URL
            if result.contains("http://") || result.contains("https://") {
                return "Found \(result). Would you like me to open this link?"
            }
            return "Found \(result)."
        }

        return "Found \(decoded.count) codes: \(decoded.joined(separator: ". "))"
    }

    /// A GS1 code's fields, read the way the stock list reads them (Plan MY §5): " (GS1: product
    /// number 02000000000015, lot ZZ1001, expiry 30 November 2027)". Empty for a code that is not
    /// a GS1 element string, and for one whose check digit or date is wrong, which says so.
    nonisolated static func gs1Fields(_ payload: String, referenceYear: Int = Calendar.current.component(.year, from: Date())) -> String {
        guard StockScan.looksLikeGS1(payload) else { return "" }
        switch GS1ElementString.parse(payload, referenceYear: referenceYear) {
        case .success(let fields):
            let scan = StockScan(raw: payload, code: fields.gtin ?? payload, gtin: fields.gtin, lot: fields.lot,
                                 expiry: fields.expiry, serial: fields.serial)
            let described = scan.described
            // The bracketed form carries every field with no separator to lose on the way back.
            return described.isEmpty ? "" : " (GS1: \(described); for van_stock pass 'code' \(fields.bracketed))"
        case .failure(let failure):
            return " (a GS1 code that could not be read safely: \(failure.sentence); scan it again)"
        }
    }

    private func symbologyName(_ symbology: VNBarcodeSymbology) -> String {
        switch symbology {
        case .qr: return "QR code"
        case .ean8, .ean13: return "EAN barcode"
        case .upce: return "UPC barcode"
        case .code39: return "Code 39"
        case .code93: return "Code 93"
        case .code128: return "Code 128"
        case .itf14: return "ITF-14"
        case .pdf417: return "PDF417"
        case .aztec: return "Aztec code"
        case .dataMatrix: return "Data Matrix"
        default: return "Code"
        }
    }
}
