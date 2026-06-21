import UIKit
import Social
import UniformTypeIdentifiers

/// Share Extension: lets the user send text (e.g. from an Apple Note), a URL, or a text
/// file straight into OpenGlasses as a teleprompter script. Uses the system compose UI
/// (`SLComposeServiceViewController`), which pre-fills the editable box with shared text,
/// and hands the (possibly-edited) result to the main app via `SharedTeleprompterInbox`.
@objc(ShareViewController)
final class ShareViewController: SLComposeServiceViewController {

    override func presentationAnimationDidFinish() {
        super.presentationAnimationDidFinish()
        // For non-text items (URL / text file) the box starts empty — pull the text in so
        // the user sees and can edit it before posting.
        if (contentText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            loadSharedText { [weak self] text in
                guard let self, let text, !text.isEmpty else { return }
                self.textView.text = text
                self.validateContent()
            }
        }
    }

    override func isContentValid() -> Bool {
        !(contentText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    override func didSelectPost() {
        let typed = (contentText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty {
            save(typed)
            complete()
        } else {
            // Fallback if the box never populated (e.g. attachment loaded late).
            loadSharedText { [weak self] text in
                if let text, !text.isEmpty { self?.save(text) }
                self?.complete()
            }
        }
    }

    override func configurationItems() -> [Any]! { [] }

    // MARK: - Helpers

    private func save(_ text: String) {
        SharedTeleprompterInbox.append(title: Self.deriveTitle(from: text), text: text)
    }

    private func complete() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    /// First non-empty line, trimmed and clipped — the same default the app uses.
    private static func deriveTitle(from text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let clipped = String(firstLine.prefix(40)).trimmingCharacters(in: .whitespaces)
        return clipped.isEmpty ? "Shared script" : clipped
    }

    /// Pull text out of the first attachment that's plain text, a file, or a URL.
    private func loadSharedText(completion: @escaping (String?) -> Void) {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem])?
            .flatMap { $0.attachments ?? [] } ?? []
        guard !providers.isEmpty else { completion(nil); return }

        let textTypes = [UTType.plainText.identifier, UTType.text.identifier]
        let provider = providers.first { p in textTypes.contains { p.hasItemConformingToTypeIdentifier($0) } }
            ?? providers.first { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
            ?? providers.first { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }
        guard let provider else { completion(nil); return }

        let typeID = textTypes.first { provider.hasItemConformingToTypeIdentifier($0) }
            ?? (provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                ? UTType.fileURL.identifier : UTType.url.identifier)

        provider.loadItem(forTypeIdentifier: typeID, options: nil) { item, _ in
            var result: String?
            switch item {
            case let string as String:
                result = string
            case let url as URL:
                // A file URL → read its contents; a web URL → use the link text.
                result = (try? String(contentsOf: url, encoding: .utf8)) ?? url.absoluteString
            case let data as Data:
                result = String(data: data, encoding: .utf8)
            default:
                result = nil
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}
