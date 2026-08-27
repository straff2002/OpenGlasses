import SwiftUI

/// Study Mode deck list (docs/plans/study-mode.md) — the on-phone entry point. Decks are created by the
/// `study` tool ("make flashcards from <document>"); here you browse them and start review or a quiz.
struct DeckListView: View {
    @ObservedObject private var store = StudyStore.shared

    var body: some View {
        Group {
            if store.decks.isEmpty {
                ContentUnavailableView(
                    "No Study Decks",
                    systemImage: "rectangle.on.rectangle.angled",
                    description: Text("Ask the assistant to “make flashcards from a document” to create a deck."))
            } else {
                List {
                    ForEach(store.decks) { deck in
                        NavigationLink {
                            DeckDetailView(deck: deck)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(deck.summary.title).font(.headline)
                                Text("\(deck.flashcards.count) cards · \(deck.quiz.count) quiz")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { offsets in
                        offsets.map { store.decks[$0].id }.forEach(store.deleteDeck)
                    }
                }
                .ogFormStyle()
            }
        }
        .navigationTitle("Study Mode")
    }
}

/// One deck: summary + key points, with entry points into flashcard review and the quiz.
struct DeckDetailView: View {
    let deck: StudyDeck

    var body: some View {
        List {
            Section("Summary") {
                if !deck.summary.overview.isEmpty {
                    Text(deck.summary.overview).font(.subheadline)
                }
                ForEach(deck.summary.keyPoints, id: \.self) { point in
                    Text("• \(point)").font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                NavigationLink {
                    FlashcardView(deckID: deck.id)
                } label: {
                    Label("Review flashcards (\(deck.flashcards.count))", systemImage: "rectangle.stack")
                }
                if !deck.quiz.isEmpty {
                    NavigationLink {
                        QuizView(deck: deck)
                    } label: {
                        Label("Take quiz (\(deck.quiz.count))", systemImage: "checklist")
                    }
                }
            }
        }
        .ogFormStyle()
        .navigationTitle(deck.summary.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
