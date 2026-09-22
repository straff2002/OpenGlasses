import UIKit

/// Turning a stored evidence file into the copy the work order carries (Plan FO P2a).
///
/// Two things have to happen and the order matters. The image is **re-encoded**, not merely drawn
/// small: a PDF page that draws a 3024×4032 still inside a 400-point box still embeds every one of
/// those pixels, so scaling at draw time would produce a document that looks right and weighs sixty
/// megabytes. Downscaling and re-compressing first is what makes `EvidenceImageBudget`'s arithmetic
/// describe the file that actually comes out.
///
/// Nothing here filters anything. The file on disk is already the filtered copy — that is the whole
/// point of doing the blur at capture (Plan FO P2a, owner decision 2026-09-21): raw pixels are never
/// stored, so there is nothing to un-blur at export time and no second chokepoint to get wrong.
enum EvidenceImageRenderer {

    /// Load one evidence file. Nil when it is missing or is not an image — a record that lost a
    /// file prints the rest of itself rather than failing.
    static func load(_ itemId: String, from directory: URL) -> UIImage? {
        let url = directory.appendingPathComponent(itemId)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    /// The copy the PDF embeds: at most `plan.longEdge` on its longest side, re-encoded at
    /// `plan.quality`. Aspect ratio preserved; never enlarged.
    static func downscaled(_ image: UIImage, plan: EvidenceImageBudget.Plan) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > 0 else { return image }
        let scale = longest > plan.longEdge ? plan.longEdge / longest : 1
        let size = CGSize(width: max(1, (image.size.width * scale).rounded()),
                          height: max(1, (image.size.height * scale).rounded()))

        let format = UIGraphicsImageRendererFormat.default()
        // Points to pixels one for one: the renderer's default scale is the screen's, which on a
        // 3× device would silently triple every dimension the budget just decided.
        format.scale = 1
        format.opaque = true
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let data = resized.jpegData(compressionQuality: plan.quality),
              let reloaded = UIImage(data: data) else { return resized }
        return reloaded
    }
}
