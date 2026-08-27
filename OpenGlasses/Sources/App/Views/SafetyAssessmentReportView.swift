import SwiftUI

/// Rich HECA report view (docs/plans/safety-assessment.md): the score, the optional annotated frame,
/// and every present high-energy hazard with its control status. Advisory only.
struct SafetyAssessmentReportView: View {
    let report: SafetyReport
    var image: UIImage? = nil
    var onDismiss: (() -> Void)? = nil

    @ScaledMetric(relativeTo: .body) private var tapTarget: CGFloat = 44

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                if let image {
                    SafetyAssessmentOverlay(image: image, report: report)
                        .frame(maxHeight: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                if !report.summary.isEmpty {
                    Text(report.summary).font(.subheadline)
                }

                scoreBanner
                presentSection

                Text(SafetyAssessmentSchema.disclaimer)
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(16)
        }
        .background(OGTheme.canvas.ignoresSafeArea())
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Safety Assessment").font(.headline)
                Text("AI HECA · \(report.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2.weight(.semibold)).foregroundStyle(AppAccent.aiCoral)
            }
            Spacer()
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
                        .frame(minWidth: tapTarget, minHeight: tapTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel("Dismiss")
            }
        }
    }

    private var scoreBanner: some View {
        OGCard(cornerRadius: 12) {
            HStack(spacing: 12) {
                if let score = report.score {
                    Text("\(Int((score * 100).rounded()))%")
                        .font(.system(.largeTitle, design: .rounded, weight: .bold)).monospacedDigit()
                        .foregroundStyle(score >= 1.0 ? OGTheme.okLabel : (report.uncontrolled.contains { $0.controlStatus == .none } ? OGTheme.errorLabel : OGTheme.warnLabel))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("HECA score").font(.caption).foregroundStyle(.secondary)
                        Text("\(report.present.filter { $0.controlStatus == .direct }.count)/\(report.present.count) present hazards directly controlled")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                } else {
                    Text("No high-energy hazards detected").font(.subheadline)
                }
                Spacer()
            }
            .padding(12)
        }
    }

    private var presentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if report.present.isEmpty {
                Text("No high-energy hazards present.").font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(report.present) { finding in findingRow(finding) }
            }
        }
    }

    private func findingRow(_ f: HazardFinding) -> some View {
        // `color` (from the shared, uncorrected enum) is the wash; `label` is the
        // WCAG-AA-audited variant for the glyph and badge text beside it.
        let color = SafetyControlColor.color(for: f.controlStatus)
        let label = SafetyControlColor.labelColor(for: f.controlStatus)
        let control = f.controlStatus == .direct ? f.directControl
            : (f.controlStatus == .indirect ? f.indirectControl : "")
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: f.hazard.systemImage).foregroundStyle(label).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(f.hazard.displayName).font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(f.controlStatus.rawValue.uppercased())
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(color.opacity(0.18), in: Capsule())
                        .foregroundStyle(label)
                }
                if !control.isEmpty { Text(control).font(.caption).foregroundStyle(.secondary) }
                if !f.comments.isEmpty { Text(f.comments).font(.caption2).foregroundStyle(.secondary) }
            }
        }
        .padding(.vertical, 4)
    }
}
