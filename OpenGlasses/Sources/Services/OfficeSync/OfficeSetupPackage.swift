import Foundation

/// Local hand-off format for the two independently vendor-signed setup documents. This wrapper
/// has no authority of its own; OfficeInlineEntitlement verifies both signatures after parsing.
enum OfficeSetupPackage {
    static let maximumBytes = 65_536
    /// The extension Avenkin Office gives a setup file, so the system offers this app for it.
    static let fileExtension = "avenkinsetup"
    /// Exported in Info.plist. Conforms to JSON: the file is the same package under its own name.
    static let typeIdentifier = "com.openglasses.app.office-setup"

    /// Whether a URL handed to the app is an Avenkin Office setup file.
    static func isSetupFile(_ url: URL) -> Bool {
        url.isFileURL && url.pathExtension.lowercased() == fileExtension
    }

    struct Contents: Codable, Equatable {
        let version: Int
        let profileDocument: String
        let licenceCode: String
    }

    enum Refusal: Error, Equatable {
        case malformed
    }

    static func decode(_ data: Data) throws -> Contents {
        guard data.count <= maximumBytes,
              OfficeManualAssignment.flatObject(data, keys: ["version", "profileDocument", "licenceCode"]),
              let contents = try? JSONDecoder().decode(Contents.self, from: data),
              contents.version == 1,
              !contents.profileDocument.isEmpty,
              !contents.licenceCode.isEmpty,
              contents.profileDocument.utf8.count <= 32_768,
              contents.licenceCode.utf8.count <= 16_384 else { throw Refusal.malformed }
        return contents
    }
}
