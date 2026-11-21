import SwiftUI

/// The phone page of the lens fit check (Plan MU §0): put the check on the glasses, then pick what
/// the wearer saw — the highest number read whole on the ruler, and how many of the three boxes
/// showed. The reading is kept for these glasses and sets how much every picture is shrunk before
/// it is sent; it also goes into the support report.
struct LensFitCheckView: View {
    @ObservedObject var session: LensFitCheckSession
    @State private var highest = LensPictureScale.fullReading
    @State private var tiles = LensFitCheck.tileCount

    var body: some View {
        Form {
            Section {
                if session.isRunning {
                    Picker(selection: $highest) {
                        ForEach((1...LensPictureScale.fullReading).reversed(), id: \.self) { number in
                            Text("\(number)").tag(number)
                        }
                    } label: {
                        Text("Highest number read whole")
                    }
                    Picker(selection: $tiles) {
                        ForEach((0...LensFitCheck.tileCount).reversed(), id: \.self) { count in
                            Text("\(count)").tag(count)
                        }
                    } label: {
                        Text("Boxes seen")
                    }
                    Button {
                        session.record(highest: highest, tiles: tiles)
                    } label: {
                        Label("Save the reading", systemImage: "checkmark.circle")
                    }
                    Button(role: .cancel) {
                        session.stop()
                    } label: {
                        Label("Stop", systemImage: "stop.circle")
                    }
                } else {
                    Button {
                        session.start()
                    } label: {
                        Label("Show on the glasses", systemImage: "ruler")
                    }
                    if let refusal = session.refusal {
                        Label(refusal.message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(OGTheme.warnLabel)
                    }
                }
            } header: {
                Text("Fit check")
            } footer: {
                Text("The display shows a ruler numbered 1 to 12 and, under it, three numbered boxes. Pick, or say, the highest number you can read whole and how many boxes you see. Twelve and three means pictures fit the lens as drawn.")
            }

            if let reading = session.lastReading {
                Section {
                    LabeledContent("Highest number read", value: "\(reading.highestNumber) / \(LensPictureScale.fullReading)")
                    LabeledContent("Boxes seen", value: "\(reading.tilesSeen) / \(LensFitCheck.tileCount)")
                    LabeledContent("Pictures shrunk by", value: "×\(LensPictureScale.factorText(reading.factor))")
                } header: {
                    Text("Last reading for these glasses")
                } footer: {
                    Text("Every picture sent to the display is made smaller by this much so it fits. The reading goes into your support report.")
                }
            }
        }
        .navigationTitle(Text("Fit check"))
        .ogFormStyle()
        .onAppear { session.refresh() }
    }
}
