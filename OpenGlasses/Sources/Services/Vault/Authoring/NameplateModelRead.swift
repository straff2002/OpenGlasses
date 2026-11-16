import Foundation
import UIKit

/// Plan LW §4 — *Add this model*: the model numbers a nameplate photo shows, read on the phone.
///
/// The same read `EquipmentLookupTool` makes of a nameplate (on-device `OCRService`, then
/// `CodeTokenizer.candidateTokens`), without a field session: the photo comes from the phone's
/// camera or library and goes nowhere. The whole tokens the template's identity pattern reads as a
/// model come first, hyphens kept; the code tokens follow, so a model the pattern misses can still
/// be picked.
enum NameplateModelRead {

    static func tokens(fromOCRText text: String, template: TradeTemplate) -> [String] {
        // Whole tokens with their inner hyphens (`QX-100A`), as a model section's heading spells
        // them, read the way the model-map proposals read a cover page; then the code tokens.
        var seen = Set<String>()
        let models = ModelMapProposals.tokens(in: text.uppercased(), template: template)
        let candidates = CodeTokenizer.candidateTokens(from: text)
        return (models + candidates).filter { seen.insert(VaultModelIndex.key($0)).inserted }
    }

    /// The text on the photo, by on-device recognition.
    static func read(_ image: UIImage, ocr: OCRService = OCRService()) async -> String {
        guard let data = image.jpegData(compressionQuality: 0.9) else { return "" }
        return await ocr.recognizeText(in: data).text
    }
}
