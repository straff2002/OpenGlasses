import Foundation
import Vision
import UIKit

/// Scans a QR code from the camera and loads its content as context for the AI.
/// Supports two patterns:
/// 1. URL QR codes — fetches the URL and loads content as reference material
/// 2. JSON QR codes — parses as playbook definition (steps + context)
///
/// Primary use case: museum entrance QR loads full museum context for AI docent mode.
/// Inspired by BLISST's QR-triggered procedural guidance pattern.
struct QRContextTool: NativeTool {
    let name = "qr_context"
    let description = "Scan a QR code and load its content as context. For museum/venue QR codes, loads exhibit info, floor maps, and guides. For procedure QR codes, creates a step-by-step playbook. Use when user says 'scan that QR code' or 'load context' at a museum, venue, or workplace."

    let cameraService: CameraService

    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "url": [
                "type": "string",
                "description": "URL to load context from (if already known). Skips QR scanning."
            ],
            "create_playbook": [
                "type": "boolean",
                "description": "If true, also create a playbook from the loaded context. Default false."
            ]
        ],
        "required": [] as [String]
    ]

    func execute(args: [String: Any]) async throws -> String {
        let createPlaybook = (args["create_playbook"] as? Bool) ?? false

        // If URL is provided directly, skip QR scanning
        if let urlString = args["url"] as? String, !urlString.isEmpty {
            return await loadContext(from: urlString, createPlaybook: createPlaybook)
        }

        // Scan QR from camera
        guard let frame = await MainActor.run(body: { cameraService.latestFrame }),
              let cgImage = frame.cgImage else {
            return "No camera frame available. Make sure the glasses are connected and pointed at the QR code."
        }

        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return "QR detection failed: \(error.localizedDescription)"
        }

        guard let results = request.results,
              let firstQR = results.first,
              let payload = firstQR.payloadStringValue else {
            return "No QR code detected. Point the camera directly at the QR code and try again."
        }

        NSLog("[QRContext] Scanned QR: %@", String(payload.prefix(200)))

        // Check if it's a URL
        if payload.hasPrefix("http://") || payload.hasPrefix("https://") {
            return await loadContext(from: payload, createPlaybook: createPlaybook)
        }

        // Check if it's JSON (playbook definition)
        if payload.hasPrefix("{") || payload.hasPrefix("[") {
            return parseJSONContext(payload, createPlaybook: createPlaybook)
        }

        // Plain text — use as-is
        return "QR code content loaded as context:\n\n\(payload)\n\n[This context is now available for your responses. Use it to provide informed answers about this venue/location.]"
    }

    // MARK: - Context Loading

    private func loadContext(from urlString: String, createPlaybook: Bool) async -> String {
        guard let url = URL(string: urlString) else {
            return "Invalid URL: \(urlString)"
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            let httpResponse = response as? HTTPURLResponse

            guard let statusCode = httpResponse?.statusCode, (200...299).contains(statusCode) else {
                return "Failed to load context from \(urlString) (HTTP \(httpResponse?.statusCode ?? 0))"
            }

            guard let content = String(data: data, encoding: .utf8) else {
                return "Could not read content from \(urlString)"
            }

            // Truncate very long content
            let maxLength = 8000
            let truncated = content.count > maxLength
                ? String(content.prefix(maxLength)) + "\n\n[Content truncated — \(content.count) characters total]"
                : content

            NSLog("[QRContext] Loaded %d characters from %@", content.count, urlString)

            var result = "[CONTEXT_LOADED from \(url.host ?? urlString)]\n\n\(truncated)\n\n"
            result += "[Use this context to provide informed, detailed responses about this venue, museum, or location. "
            result += "Cross-reference what you see through the camera with this information.]"

            if createPlaybook {
                result += "\n\n[A playbook should be created from this context. Extract the key sections as steps.]"
            }

            return result
        } catch {
            return "Failed to load context from \(urlString): \(error.localizedDescription)"
        }
    }

    // MARK: - JSON Context Parsing

    private func parseJSONContext(_ json: String, createPlaybook: Bool) -> String {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "QR contains text content:\n\n\(json)\n\n[Context loaded for your responses.]"
        }

        var result = ""

        // Extract venue/context info
        if let name = parsed["name"] as? String {
            result += "Venue: \(name)\n"
        }
        if let description = parsed["description"] as? String {
            result += "Description: \(description)\n"
        }
        if let context = parsed["context"] as? String {
            result += "\n\(context)\n"
        }

        // Extract steps/procedures if present
        if let steps = parsed["steps"] as? [[String: Any]] {
            result += "\nProcedure (\(steps.count) steps):\n"
            for (i, step) in steps.enumerated() {
                let title = step["title"] as? String ?? "Step \(i + 1)"
                let detail = step["detail"] as? String ?? ""
                result += "  \(i + 1). \(title)"
                if !detail.isEmpty { result += " — \(detail)" }
                result += "\n"
            }
        }

        // Extract exhibits if present (museum mode)
        if let exhibits = parsed["exhibits"] as? [[String: Any]] {
            result += "\nExhibits (\(exhibits.count)):\n"
            for exhibit in exhibits {
                let name = exhibit["name"] as? String ?? "Unknown"
                let location = exhibit["location"] as? String ?? ""
                let info = exhibit["info"] as? String ?? ""
                result += "  • \(name)"
                if !location.isEmpty { result += " — \(location)" }
                if !info.isEmpty { result += ": \(info)" }
                result += "\n"
            }
        }

        if result.isEmpty {
            result = "QR context: \(json)"
        }

        return "[CONTEXT_LOADED]\n\n\(result)\n\n[Use this context to guide the user. Cross-reference with camera images for the most accurate responses.]"
    }
}
