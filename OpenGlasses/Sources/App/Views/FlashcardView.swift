import SwiftUI

/// Flashcard review (docs/plans/study-mode.md) — drives `StudyService`'s spaced-repetition review
/// session (single source of truth, so grades persist via the store). Tap to flip; grade to advance.
struct FlashcardView: View {
    let deckID: String
    @ObservedObject private var service = StudyService.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 24) {
            if let session = service.reviewSession, session.index < session.cards.count {
                let card = session.cards[session.index]

                Text("Card \(session.index + 1) of \(session.cards.count)")
                    .font(.caption).foregroundStyle(.secondary)

                Spacer()

                Button {
                    if !session.showingBack { _ = service.flip() }
                } label: {
                    VStack(spacing: 12) {
                        Text(card.front).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                        if session.showingBack {
                            Divider()
                            Text(card.back).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        } else {
                            Text("Tap to reveal").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity).padding(28)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain)

                Spacer()

                if session.showingBack {
                    HStack(spacing: 16) {
                        Button(role: .destructive) { _ = service.gradeCard(correct: false) } label: {
                            Label("Missed", systemImage: "xmark").frame(maxWidth: .infinity)
                        }
                        Button { _ = service.gradeCard(correct: true) } label: {
                            Label("Got it", systemImage: "checkmark").frame(maxWidth: .infinity)
                        }
                        .tint(OGTheme.ok)
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                ContentUnavailableView("Review complete", systemImage: "checkmark.seal.fill")
                Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .navigationTitle("Flashcards")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { _ = service.startReview(deckID: deckID) }
        .onDisappear { service.stop() }
    }
}
