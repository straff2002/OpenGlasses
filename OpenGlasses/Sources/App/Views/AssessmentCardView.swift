import SwiftUI

/// Renders any `AssessmentCard` (structured-vision plan, Phase 3) — tier chip, summary, instrument
/// readings, findings, recommended action, and "still needed". Generic over the schema: it knows
/// nothing about any vertical. AI attribution uses the coral accent.
struct AssessmentCardView: View {
    let card: AssessmentCard
    var onDismiss: () -> Void
    /// Optional "View full report" affordance for cards backed by a rich detail view (e.g. HECA).
    var onDetails: (() -> Void)? = nil

    @ScaledMetric(relativeTo: .body) private var tapTarget: CGFloat = 44

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if !card.summary.isEmpty {
                Text(card.summary).font(.subheadline).foregroundStyle(.primary)
            }

            if !card.readings.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(card.readings) { reading in readingRow(reading) }
                }
            }

            if !card.findings.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(card.findings) { finding in findingRow(finding) }
                }
            }

            if let action = card.recommendedAction, !action.isEmpty {
                Label(action, systemImage: "arrow.right.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tierLabelColor)
            }

            if !card.stillNeeded.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(card.stillNeeded, id: \.self) { need in
                        Label(need, systemImage: "circle.dashed")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            if let onDetails {
                Button(action: onDetails) {
                    Label("View full report", systemImage: "doc.text.magnifyingglass")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppAccent.aiCoral)
            }

            footer
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(tierColor.opacity(0.35), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: card.tier.systemImage).foregroundStyle(tierLabelColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(card.title).font(.headline)
                Text("AI vision · \(card.tier.displayLabel)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AppAccent.aiCoral)
            }
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3).foregroundStyle(.secondary)
                    .frame(minWidth: tapTarget, minHeight: tapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
    }

    private func readingRow(_ reading: InstrumentReading) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(reading.quantity.capitalized).font(.subheadline)
            Spacer()
            VStack(alignment: .trailing, spacing: 0) {
                Text("\(Self.fmt(reading.value)) \(reading.unit)")
                    .font(.subheadline.weight(.semibold)).monospacedDigit()
                if let c = reading.canonical, let cu = reading.canonicalUnit, cu != reading.unit {
                    Text("\(Self.fmt(c)) \(cu)")
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
    }

    private func findingRow(_ finding: AssessmentFinding) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().fill(color(for: finding.severity)).frame(width: 7, height: 7).padding(.top, 5)
            VStack(alignment: .leading, spacing: 1) {
                Text(finding.label).font(.subheadline)
                if let detail = finding.detail, !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("Confidence \(Int((card.confidence * 100).rounded()))%")
                .font(.caption2).foregroundStyle(.secondary)
            Spacer()
            if let disclaimer = card.disclaimer, !disclaimer.isEmpty {
                Text(disclaimer).font(.caption2).foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    // MARK: - Helpers

    private var tierColor: Color { color(for: card.tier) }
    private var tierLabelColor: Color { labelColor(for: card.tier) }

    /// Border wash / status-dot fill — the uncorrected hue.
    private func color(for tier: AssessmentTier) -> Color {
        switch tier {
        case .ok: return OGTheme.ok
        case .caution: return OGTheme.warn
        case .critical: return OGTheme.error
        }
    }

    /// Text / glyph colour — the WCAG-AA-audited label variant.
    private func labelColor(for tier: AssessmentTier) -> Color {
        switch tier {
        case .ok: return OGTheme.okLabel
        case .caution: return OGTheme.warnLabel
        case .critical: return OGTheme.errorLabel
        }
    }

    private static func fmt(_ value: Double) -> String { String(format: "%g", value) }
}

/// Overlay that presents the latest `AssessmentCard` over the main UI. Hosted by `RootView`.
struct AssessmentCardOverlay: View {
    @ObservedObject private var vision = StructuredVisionService.shared
    @ObservedObject private var safety = SafetyAssessmentService.shared
    @State private var showingReport = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let card = vision.latest {
            let canShowReport = card.kind == "safety_assessment" && safety.latest != nil
            VStack {
                Spacer()
                AssessmentCardView(card: card,
                                   onDismiss: { vision.dismiss() },
                                   onDetails: canShowReport ? { showingReport = true } : nil)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.85), value: vision.latest)
            .sheet(isPresented: $showingReport) {
                if let report = safety.latest {
                    SafetyAssessmentReportView(report: report, image: safety.lastImage) {
                        showingReport = false
                    }
                }
            }
        }
    }
}
