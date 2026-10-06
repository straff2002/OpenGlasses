import CoreGraphics
import Foundation

/// The machine-readable marking every PDF the app writes carries (Plan HQ P1 item 1).
///
/// A PDF says what made it in two places a reader's software looks: the Info dictionary (`Title`,
/// `Creator`, `Subject`, `Keywords`) and an XMP metadata packet. The XMP is the one a provenance
/// detector reads: it carries the IPTC digital source type — the controlled-vocabulary URI the
/// provenance ecosystem uses for "made by a trained model" — next to the standard `xmp:` and `dc:`
/// fields. Nothing here is a proprietary namespace.
///
/// One stamp, built once per document and handed to both halves of the renderer: its
/// `documentInfo` goes on the `UIGraphicsPDFRendererFormat`, and `apply(to:)` adds the XMP to the
/// renderer's context. Every PDF writer goes through this type so the four renderers (and the
/// medical export) cannot drift into four spellings of the same claim.
///
/// **What it never carries:** the instructions a model was given, a source document, or the
/// document's body. The description is `AIProvenance.footerLine` — the model, where it ran, a
/// digest of the instruction version, the time and the app build — or a fixed sentence when no
/// model was recorded.
struct PDFProvenanceStamp: Equatable {

    /// The IPTC digital source type a document declares.
    enum DigitalSourceType: String, Equatable {
        /// Produced by a trained model.
        case trainedAlgorithmicMedia =
            "http://cv.iptc.org/newscodes/digitalsourcetype/trainedAlgorithmicMedia"
        /// A mix of human input (speech-to-text, entered values) and model output.
        case compositeWithTrainedAlgorithmicMedia =
            "http://cv.iptc.org/newscodes/digitalsourcetype/compositeWithTrainedAlgorithmicMedia"
    }

    /// The keyword every document holding model output carries, in `Keywords` and `dc:subject`.
    static let aiGeneratedKeyword = "AI-generated"

    let title: String
    let creator: String
    /// The Info `Subject` and the XMP `dc:description`.
    let subject: String
    let keywords: [String]
    let sourceType: DigitalSourceType
    /// The software that made the document, as `xmp:CreatorTool`.
    let creatorTool: String
    let createdAt: Date

    init(title: String, creator: String, subject: String, keywords: [String],
         sourceType: DigitalSourceType, creatorTool: String, createdAt: Date) {
        self.title = title
        self.creator = creator
        self.subject = subject
        self.keywords = keywords
        self.sourceType = sourceType
        self.creatorTool = creatorTool
        // Whole seconds, like `AIProvenance.generatedAt`: the XMP date is written without a
        // fractional part, and the value read back should be the value that went in.
        self.createdAt = Date(timeIntervalSince1970: createdAt.timeIntervalSince1970.rounded(.down))
    }

    /// The stamp for a document holding model output.
    ///
    /// - Parameters:
    ///   - provenance: which model wrote it, or nil when none was recorded — the document still
    ///     says it holds AI-generated content, and says the model is unknown.
    ///   - title: the document's own title. A fixed heading, never a customer or patient name.
    ///   - composite: true when the document mixes human input (speech-to-text, entered values)
    ///     with model text; false when the model wrote it.
    ///   - unrecordedSubject: what `Subject` says when `provenance` is nil.
    static func aiGenerated(provenance: AIProvenance?, title: String, composite: Bool,
                            unrecordedSubject: String, now: Date = Date()) -> PDFProvenanceStamp {
        let version = provenance?.appVersion ?? AIProvenance.currentAppVersion
        let creator: String
        if provenance != nil {
            creator = "Avenkin \(version) — AI-generated"
        } else {
            creator = composite ? "Avenkin — contains AI-generated content" : "Avenkin — AI-generated"
        }
        return PDFProvenanceStamp(
            title: title,
            creator: creator,
            subject: provenance?.footerLine ?? unrecordedSubject,
            keywords: [aiGeneratedKeyword],
            sourceType: composite ? .compositeWithTrainedAlgorithmicMedia : .trainedAlgorithmicMedia,
            creatorTool: "Avenkin \(version)",
            createdAt: provenance?.generatedAt ?? now)
    }

    // MARK: - Info dictionary

    /// PDF document metadata keys, for `UIGraphicsPDFRendererFormat.documentInfo`.
    var documentInfo: [String: Any] {
        [
            kCGPDFContextTitle as String: title,
            kCGPDFContextCreator as String: creator,
            kCGPDFContextSubject as String: subject,
            kCGPDFContextKeywords as String: keywords.joined(separator: ", "),
        ]
    }

    // MARK: - XMP

    /// Whole-second ISO-8601, the form `xmp:CreateDate` takes.
    private static let timestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// A minimal, well-formed XMP packet: `xmp:CreatorTool`, `xmp:CreateDate`, `dc:title`,
    /// `dc:description`, `dc:subject` and `Iptc4xmpExt:DigitalSourceType`.
    var xmpPacket: Data {
        let escape = Self.xmlEscaped
        let subjects = keywords.map { "<rdf:li>\(escape($0))</rdf:li>" }.joined()
        let packet = """
            <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
            <x:xmpmeta xmlns:x="adobe:ns:meta/">
             <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
              <rdf:Description rdf:about=""
                xmlns:xmp="http://ns.adobe.com/xap/1.0/"
                xmlns:dc="http://purl.org/dc/elements/1.1/"
                xmlns:Iptc4xmpExt="http://iptc.org/std/Iptc4xmpExt/2008-02-29/"
                xmp:CreatorTool="\(escape(creatorTool))"
                xmp:CreateDate="\(Self.timestampFormatter.string(from: createdAt))"
                Iptc4xmpExt:DigitalSourceType="\(sourceType.rawValue)">
               <dc:title><rdf:Alt><rdf:li xml:lang="x-default">\(escape(title))</rdf:li></rdf:Alt></dc:title>
               <dc:description><rdf:Alt><rdf:li xml:lang="x-default">\(escape(subject))</rdf:li></rdf:Alt></dc:description>
               <dc:subject><rdf:Bag>\(subjects)</rdf:Bag></dc:subject>
              </rdf:Description>
             </rdf:RDF>
            </x:xmpmeta>
            <?xpacket end="w"?>
            """
        return Data(packet.utf8)
    }

    /// Add the XMP packet to a PDF context. Call inside the renderer's drawing block; the Info
    /// dictionary half is `documentInfo`, set on the renderer's format.
    func apply(to context: CGContext) {
        context.addDocumentMetadata(xmpPacket as CFData)
    }

    private static func xmlEscaped(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default:
                // XML 1.0 has no form for most control characters; a value never needs one.
                if scalar.value < 0x20, scalar != "\n", scalar != "\t" { continue }
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}

extension AIProvenance {
    /// The XMP packet for a document this model wrote (`composite` when the document mixes human
    /// input with the model's text). See `PDFProvenanceStamp`.
    func xmpPacket(title: String, composite: Bool = false) -> Data {
        PDFProvenanceStamp.aiGenerated(provenance: self, title: title, composite: composite,
                                       unrecordedSubject: footerLine).xmpPacket
    }

    /// `pdfDocumentInfo` with the document's own title.
    func pdfDocumentInfo(title: String) -> [String: Any] {
        var info = pdfDocumentInfo
        info[kCGPDFContextTitle as String] = title
        return info
    }
}
