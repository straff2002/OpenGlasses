import SwiftUI

/// The phone page of the band check (Plan KP §5): start it, follow it live (the same dots the lens
/// shows), stop it, and see the last run's result — the one the support report carries.
struct BandPracticeView: View {
    @ObservedObject var session: BandPracticeSession

    var body: some View {
        Form {
            Section {
                if let run = session.practice {
                    ForEach(Array(run.lessons.enumerated()), id: \.offset) { index, lesson in
                        lessonRow(run, index: index, lesson: lesson)
                    }
                    if run.isFinished {
                        Label("All lessons passed. Press Done on the glasses.", systemImage: "checkmark.seal")
                    }
                    let wrong = run.wrong.reduce(0, +)
                    if wrong > 0 {
                        Text(String(localized: "Wrong presses: \(wrong)"))
                            .foregroundStyle(.secondary)
                    }
                    Button(role: .destructive) {
                        session.stop()
                    } label: {
                        Label("Stop", systemImage: "stop.circle")
                    }
                } else {
                    Button {
                        session.start()
                    } label: {
                        Label("Start on the glasses", systemImage: "hand.tap")
                    }
                    if let refusal = session.refusal {
                        Label(refusal.message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(OGTheme.warnLabel)
                    }
                }
            } header: {
                Text("Practise the band")
            } footer: {
                Text("Three short lessons on the in-lens display: press one button, press the marked one of two, then press six buttons in order. Each press plays a tick. It shows whether the Neural Band reaches every button.")
            }

            if let result = session.lastResult {
                Section {
                    LabeledContent("Lessons passed", value: "\(result.lessonsPassed) / \(result.lessons.count)")
                    LabeledContent("Presses that didn't arrive", value: "\(result.pressesNotArrived)")
                    LabeledContent("Wrong presses", value: "\(result.wrongPresses)")
                    LabeledContent("Time between presses", value: BandCheckReport.intervalSummary(result.intervalsMs))
                    LabeledContent("Ended", value: result.endedAt.formatted(date: .abbreviated, time: .shortened))
                } header: {
                    Text("Last run")
                } footer: {
                    Text("The last run goes into your support report.")
                }
            }
        }
        .navigationTitle(Text("Practise the band"))
        .ogFormStyle()
    }

    @ViewBuilder
    private func lessonRow(_ run: BandPractice, index: Int, lesson: BandLesson) -> some View {
        HStack {
            Text(lesson.title)
            Spacer()
            if index < run.lessonIndex {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(OGTheme.okLabel)
                    .accessibilityLabel(Text("Passed"))
            } else if index == run.lessonIndex {
                Text(BandPracticeCardBuilder.dots(filled: run.step, of: lesson.requiredPresses))
                    .monospaced()
                    .accessibilityLabel(Text(String(localized: "\(run.step) of \(lesson.requiredPresses) presses")))
            } else {
                Text(BandPracticeCardBuilder.dots(filled: 0, of: lesson.requiredPresses))
                    .monospaced()
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
    }
}
