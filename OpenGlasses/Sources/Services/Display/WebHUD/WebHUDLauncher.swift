import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Plan LT §7 — what a browser needs to put the web mirror on a home screen or launcher: two PNG
/// icons (the app mark, white on black, which reads the same in a monochrome launcher) and a web
/// app manifest. Served by `WebHUDMirrorServer` behind the mirror's token; the page links them from
/// its `<head>` with the token the page already holds.
enum WebHUDLauncher {

    /// The two sizes launchers ask for.
    enum IconSize: Int, CaseIterable {
        case small = 192
        case large = 512

        var path: String { "/icon-\(rawValue).png" }
    }

    static let manifestPath = "/manifest.webmanifest"
    static let manifestContentType = "application/manifest+json"

    /// The manifest, with the token on every URL in it so each fetch it leads to is authorised
    /// like the data endpoint, and the launcher opens a page that can poll (`start_url` carries
    /// the token in the hash, as the mirror's own link does). Black throughout: on the additive
    /// display black is transparent.
    static func manifest(token: String) -> Data {
        let query = token.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? ""
        let object: [String: Any] = [
            "name": "Avenkin HUD",
            "short_name": "HUD",
            "display": "standalone",
            "start_url": "/#t=" + query,
            "scope": "/",
            "background_color": "#000000",
            "theme_color": "#000000",
            "icons": IconSize.allCases.map { size -> [String: String] in
                [
                    "src": size.path + "?t=" + query,
                    "sizes": "\(size.rawValue)x\(size.rawValue)",
                    "type": "image/png",
                    // Not `monochrome`: that purpose reads only the alpha channel, and this icon
                    // is opaque. White on black already reads the same in a monochrome launcher.
                    "purpose": "any",
                ]
            },
        ]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    #if canImport(UIKit)
    @MainActor private static var cache: [IconSize: Data] = [:]

    /// The icon as PNG: the app mark, white, centred on black with a margin. Drawn once per size.
    @MainActor
    static func iconPNG(_ size: IconSize) -> Data? {
        if let cached = cache[size] { return cached }
        let side = CGFloat(size.rawValue)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let mark = UIImage(named: "AvenkinMark")?.withTintColor(.white, renderingMode: .alwaysOriginal)
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            guard let mark, mark.size.width > 0, mark.size.height > 0 else { return }
            // A launcher may crop to a circle: keep the mark inside the middle 60 %.
            let box = side * 0.6
            let scale = min(box / mark.size.width, box / mark.size.height)
            let drawn = CGSize(width: mark.size.width * scale, height: mark.size.height * scale)
            mark.draw(in: CGRect(x: (side - drawn.width) / 2, y: (side - drawn.height) / 2,
                                 width: drawn.width, height: drawn.height))
        }
        guard let png = image.pngData() else { return nil }
        cache[size] = png
        return png
    }
    #endif
}

private extension CharacterSet {
    /// Query-value characters: `urlQueryAllowed` without the separators a value must not carry.
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+#")
        return set
    }()
}
