import SwiftUI
import UIKit

/// Plan MQ P3's device qualification app. It starts measuring as soon as it launches, keeps the
/// screen awake, stops generating when it leaves the foreground, and writes Documents/results.json
/// after every case (counts and hashes only). See README.md.
@main
struct LocalModelQualificationApp: App {
    @StateObject private var runner = QualificationRunner()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            VStack(alignment: .leading, spacing: 12) {
                Text("Local model qualification").font(.headline)
                Text(runner.options.apple ? "Apple on-device model" : runner.options.modelID)
                    .font(.subheadline).foregroundStyle(.secondary)
                Text(runner.status)
                if runner.total > 0 {
                    ProgressView(value: Double(runner.completed), total: Double(runner.total))
                    Text("\(runner.completed) of \(runner.total) runs, \(runner.passed) passed")
                        .font(.footnote).monospacedDigit()
                }
                Text("Keep this app in the foreground, on a charger. Leaving it stops the run; relaunching carries on.")
                    .font(.footnote).foregroundStyle(.secondary)
                Spacer()
            }
            .padding()
            .onAppear { runner.start() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                runner.resignActive()
            }
            .onChange(of: phase) { _, newPhase in
                if newPhase == .active, !runner.isRunning { runner.start() }
            }
        }
    }
}
