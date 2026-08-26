import SwiftUI

/// Shared control-status colour for HECA views.
///
/// Two variants, for the same reason `OGTheme` splits the status hues: `color`
/// is the hue as an evidence box or a capsule wash, `labelColor` is the same
/// meaning as *text*, corrected until it clears AA on the app's surfaces.
enum SafetyControlColor {
    static func color(for status: ControlStatus) -> Color {
        switch status {
        case .direct: return OGTheme.ok
        case .indirect: return OGTheme.warn
        case .none: return OGTheme.error
        }
    }

    static func labelColor(for status: ControlStatus) -> Color {
        switch status {
        case .direct: return OGTheme.okLabel
        case .indirect: return OGTheme.warnLabel
        case .none: return OGTheme.errorLabel
        }
    }
}

/// Draws HECA evidence boxes over the captured frame, colored by each hazard's control status
/// (docs/plans/safety-assessment.md). Box placement uses the pure `SafetyBoxMapping`, corrected for
/// the letterboxing introduced by `scaledToFit`.
struct SafetyAssessmentOverlay: View {
    let image: UIImage
    let report: SafetyReport

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Image(uiImage: image).resizable().scaledToFit()
                ForEach(boxes(in: geo.size)) { item in
                    Rectangle()
                        .strokeBorder(item.color, lineWidth: 2)
                        .background(item.color.opacity(0.12))
                        .frame(width: item.rect.width, height: item.rect.height)
                        .offset(x: item.rect.minX, y: item.rect.minY)
                }
            }
        }
    }

    private struct BoxItem: Identifiable {
        let id = UUID()
        let rect: CGRect
        let color: Color
    }

    private func boxes(in size: CGSize) -> [BoxItem] {
        let imgSize = image.size
        guard imgSize.width > 0, imgSize.height > 0 else { return [] }
        // `scaledToFit` letterboxes — compute the displayed image rect.
        let scale = min(size.width / imgSize.width, size.height / imgSize.height)
        let dispW = imgSize.width * scale
        let dispH = imgSize.height * scale
        let originX = (size.width - dispW) / 2
        let originY = (size.height - dispH) / 2
        var items: [BoxItem] = []
        for finding in report.present {
            let color = SafetyControlColor.color(for: finding.controlStatus)
            for ev in finding.evidence {
                guard let r = SafetyBoxMapping.rect(for: ev.box, in: CGSize(width: dispW, height: dispH)) else { continue }
                items.append(BoxItem(rect: r.offsetBy(dx: originX, dy: originY), color: color))
            }
        }
        return items
    }
}
