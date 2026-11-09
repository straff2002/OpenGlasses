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

/// The mic and the buttons button in the tab view's bottom accessory, on the Voice tab only.
///
/// The accessory is Apple's own strip: above the tab bar while it is full size, and beside the
/// Avenkin mark when the bar shrinks as the conversation scrolls — the system moves it into that
/// row with the same motion as the bar, which is the whole reason the controls live here.
struct VoiceDockAccessoryModifier: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content.tabViewBottomAccessory(isEnabled: enabled) {
                VoiceDockAccessory()
            }
        } else {
            content
        }
    }
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
