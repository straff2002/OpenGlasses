import SwiftUI

/// One layout container throughout resizing: the composer and dock never move between branches.
struct WorkspaceRegionLayout: Layout {
    let size: CGSize
    let placement: AdaptiveWorkspacePlacement

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize { size }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = [placement.primary] + (placement.context.map { [$0] } ?? [])
        for (view, frame) in zip(subviews, frames) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                       anchor: .topLeading,
                       proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }
}

@MainActor
final class AdaptiveWorkspaceState: ObservableObject {
    @Published var isExpanded = false
    @Published var section: Section = .job
    @Published var personalSection: PersonalSection = .conversation

    enum PersonalSection: Hashable {
        case conversation
        case myDay
    }

    enum Section: String, CaseIterable, Identifiable {
        case job = "Job"
        case reference = "Reference"
        case evidence = "Evidence"
        var id: Self { self }
    }
}

/// The context pane shares the existing job, evidence, manual and conversation implementations.
/// None of these views owns a voice, camera or Field Assist session.
struct AdaptiveWorkspaceContext: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var workspace: AdaptiveWorkspaceState
    @Environment(\.appAccent) private var accent
    let showsJobs: Bool
    let showsMyDay: Bool
    let hasUnfinishedJob: Bool

    var body: some View {
        VStack(spacing: 0) {
            if showsJobs {
                Picker("Job context", selection: $workspace.section) {
                    Text("Job").tag(AdaptiveWorkspaceState.Section.job)
                    Text("Reference").tag(AdaptiveWorkspaceState.Section.reference)
                    Text("Evidence").tag(AdaptiveWorkspaceState.Section.evidence)
                }
                .pickerStyle(.segmented)
                .padding(12)

                ZStack {
                    // Keep one job page alive when switching to a reference. Its reference draft,
                    // evidence selection, and closing/sign-off flow must not be recreated.
                    JobTab(embedded: true, focusesEvidence: workspace.section == .evidence)
                        .opacity(workspace.section == .reference ? 0 : 1)
                        .allowsHitTesting(workspace.section != .reference)
                        .accessibilityHidden(workspace.section == .reference)
                    if workspace.section == .reference { reference }
                }
            } else if appState.manualFigureRequest != nil {
                reference
            } else {
                personalContext
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // This pane is already inside the root tab view's usable bounds. Give its scroll
        // content local margins rather than inheriting the outer vertical navigation rail's
        // trailing content margin a second time (including inside embedded navigation stacks).
        .contentMargins(.horizontal, 16, for: .scrollContent)
        .background(OGTheme.canvas, in: RoundedRectangle(cornerRadius: 20))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .tint(accent)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("adaptive-workspace-context")
        .onChange(of: showsMyDay) { _, available in
            if !available { workspace.personalSection = .conversation }
        }
    }

    @ViewBuilder
    private var personalContext: some View {
        if hasUnfinishedJob {
            Button {
                appState.openJobs(.currentJob)
            } label: {
                Label("Open unfinished job", systemImage: "arrow.uturn.backward")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .accessibilityIdentifier("adaptive-workspace-open-job")
        }

        if showsMyDay {
            Picker("Personal context", selection: $workspace.personalSection) {
                Text("Conversation").tag(AdaptiveWorkspaceState.PersonalSection.conversation)
                Text("My Day").tag(AdaptiveWorkspaceState.PersonalSection.myDay)
            }
            .pickerStyle(.segmented)
            .padding(12)
        }

        if showsMyDay && workspace.personalSection == .myDay {
            ScrollView {
                MyDayHomeView(service: appState.myDayService, compact: false,
                              onRemoveFromHome: {
                    UserDefaults.standard.set(false, forKey: MyDayHomePlacement.onHomeKey)
                })
                .padding(12)
            }
            .accessibilityIdentifier("adaptive-workspace-my-day")
        } else {
            VStack(spacing: 8) {
                ConversationPageHeader(store: appState.conversationStore)
                ConversationPageBody(store: appState.conversationStore,
                                     session: appState.geminiLiveSession,
                                     openAISession: appState.openAIRealtimeSession)
            }
            .padding(12)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("adaptive-workspace-conversation")
        }
    }

    @ViewBuilder
    private var reference: some View {
        if let request = appState.manualFigureRequest {
            ManualFigureSheet(request: request, onClose: {
                appState.manualFigureRequest = nil
                workspace.section = .job
            })
        } else {
            ContentUnavailableView {
                Label("Reference", systemImage: "book.closed")
            } description: {
                Text("Open a cited manual page to read it beside the conversation.")
            } actions: {
                Button("Browse Field Assist manuals") { appState.requestedTab = .modes }
            }
        }
    }
}

/// A manual's source and page survive moving between the compact sheet and expanded pane.
/// Controllers are shared rather than reconstructed from the original citation on rotation.
@MainActor
final class ManualFigurePresentation: ObservableObject {
    @Published private var indices: [String: Int] = [:]
    private var controllers: [String: [Int: ManualPageController]] = [:]
    private weak var session: FieldSessionService?

    convenience init() {
        self.init(session: .shared)
    }

    init(session: FieldSessionService?) {
        self.session = session
    }

    func index(for request: AppState.ManualFigureRequest) -> Int {
        min(max(0, indices[request.id] ?? request.opening), request.stops.count - 1)
    }

    func select(_ index: Int, in request: AppState.ManualFigureRequest) {
        indices[request.id] = min(max(0, index), request.stops.count - 1)
    }

    func controller(for request: AppState.ManualFigureRequest, at index: Int) -> ManualPageController {
        if let controller = controllers[request.id]?[index] { return controller }
        let stop = request.stops[index]
        let controller = ManualPageController(model: stop.sheet, session: session,
                                              origin: stop.presenter.figure.origin)
        controllers[request.id, default: [:]][index] = controller
        return controller
    }

    func reset() {
        controllers.removeAll()
        indices.removeAll()
    }
}
