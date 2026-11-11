import SwiftUI

/// What the Voice tab and the strip at the bottom of the screen share: which of the conversation and
/// the buttons is up, whether the typed bar is open, and whether a reply arrived behind the buttons.
///
/// It lives above the tab view because the mic and the buttons button sit in the tab view's bottom
/// accessory (`VoiceDockAccessory`), which belongs to the tab view and not to the Voice tab — so
/// the state both of them act on cannot be the tab's own.
@MainActor
final class VoiceDockModel: ObservableObject {
    @Published var pager = DockPagerState()
    @Published var showChatInput = false
    /// A reply came in while the buttons were up and the conversation has not been shown since.
    @Published var unseenReply = false

    /// Whether the controls ride in the tab view's bottom accessory. The accessory can only be
    /// switched on and off per tab from iOS 26.1; on 26.0 the Voice tab floats them itself.
    static var usesSystemAccessory: Bool {
        if #available(iOS 26.1, *) { return true }
        return false
    }
}

/// What the tabs and the bottom strip share (Plan KY): the facts that decide each tab's strip, and
/// the strip's last tap for the tab that acts on it.
///
/// Jobs are opened through `AppState.openJobs`, which any surface can call; the other actions need
/// state only their tab holds (History's stack and its leave-the-job question, Field Assist's
/// shelf, the persona sheet), so the strip posts a request and that tab takes it.
@MainActor
final class TabStripModel: ObservableObject {
    @Published var facts = TabStripFacts()
    @Published private(set) var request: TabStripRequest?

    func send(_ lead: TabStripLead) { request = TabStripRequest(lead: lead) }

    /// Clears and returns true when the pending request is `lead` — the tab that answers it calls
    /// this, so a request is acted on once.
    func take(_ lead: TabStripLead) -> Bool {
        guard request?.lead == lead else { return false }
        request = nil
        return true
    }
}

/// One tap on a tab's strip action. Identified, so the same action twice is two requests.
struct TabStripRequest: Equatable {
    let lead: TabStripLead
    let id = UUID()
}

/// The bottom strip in the tab view's accessory, on every tab (Plans KX, KY).
///
/// The accessory is Apple's own strip: above the tab bar while it is full size, and beside the
/// shrunk tab bar when a tab's content scrolls — the system moves it into that row with the same
/// motion as the bar, which is the whole reason the controls live here. Avenkin's strip is the mic,
/// the buttons button and typing; every other tab's is the mic and that tab's own action.
struct TabStripAccessoryModifier: ViewModifier {
    let enabled: Bool
    let tab: MainTab
    let facts: TabStripFacts

    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content.tabViewBottomAccessory(isEnabled: enabled) {
                if tab == .voice {
                    VoiceDockAccessory()
                } else {
                    TabStripAccessory(lead: TabStripPolicy.lead(for: tab, facts: facts),
                                      modeName: facts.activeModeName)
                }
            }
        } else {
            content
        }
    }
}

/// Another tab's strip: its own action, then the mic.
struct TabStripAccessory: View {
    let lead: TabStripLead?
    let modeName: String?
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var dock: VoiceDockModel
    @EnvironmentObject private var strip: TabStripModel
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        LiveVoiceState(session: appState.geminiLiveSession,
                       openAISession: appState.openAIRealtimeSession,
                       speech: appState.speechService) { voiceState in
            BottomControlBar(
                session: appState.geminiLiveSession,
                openAISession: appState.openAIRealtimeSession,
                showSettings: .constant(false),
                showModelPicker: .constant(false),
                showPreview: .constant(false),
                voiceState: voiceState,
                accessoryPlacement: placement ?? .expanded,
                tabLead: lead.map { lead in
                    TabStripLeadControl(lead: lead, title: lead.title(modeName: modeName)) { run(lead) }
                },
                isHomeTab: false,
                pager: $dock.pager
            )
        }
    }

    private func run(_ lead: TabStripLead) {
        switch lead {
        case .newJob: appState.openJobs(.newJob)
        case .openJob: appState.openJobs(.currentJob)
        case .newConversation, .askManual, .activeMode: strip.send(lead)
        }
    }
}

/// A tab's strip action as the control row draws it.
struct TabStripLeadControl {
    let lead: TabStripLead
    let title: String
    let action: () -> Void
}

/// The accessory's content: the dock's control row in its accessory form.
struct VoiceDockAccessory: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var dock: VoiceDockModel
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        LiveVoiceState(session: appState.geminiLiveSession,
                       openAISession: appState.openAIRealtimeSession,
                       speech: appState.speechService) { voiceState in
            BottomControlBar(
                session: appState.geminiLiveSession,
                openAISession: appState.openAIRealtimeSession,
                showSettings: .constant(false),
                showModelPicker: .constant(false),
                showPreview: .constant(false),
                showChatInput: $dock.showChatInput,
                showsActions: HomeSurfaceVisibility.showsActionTiles(mode: appState.currentMode),
                voiceState: voiceState,
                accessoryPlacement: placement ?? .expanded,
                unseenReply: dock.unseenReply,
                pager: $dock.pager
            )
        }
    }
}

/// The session's visual state for a view outside the Voice tab — the same fusion
/// `VoiceVisualState.from` makes there, without the playback metering the tab's ambience drives.
struct LiveVoiceState<Content: View>: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var session: GeminiLiveSessionManager
    @ObservedObject var openAISession: OpenAIRealtimeSessionManager
    @ObservedObject var speech: TextToSpeechService
    @ViewBuilder var content: (VoiceVisualState) -> Content

    var body: some View {
        content(VoiceVisualState.from(
            isSpeaking: speech.isSpeaking || session.isModelSpeaking || openAISession.isModelSpeaking,
            isProcessing: appState.isProcessing,
            isListening: appState.isListening,
            realtimeActive: session.isActive || openAISession.isActive))
    }
}
