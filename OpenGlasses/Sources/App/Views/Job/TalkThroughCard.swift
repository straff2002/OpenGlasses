import SwiftUI

/// Talk-through on the procedure step screen (Plan JI §7a, P6b): the "Talk me through it" switch,
/// off by default and for this run only; which mic listens; the step the narration points at, with
/// a yes that moves on exactly as Next does; the deviation phrase when the narration moved past a
/// step that asks for something; the step's own hints; and a question's passage. Every decision is
/// the session's; this shows it and asks.
struct TalkThroughCard: View {
    @ObservedObject var service: TalkThroughService
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(
                get: { service.isRunning },
                set: { on in
                    if on { appState.startTalkThrough() } else { appState.stopTalkThrough() }
                })) {
                Text(TalkThroughCopy.switchLabel)
                    .font(.body)
            }
            .frame(minHeight: OGMetrics.minTouchTarget)
            .accessibilityIdentifier("talk-through-switch")
            Text(TalkThroughCopy.switchHint)
                .font(.footnote)
                .foregroundStyle(OGTheme.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
            if service.isRunning {
                running
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OGTheme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    @ViewBuilder
    private var running: some View {
        Text(TalkThroughMicPlan.line(route: appState.talkThroughMicRoute,
                                     glassesHaveDisplay: appState.talkThroughGlassesHaveDisplay))
            .font(.footnote)
            .foregroundStyle(OGTheme.secondaryLabel)
            .fixedSize(horizontal: false, vertical: true)
        if let proposal = service.proposal {
            Text(TalkThroughCopy.proposal(proposal.title))
                .font(.headline)
                .foregroundStyle(Color(.label))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("talk-through-proposal")
            HStack(spacing: 12) {
                button(TalkThroughCopy.proposalYes, prominent: true) { _ = service.confirmProposal() }
                button(TalkThroughCopy.proposalNo, prominent: false) { service.declineProposal() }
            }
        }
        if let line = service.offOrderLine {
            Text(line)
                .font(.callout)
                .foregroundStyle(OGTheme.warnLabel)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let hint = service.currentHint {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(hint.phoneLines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.callout)
                        .foregroundStyle(Color(.label))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
        }
        if let card = service.questionCard {
            VStack(alignment: .leading, spacing: 4) {
                if let question = card.question {
                    Text(question)
                        .font(.footnote)
                        .foregroundStyle(OGTheme.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(card.full.isEmpty ? card.line : card.full)
                    .font(.callout)
                    .foregroundStyle(Color(.label))
                    .fixedSize(horizontal: false, vertical: true)
                if let source = card.sourceLabel {
                    Text(source)
                        .font(.caption)
                        .foregroundStyle(OGTheme.secondaryLabel)
                }
            }
            .accessibilityElement(children: .combine)
        }
        if !service.justGo {
            Button {
                service.turnOnJustGo()
            } label: {
                Text(TalkThroughCopy.justGoButton)
                    .frame(maxWidth: .infinity, minHeight: OGMetrics.minTouchTarget, alignment: .leading)
            }
            .accessibilityHint(TalkThroughCopy.justGoHint)
        }
    }

    private func button(_ title: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(ProcedureButtonStyle(prominent: prominent))
    }
}
