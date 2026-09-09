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
            return "No camera frame available. Make sure the glasses are connected and the camera is active."
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
            request.symbologies = [.ean8, .ean13, .upce, .code39, .code93, .code128, .itf14, .pdf417]
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
                decoded.append("\(typeStr): \(payload)")
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
