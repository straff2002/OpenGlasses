import SwiftUI

/// Live hints' two phone surfaces before P2's session screen (Plan MO §10): the one-line notice a
/// session shows at every start (and when it stops itself), and the first-run sheet, shown once,
/// that says where the audio goes and that nothing is kept. Invisible otherwise.
struct LiveHintsNoticeOverlay: View {
    @ObservedObject var service: LiveHintsService

    var body: some View {
        VStack {
            if let notice = service.notice {
                LiveHintsNoticeBanner(text: notice)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: notice) {
                        try? await Task.sleep(nanoseconds: UInt64(HintLimits.captureNoticeDuration * 1_000_000_000))
                        if service.notice == notice { service.dismissNotice() }
                    }
            }
            Spacer(minLength: 0)
        }
        .animation(.easeInOut(duration: 0.25), value: service.notice)
        .allowsHitTesting(false)
        .sheet(isPresented: Binding(get: { service.firstRunPending },
                                    set: { if !$0 { service.dismissFirstRun() } })) {
            LiveHintsFirstRunSheet(service: service)
        }
    }
}

/// The notice line.
private struct LiveHintsNoticeBanner: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "ear")
            .font(.subheadline)
            .fixedSize(horizontal: false, vertical: true)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal)
            .padding(.top, 8)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isStaticText)
    }
}

/// Shown once, at the first start ever: where audio goes for each path, what goes to a model, and
/// that nothing is kept. **Start live hints** starts the session and is not asked again; **Not now**
/// closes it and it shows at the next start; **Turn off live hints** switches the feature off
/// (`Config.liveHintsEnabled`, the inventory's switch for `AIFeature.liveHints`).
struct LiveHintsFirstRunSheet: View {
    @ObservedObject var service: LiveHintsService

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(LiveHintsCopy.firstRunAudio)
                    Text(LiveHintsCopy.firstRunQuestions)
                    Text(LiveHintsCopy.firstRunKept)
                    Text(LiveHintsCopy.firstRunPeople)
                        .font(.body.weight(.semibold))
                    VStack(spacing: 10) {
                        Button {
                            service.acknowledgeFirstRun()
                        } label: {
                            Text(LiveHintsCopy.firstRunContinue).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        Button {
                            service.dismissFirstRun()
                        } label: {
                            Text(LiveHintsCopy.firstRunCancel).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        Button(role: .destructive) {
                            Config.liveHintsEnabled = false
                            service.dismissFirstRun()
                        } label: {
                            Text(LiveHintsCopy.firstRunTurnOff).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.top, 8)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding()
            }
            .navigationTitle(LiveHintsCopy.firstRunTitle)
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.large])
    }
}
