import SwiftUI

/// The words under **Keep caption sessions** (Plan KP §7). Captions record other people's speech,
/// so the footer says plainly what is kept, for how long, where, and that the people speaking may
/// need to agree.
enum CaptionSessionsCopy {

    static var footer: String {
        String(localized: "Keeps a transcript of each captions or translation session when it stops: the time of each line, what was said, its translation, and the speaker's name where one was labelled. Sessions stay on this phone, are deleted seven days after they began, and go nowhere unless you share one. Captions record other people's speech, so the people speaking may need to agree before you keep it.")
    }

    static var complianceModeFooter: String {
        String(localized: "Off in Medical Compliance mode: caption sessions are never kept while it's on.")
    }
}

/// **Keep caption sessions**, the sessions kept, and **Delete all** (Plan KP P5). Reached from
/// Devices & Privacy › What You Keep, beside Recordings and Meeting Records; captions run on the
/// phone with or without glasses, so this is not under the glasses.
struct CaptionSessionsView: View {
    @ObservedObject private var store: CaptionSessionStore
    // Redraw when either key is written, here or elsewhere; the values are read through `Config`.
    @AppStorage("hipaaMode") private var hipaaMode = false
    @AppStorage(Config.keepCaptionSessionsKey) private var keepStored = false
    @State private var confirmingDeleteAll = false

    init(store: CaptionSessionStore? = nil) {
        _store = ObservedObject(wrappedValue: store ?? .shared)
    }

    private var keep: Binding<Bool> {
        Binding(get: { keepStored && !hipaaMode },
                set: { keepStored = Config.setKeepCaptionSessions($0) })
    }

    var body: some View {
        Form {
            Section {
                Toggle(String(localized: "Keep Caption Sessions"), isOn: keep)
                    .disabled(hipaaMode)
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(CaptionSessionsCopy.footer)
                    if hipaaMode {
                        Text(CaptionSessionsCopy.complianceModeFooter)
                    }
                }
            }

            Section {
                if store.sessions.isEmpty {
                    Text(String(localized: "No sessions kept."))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.sessions) { session in
                        NavigationLink {
                            CaptionSessionTranscriptView(session: session)
                        } label: {
                            CaptionSessionRow(session: session)
                        }
                    }
                    .onDelete { offsets in
                        offsets.map { store.sessions[$0].id }.forEach { store.delete(id: $0) }
                    }
                }
            } header: {
                Text(String(localized: "Sessions"))
            }

            if !store.sessions.isEmpty {
                Section {
                    Button(String(localized: "Delete All"), role: .destructive) {
                        confirmingDeleteAll = true
                    }
                }
            }
        }
        .navigationTitle(String(localized: "Caption Sessions"))
        .onAppear {
            store.pruneExpired()
            store.reload()
        }
        .confirmationDialog(String(localized: "Delete every kept caption session?"),
                            isPresented: $confirmingDeleteAll, titleVisibility: .visible) {
            Button(String(localized: "Delete All"), role: .destructive) { store.deleteAll() }
            Button(String(localized: "Cancel"), role: .cancel) {}
        }
    }
}

/// One kept session in the list: when it began, how long it ran, how many lines.
private struct CaptionSessionRow: View {
    let session: CaptionSession

    private var detail: String {
        let minutes = max(1, Int((session.endedAt.timeIntervalSince(session.startedAt) / 60).rounded()))
        let lines = session.turns.count
        return session.translated
            ? String(localized: "\(minutes) min, \(lines) lines, translated")
            : String(localized: "\(minutes) min, \(lines) lines")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A kept session as a transcript: one turn per line, its time first, the speaker's name where
/// diarisation labelled it, and the translation under it. **Share** hands the same lines, as plain
/// text, to the share sheet; nothing is sent until the wearer chooses where.
struct CaptionSessionTranscriptView: View {
    let session: CaptionSession

    var body: some View {
        List {
            ForEach(Array(session.turns.enumerated()), id: \.offset) { _, turn in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(CaptionSessionTranscript.time(turn.at))
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.secondary)
                        words(turn)
                    }
                    if let translation = turn.translation {
                        Text(translation)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 56)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .navigationTitle(session.startedAt.formatted(date: .abbreviated, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ShareLink(item: CaptionSessionTranscript.plainText(session),
                          subject: Text(CaptionSessionTranscript.heading(session))) {
                    Label(String(localized: "Share"), systemImage: "square.and.arrow.up")
                }
            }
        }
    }

    private func words(_ turn: CaptionSession.Turn) -> Text {
        guard let speaker = turn.speaker else { return Text(turn.said) }
        return Text("\(Text(speaker).bold()): \(turn.said)")
    }
}
