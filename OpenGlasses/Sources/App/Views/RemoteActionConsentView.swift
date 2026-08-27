import SwiftUI

/// The shared remote-action consent card (Plan BN P1): ONE surface for Plan N coding-agent
/// confirms, Plan BH gateway capture consent, and the assistant's own high-impact tool calls —
/// source-attributed, paired with the coordinator's spoken prompt and the voice yes/no path
/// (`ToolConfirmationCoordinator.resolveByVoice`).
struct RemoteActionConsentView: View {
    let pending: PendingToolConfirmation
    let respond: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("\(pending.source.line) wants:", systemImage: sourceIcon)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(pending.summary)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button {
                    respond(false)
                } label: {
                    Text("Deny").frame(maxWidth: .infinity)
                }
                .buttonStyle(.ogQuiet)

                Button(role: .destructive) {
                    respond(true)
                } label: {
                    Text("Approve").frame(maxWidth: .infinity)
                }
                .buttonStyle(.ogProminent)
            }

            Text("Say \"yes\" or \"no\", or tap.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.quaternary))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(pending.source.line) wants: \(pending.summary). Approve or deny?")
    }

    private var sourceIcon: String {
        switch pending.source {
        case .assistant:   return "sparkles"
        case .codingAgent: return "hammer"
        case .gateway:     return "network"
        case .opsPeer:     return "building.2"
        }
    }
}
