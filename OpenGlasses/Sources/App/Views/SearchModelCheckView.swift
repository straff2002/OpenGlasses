import SwiftUI

/// Developer → Search Model Check: runs `SearchModelPhoneCheck` on this phone and shows its counts
/// and timings. The model and its files are copied in by hand; nothing here downloads anything.
struct SearchModelCheckView: View {
    @State private var lines: [String] = []
    @State private var running = false

    private var missing: [String] { SearchModelPhoneCheck.missingFiles() }

    var body: some View {
        OGScrollPage {
            OGSection(
                header: "Search Model Check",
                footer: "Checks whether the search-trained embedding model runs well on this iPhone: load time, speed, memory, and whether its vectors match the reference. It runs on the CPU only. The model files are copied into the app's Documents folder, in search-model-check, from a Mac."
            ) {
                Button {
                    run { try await SearchModelPhoneCheck.run() }
                } label: {
                    OGRow("Run the check", icon: "gauge.with.dots.needle.67percent", showsChevron: false) {
                        EmptyView()
                    }
                }
                .buttonStyle(.plain)
                .disabled(running || !missing.isEmpty)
                OGDivider()
                Button {
                    run { await SearchModelPhoneCheck.runOneQuestionLater() }
                } label: {
                    OGRow("Embed one question in 15 seconds", icon: "lock",
                          subtitle: "Lock the phone straight after tapping",
                          showsChevron: false) {
                        EmptyView()
                    }
                }
                .buttonStyle(.plain)
                .disabled(running || !missing.isEmpty)
            }

            OGSection(header: "Result") {
                VStack(alignment: .leading, spacing: 3) {
                    if !missing.isEmpty {
                        Text(verbatim: "Missing: " + missing.joined(separator: ", "))
                    } else if running {
                        Text("Running…")
                    } else if lines.isEmpty {
                        Text("Not run yet.")
                    }
                    ForEach(lines, id: \.self) { line in
                        Text(verbatim: line)
                    }
                }
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .textSelection(.enabled)

                if !lines.isEmpty {
                    OGDivider()
                    Button {
                        UIPasteboard.general.string = lines.joined(separator: "\n")
                    } label: {
                        OGRow("Copy Result", icon: "doc.on.doc", mutedIcon: true, showsChevron: false) {
                            EmptyView()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("Search Model Check")
    }

    private func run(_ work: @escaping () async throws -> [String]) {
        running = true
        lines = []
        Task {
            let result: [String]
            do { result = try await work() } catch { result = ["failed: \(String(describing: error))"] }
            lines = result
            running = false
            let file = SearchModelPhoneCheck.folder.appendingPathComponent("result.txt")
            let stamped = (["\(Date())"] + result).joined(separator: "\n") + "\n\n"
            if let handle = try? FileHandle(forWritingTo: file) {
                handle.seekToEndOfFile()
                handle.write(Data(stamped.utf8))
                try? handle.close()
            } else {
                try? stamped.write(to: file, atomically: true, encoding: .utf8)
            }
        }
    }
}
