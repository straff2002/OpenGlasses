import Foundation

/// One documentation page, as the authoring model is shown it.
struct AddOnDocsPage: Equatable, Sendable {
    /// Where it ended up, after any redirects.
    let url: URL
    /// Plain text: HTML reduced to its words, at most `AddOnDocsText.maxLength` characters.
    let text: String
}

enum AddOnDocsFetchError: Error, Equatable, Sendable {
    /// Not a plain https address (or one with a user name, a fragment or another port).
    case notPermitted
    /// The host answered with something other than success.
    case status(Int)
}

/// Reads an API's documentation page while the assistant builds an add-on. A seam, so the
/// building service is tested with a fake.
protocol AddOnDocsFetcher: Sendable {
    func fetch(_ url: URL) async throws -> AddOnDocsPage
}

/// The production fetcher, over the hardened client's `.addOnAuthoring` profile: GET only, HTTPS
/// only, public addresses only (DNS rebinding included), HTML, JSON or text, at most 256 KB, at
/// most three redirects each re-checked. Medical Compliance's Local Only mode refuses the route
/// here, whatever else allowed the session to start.
struct BoundedAddOnDocsFetcher: AddOnDocsFetcher {

    var makeClient: @Sendable () -> BoundedHTTPClient = { BoundedHTTPClient() }

    func fetch(_ url: URL) async throws -> AddOnDocsPage {
        try MedicalEgressGuard.check(.addOnAuthoringDocs)
        guard AddOnIngest.isPermittedSource(url) else { throw AddOnDocsFetchError.notPermitted }
        let (data, response) = try await makeClient().fetchData(url, profile: .addOnAuthoring)
        guard (200...299).contains(response.statusCode) else { throw AddOnDocsFetchError.status(response.statusCode) }
        let mime = response.headers["content-type"]?.split(separator: ";", maxSplits: 1).first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        let raw = String(decoding: data, as: UTF8.self)
        let text = mime == "text/html" || mime == "application/xhtml+xml" ? AddOnDocsText.plainText(fromHTML: raw) : raw
        return AddOnDocsPage(url: response.finalURL, text: String(text.prefix(AddOnDocsText.maxLength)))
    }
}

/// HTML reduced to readable text for the authoring model. Pure; not a parser — enough to keep a
/// documentation page's words and examples and drop its scripts, styles and markup.
enum AddOnDocsText {

    static let maxLength = 24_000

    static func plainText(fromHTML html: String) -> String {
        var text = html
        for element in ["script", "style", "noscript", "svg", "head"] {
            text = text.replacingOccurrences(of: "(?s)<\(element)\\b[^>]*>.*?</\(element)\\s*>", with: " ",
                                             options: [.regularExpression, .caseInsensitive])
        }
        text = text.replacingOccurrences(of: "(?s)<!--.*?-->", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "<(br|p|div|li|tr|h[1-6]|pre|code)\\b[^>]*>", with: "\n",
                                         options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        for (entity, character) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"),
                                    ("&apos;", "'"), ("&nbsp;", " "), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        let lines = text.components(separatedBy: .newlines).map {
            $0.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
        }
        var out: [String] = []
        for line in lines where !(line.isEmpty && (out.last?.isEmpty ?? true)) { out.append(line) }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
