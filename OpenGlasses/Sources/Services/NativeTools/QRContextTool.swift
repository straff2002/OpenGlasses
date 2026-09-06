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
    private let networkDecision: UntrustedNetworkFeaturePolicy.Decision
    private let fetch: (URL) async throws -> (Data, HTTPURLResponse)

    init(
        cameraService: CameraService,
        networkDecision: UntrustedNetworkFeaturePolicy.Decision =
            UntrustedNetworkFeaturePolicy.currentDecision(for: .qrContextFetch),
        fetch: @escaping (URL) async throws -> (Data, HTTPURLResponse) = { url in
            let (data, response) = try await BoundedHTTPClient().fetchData(url, profile: .qrContext)
            guard let http = HTTPURLResponse(
                url: response.finalURL,
                statusCode: response.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: response.headers
            ) else { throw URLError(.badServerResponse) }
            return (data, http)
        }
    ) {
        self.cameraService = cameraService
        self.networkDecision = networkDecision
        self.fetch = fetch
    }

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

        // A QR payload is whatever someone printed on a wall: a URL with a token in its query,
        // a JSON venue definition, a plain note. Its class and size are loggable; it is not.
        let isURL = payload.hasPrefix("http://") || payload.hasPrefix("https://")
        let isJSON = payload.hasPrefix("{") || payload.hasPrefix("[")
        PrivacyLog.qrScanned(payload: isURL ? .url : (isJSON ? .json : .text),
                             bytes: payload.utf8.count)

        // Check if it's a URL
        if isURL {
            return await loadContext(from: payload, createPlaybook: createPlaybook)
        }

        // Check if it's JSON (playbook definition)
        if isJSON {
            return parseJSONContext(payload, createPlaybook: createPlaybook)
        }

        // Plain text — use as-is
        return "QR code content loaded as context:\n\n\(payload)\n\n[This context is now available for your responses. Use it to provide informed answers about this venue/location.]"
    }

    // MARK: - Context Loading

    private func loadContext(from urlString: String, createPlaybook: Bool) async -> String {
        guard networkDecision.allowsRequest else {
            PrivacyLog.qrFetchBlocked(.init(
                category: .refused,
                detail: PrivacyToken("releaseContainment")
            ))
            return UntrustedNetworkFeaturePolicy.unavailableMessage
        }

        // SSRF guard (Plan BC): the URL comes from a scanned QR or an LLM arg — never let it aim
        // at the user's private network or a metadata endpoint.
        let url: URL
        switch URLFetchGuard.validate(urlString) {
        case .success(let validated):
            url = validated
        case .failure(let rejection):
            // The rejection's own description names the host or scheme it refused — case only.
            PrivacyLog.qrFetchBlocked(.refused(rejection))
            return "Won't load that URL — \(rejection.description)."
        }

        do {
            let (data, httpResponse) = try await fetch(url)

            guard (200...299).contains(httpResponse.statusCode) else {
                return "Failed to load context from \(url.host ?? "the requested host") (HTTP \(httpResponse.statusCode))"
            }

            guard let content = String(data: data, encoding: .utf8) else {
                return "Could not read content from \(url.host ?? "the requested host")"
            }

            // Truncate very long content
            let maxLength = 8000
            let truncated = content.count > maxLength
                ? String(content.prefix(maxLength)) + "\n\n[Content truncated — \(content.count) characters total]"
                : content

            PrivacyLog.qrFetchLoaded(host: url.host, characters: content.count)

            var result = "[CONTEXT_LOADED from \(url.host ?? urlString)]\n\n\(truncated)\n\n"
            result += "[Use this context to provide informed, detailed responses about this venue, museum, or location. "
            result += "Cross-reference what you see through the camera with this information.]"

            if createPlaybook {
                result += "\n\n[A playbook should be created from this context. Extract the key sections as steps.]"
            }

            return result
        } catch {
            return "Failed to load context from \(url.host ?? "the requested host"): \(error.localizedDescription)"
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
