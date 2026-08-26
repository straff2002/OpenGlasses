import SwiftUI

/// On-phone quiz (docs/plans/study-mode.md) — self-contained, scored with the pure `QuizGrader` (the
/// same grader the voice path uses). Tap an option for immediate feedback, then advance; a summary with
/// the missed questions is shown at the end.
struct QuizView: View {
    let deck: StudyDeck
    @Environment(\.dismiss) private var dismiss

    @State private var index = 0
    @State private var answers: [String: String] = [:]
    @State private var selected: String?
    @State private var result: QuizResult?

    private let grader = QuizGrader()

    var body: some View {
        VStack(spacing: 20) {
            if let result {
                completion(result)
            } else if index < deck.quiz.count {
                question(deck.quiz[index])
            }
        }
        .padding()
        .navigationTitle("Quiz")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func question(_ q: QuizQuestion) -> some View {
        Text("Question \(index + 1) of \(deck.quiz.count)")
            .font(.caption).foregroundStyle(.secondary)
        Text(q.prompt).font(.title3.weight(.semibold)).multilineTextAlignment(.center)

        ForEach(q.options) { option in
            Button { select(option, in: q) } label: {
                HStack {
                    Text(option.text)
                    Spacer()
                    // Once answered, mark the correct option even if it wasn't the one
                    // tapped — colour alone (green vs. red) isn't enough of a signal.
                    if selected != nil {
                        if option.id == q.correctOptionID {
                            Image(systemName: "checkmark.circle.fill")
                        } else if selected == option.id {
                            Image(systemName: "xmark.circle.fill")
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(optionColor(option, q), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(selected != nil)
        }

        if selected != nil {
            Button(index == deck.quiz.count - 1 ? "Finish" : "Next", action: advance)
                .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private func completion(_ result: QuizResult) -> some View {
        ContentUnavailableView {
            Label("Quiz complete", systemImage: "checkmark.seal.fill")
        } description: {
            Text("You scored \(result.correct)/\(result.total) (\(Int(result.percentage.rounded()))%)")
        }
        if !result.missed.isEmpty {
            List(result.missed) { q in
                VStack(alignment: .leading, spacing: 2) {
                    Text(q.prompt).font(.subheadline)
                    if let correct = q.correctOption {
                        Text(correct.text).font(.caption).foregroundStyle(OGTheme.okLabel)
                    }
                }
            }
        }
        Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
    }

    // MARK: - Logic

    private func select(_ option: QuizOption, in q: QuizQuestion) {
        guard selected == nil else { return }
        selected = option.id
        answers[q.id] = option.id
    }

    private func advance() {
        selected = nil
        if index < deck.quiz.count - 1 {
            index += 1
        } else {
            result = grader.grade(deck.quiz, answers: answers)
        }
    }

    private func optionColor(_ option: QuizOption, _ q: QuizQuestion) -> Color {
        guard selected != nil else { return Color.gray.opacity(0.12) }
        if option.id == q.correctOptionID { return OGTheme.ok.opacity(0.25) }
        if option.id == selected { return OGTheme.error.opacity(0.25) }
        return Color.gray.opacity(0.12)
    }
}
