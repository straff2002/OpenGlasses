import EventKit
import SwiftUI

/// On-demand phone surface for the same deterministic snapshot used by voice and Siri.
struct MyDayView: View {
    @ObservedObject var service: MyDayService
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var cardStore = PreparedCardStore.shared
    @ObservedObject private var styleStore = WritingStyleStore.shared
    @Environment(\.appAccent) private var accent
    @Environment(\.openURL) private var openURL
    @State private var actionMessage: String?
    @AppStorage("preparedCardGoogleLineDismissed") private var googleLineDismissed = false
    /// The card the wearer last cleared, for its Undo (§5.1).
    @State private var lastDismissed: PreparedCard?

    var body: some View {
        NavigationStack {
            OGScrollPage {
                content
            }
            .navigationTitle("My Day")
            .refreshable { _ = await service.refresh() }
            .task {
                if case .idle = service.state { _ = await service.refresh() }
            }
            .alert("My Day", isPresented: Binding(
                get: { actionMessage != nil },
                set: { if !$0 { actionMessage = nil } }
            )) {
                Button("OK") { actionMessage = nil }
            } message: {
                Text(actionMessage ?? "")
            }
        }
        // Plan KT §7.1: this page is a sheet, so a card's composer is presented from here.
        .modifier(DraftComposerHost(appState: appState, onPage: true))
        .onAppear { appState.draftComposerOnPage = true }
        .onDisappear { appState.draftComposerOnPage = false }
        .onChange(of: service.todayFeed.cards.map(\.id), initial: true) { _, _ in
            let cards = service.todayFeed.cards
            guard !cards.isEmpty else { return }
            service.changeCards { $0.noteShown(cards, now: Date()) }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch service.state {
        case .idle:
            loadingCard(previous: nil)
        case .loading(let previous):
            loadingCard(previous: previous)
        case .loaded(let snapshot):
            snapshotContent(snapshot)
        }
    }

    @ViewBuilder
    private func loadingCard(previous: MyDaySnapshot?) -> some View {
        if let previous {
            snapshotContent(previous)
        }
        OGSection {
            HStack(spacing: 12) {
                ProgressView()
                Text(previous == nil ? "Building your day…" : "Refreshing…")
                    .font(.body)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private func snapshotContent(_ snapshot: MyDaySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(snapshot.headline)
                .font(.title2.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(refreshLabel(snapshot))
                .font(.footnote)
                .foregroundStyle(isStale(snapshot) ? OGTheme.warnLabel : .secondary)
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)

        // Plan KT §9.2: once, while Calendar is readable and has no Google calendar in it.
        if service.googleCalendarMissing && !googleLineDismissed {
            OGSection {
                GoogleCalendarLine { googleLineDismissed = true }
            }
        }

        if let kind = service.preparedFeed.turnedOffKind {
            OGSection {
                PreparedCardTurnedOffNotice(
                    kind: kind,
                    onUndo: { service.changeCards { $0.undoTurnOff(kind) } },
                    onClose: { service.changeCards { $0.dismissTurnOffNotice() } })
            }
        }

        // Plan KT §4.3: after three edits of the same kind, one suggested change to the style.
        if let suggestion = styleStore.suggestion, !service.todayFeed.cards.isEmpty {
            OGSection {
                StyleSuggestionLine(suggestion: suggestion, store: styleStore)
                    .padding(16)
            }
        }

        // Plan KT §5.1: cards, then rows. A card replaces the rows it says the same thing as.
        let cardModels = PreparedCardPresentation.page(service.preparedFeed, memory: cardStore.memory,
                                                       now: Date(), calendar: .autoupdatingCurrent)
        ForEach(cardModels) { model in
            if let card = service.card(model.id) {
                let handlers = pageHandlers(for: card)
                OGCard {
                    MyDaySwipeToClear(label: model.headline) {
                        handlers.dismiss()
                    } content: {
                        PreparedCardView(model: model, handlers: handlers)
                    }
                }
                .id(model.id)
            }
        }

        if let dismissed = lastDismissed {
            OGSection {
                HStack(spacing: 12) {
                    Text("Cleared “\(dismissed.headline)”")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button("Undo") {
                        service.changeCards { $0.undo(dismissed.id, now: Date()) }
                        lastDismissed = nil
                    }
                    .buttonStyle(.bordered)
                }
                .padding(16)
            }
        }

        // The whole day, not the card's share of it. This screen is what "See all" opens, so
        // anything the cap held back has to be here — otherwise clearing a row is the only way to
        // discover it existed.
        let absorbed = service.todayFeed.absorbed
        let allItems = snapshot.allItems.filter { !absorbed.contains(CardRowID($0.id)) }
        if allItems.isEmpty && cardModels.isEmpty {
            OGSection {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Nothing urgent", systemImage: "checkmark.circle")
                        .font(.headline)
                    Text("Your available sources have nothing that needs attention right now.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
        } else if !allItems.isEmpty {
            OGSection(header: "Next") {
                ForEach(Array(allItems.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { OGDivider() }
                    MyDaySwipeToClear(label: item.title) {
                        Task { await service.dismiss(item) }
                    } content: {
                        if let goalID = MyDayService.goalID(of: item) {
                            // A goals row opens its goal (Plan IW P2); its complete button marks
                            // the step done.
                            HStack(spacing: 0) {
                                itemRow(item)
                                NavigationLink {
                                    GoalPage(goalID: goalID)
                                } label: {
                                    Image(systemName: "chevron.forward")
                                        .frame(width: OGMetrics.minTouchTarget, height: OGMetrics.minTouchTarget)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(accent)
                                .accessibilityLabel("Open the goal for \(item.title)")
                                .padding(.trailing, 8)
                            }
                        } else {
                            itemRow(item)
                        }
                    }
                }
            }
        }

        let unavailable = snapshot.sourceStates.filter { $0.availability != .available }
        if !unavailable.isEmpty {
            OGSection(header: "Availability") {
                ForEach(Array(unavailable.enumerated()), id: \.element.id) { index, state in
                    if index > 0 { OGDivider() }
                    sourceRow(state)
                }
            }
        }
    }

    /// The shared handlers, with a cleared card remembered for its Undo.
    private func pageHandlers(for card: PreparedCard) -> PreparedCardHandlers {
        var handlers = appState.cardHandlers(for: card)
        let clear = handlers.dismiss
        handlers.dismiss = {
            clear()
            lastDismissed = card
        }
        return handlers
    }

    private func itemRow(_ item: MyDayItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            OGIconTile(systemName: MyDayView.icon(for: item))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.body.weight(item.urgency >= .important ? .semibold : .regular))
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = item.detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Apple requires its Weather credit wherever WeatherKit data is displayed.
                if item.kind == .weather {
                    WeatherAttributionView()
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 8)
            actionButton(for: item)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: OGMetrics.minTouchTarget)
    }

    @ViewBuilder
    private func actionButton(for item: MyDayItem) -> some View {
        if item.actions.contains(.complete) {
            Button {
                Task { await complete(item) }
            } label: {
                Image(systemName: "checkmark.circle")
                    .frame(width: OGMetrics.minTouchTarget, height: OGMetrics.minTouchTarget)
            }
            .buttonStyle(.plain)
            .foregroundStyle(accent)
            .accessibilityLabel(item.id.source == .goals ? "Mark \(item.title) done" : "Complete \(item.title)")
        } else if item.actions.contains(.directions),
                  let url = service.directionsURL(for: item.id) {
            Button {
                service.recordAction(.startDirections)
                openURL(url)
            } label: {
                Image(systemName: "arrow.triangle.turn.up.right.diamond")
                    .frame(width: OGMetrics.minTouchTarget, height: OGMetrics.minTouchTarget)
            }
            .buttonStyle(.plain)
            .foregroundStyle(accent)
            .accessibilityLabel("Start directions for \(item.title)")
        } else if item.actions.contains(.dismiss) {
            Button {
                Task { await service.dismissDigestItem(id: item.id.rawValue) }
            } label: {
                Image(systemName: "xmark.circle")
                    .frame(width: OGMetrics.minTouchTarget, height: OGMetrics.minTouchTarget)
            }
            .buttonStyle(.plain)
            .foregroundStyle(accent)
            .accessibilityLabel("Dismiss \(item.title)")
        } else if item.actions.contains(.open), let dueAt = item.dueAt {
            Button {
                service.recordAction(.openEvent)
                let seconds = dueAt.timeIntervalSinceReferenceDate
                if let url = URL(string: "calshow:\(seconds)") { openURL(url) }
            } label: {
                Image(systemName: "arrow.up.forward.square")
                    .frame(width: OGMetrics.minTouchTarget, height: OGMetrics.minTouchTarget)
            }
            .buttonStyle(.plain)
            .foregroundStyle(accent)
            .accessibilityLabel("Open \(item.title) in Calendar")
        }
    }

    private func sourceRow(_ state: MyDaySourceState) -> some View {
        HStack(spacing: 12) {
            OGIconTile(systemName: state.availability == .denied ? "lock" : "exclamationmark.triangle", muted: true)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.source.displayName)
                    .font(.body)
                Text(state.message ?? String(localized: "This source is unavailable."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if state.availability == .denied {
                Button("Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func complete(_ item: MyDayItem) async {
        do {
            let title = try await service.complete(item)
            if title == nil { actionMessage = MyDayView.goneMessage(for: item) }
        } catch {
            actionMessage = String(localized: "The reminder could not be completed.")
        }
    }


    private func isStale(_ snapshot: MyDaySnapshot) -> Bool {
        guard let refresh = snapshot.nextRefreshAt else { return false }
        return Date() >= refresh
    }

    private func refreshLabel(_ snapshot: MyDaySnapshot) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        let time = formatter.string(from: snapshot.generatedAt)
        return isStale(snapshot)
            ? String(localized: "Stale — pull to refresh \(time)")
            : String(localized: "Updated \(time)")
    }
}

/// Compact home-screen expression of My Day. It replaces the decorative voice waveline with
/// information that is useful before a conversation starts, while keeping the complete review and
/// action surface one tap away.
///
/// Drawn only while My Day is on *and* placed on the home screen (`MyDayHomePlacement`) — there is
/// no set-up card standing in for it when it is off. The card can take itself off the home screen
/// from its context menu; Settings and the home screen's editor put it back.
struct MyDayHomeView: View {
    @ObservedObject var service: MyDayService
    let compact: Bool
    /// Takes the card off the home screen. The caller owns the placement flag and animates the
    /// change, so the panel below takes the height back on the same curve.
    var onRemoveFromHome: () -> Void = {}

    @EnvironmentObject private var appState: AppState
    @ObservedObject private var cardStore = PreparedCardStore.shared
    @Environment(\.appAccent) private var accent
    @Environment(\.openURL) private var openURL
    @State private var showDetail = false

    /// The user's own collapse, remembered across launches. Distinct from `compact`, which the
    /// session state imposes for as long as the mic is open: this one is a choice, so it outranks
    /// the compact form and holds until the user reverses it.
    @AppStorage("myDayCollapsed") private var isCollapsed = false

    /// The whole day, in the card, in place of the three-item summary.
    ///
    /// Deliberately **not** persisted, unlike `isCollapsed`. Collapsing is a standing preference
    /// about how much of the home surface My Day should occupy; expanding is a momentary "show me
    /// the rest", and a card that came back full-height on every launch would be making a lasting
    /// decision out of a glance. It also resets when the card is collapsed, so the chevron always
    /// returns to a card the wearer recognises.
    @State private var isExpanded = false

    /// The result of an item action, which has nowhere else to be said now that the full day is
    /// drawn in the card rather than on a screen with its own alert.
    @State private var actionMessage: String?

    var body: some View {
        enabledCard
        // The long press every home-screen card answers. "Remove" rather than "Turn off": the
        // briefings, the tool and the alerts keep running — only the card leaves.
        .contextMenu {
            Button(role: .destructive) {
                onRemoveFromHome()
            } label: {
                Label("Remove from Home", systemImage: "minus.circle")
            }
        }
        .padding(.horizontal, 16)
        .task {
            if case .idle = service.state { _ = await service.refresh() }
        }
        // The card is meant to be current, and until now nothing made it so: `nextRefreshAt` only
        // ever *labelled* a snapshot stale, and the sole automatic refresh was the first load. Two
        // cheap signals cover the day — coming back to the app, and the calendar changing under it.
        // Both are cheap because a dismissal is persisted, so recomposing often costs the wearer
        // nothing: a cleared row does not come back, and genuinely new information is not delayed.
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.willEnterForegroundNotification)) { _ in
            refreshIfStale()
        }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
            refreshInBackground()
        }
        // The full day is drawn in the card now, so this screen is no longer where "show me the
        // rest" goes. It survives for the one job the card cannot do inline: repairing a source.
        // Those rows carry per-source messages and a Settings deep link, and they are reached from
        // the availability line — the thing they repair — rather than from the expand control.
        .sheet(isPresented: $showDetail) {
            MyDayView(service: service)
        }
        .alert("My Day", isPresented: Binding(
            get: { actionMessage != nil },
            set: { if !$0 { actionMessage = nil } }
        )) {
            Button("OK") { actionMessage = nil }
        } message: {
            Text(actionMessage ?? "")
        }
    }

    /// Completing a reminder from the expanded card — the same call the full screen makes, so an
    /// action that moved to the card did not become a weaker version of itself.
    private func complete(_ item: MyDayItem) async {
        do {
            let title = try await service.complete(item)
            if title == nil { actionMessage = MyDayView.goneMessage(for: item) }
        } catch {
            actionMessage = String(localized: "The reminder could not be completed.")
        }
    }

    /// Only when the snapshot has aged past the interval it advertises — coming back to the app for
    /// five seconds should not re-hit EventKit.
    private func refreshIfStale() {
        if case .loaded(let snapshot) = service.state,
           let next = snapshot.nextRefreshAt, Date() < next { return }
        refreshInBackground()
    }

    /// `channel: nil` — this is the card keeping itself current, not the wearer asking for a
    /// briefing, and the metrics should not read as though they did.
    private func refreshInBackground() {
        // EventKit posts its change notification in bursts; a refresh already in flight is enough.
        if case .loading = service.state { return }
        Task { _ = await service.refresh(channel: nil) }
    }

    private var enabledCard: some View {
        OGCard {
            VStack(spacing: 0) {
                header

                if !isCollapsed {
                    Rectangle()
                        .fill(OGTheme.hairline)
                        .frame(height: 0.5)
                        .accessibilityHidden(true)

                    stateContent
                }
            }
        }
        // Both height changes ride the surface's one settle curve. The panel below does not
        // animate at all — it tracks the height this card reports — so this *is* the motion of
        // the exchange, and the two move as one.
        .animation(DockGridMetrics.heightSettle, value: isCollapsed)
        .animation(DockGridMetrics.heightSettle, value: isExpanded)
    }

    /// The card's one always-present row. Collapsed, it is the whole card — the title, today's
    /// headline if there is one, and the chevron back out. The header itself toggles, because a
    /// 24 pt chevron is a poor target for the gesture people actually reach for.
    private var header: some View {
        HStack(spacing: 8) {
            Label("My Day", systemImage: "sun.max.fill")
                .font(.headline)
                .foregroundStyle(OGTheme.tintedAccentLabel(accent))
                .layoutPriority(1)
                // The context menu's one item, reachable without the long press VoiceOver keeps
                // for itself.
                .accessibilityAction(named: "Remove from Home") { onRemoveFromHome() }

            if isCollapsed, let headline = collapsedHeadline {
                Text(headline)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 8)

            if !isCollapsed {
                Button {
                    Task { _ = await service.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: OGMetrics.minTouchTarget, height: OGMetrics.minTouchTarget)
                }
                .buttonStyle(.plain)
                .foregroundStyle(accent)
                .accessibilityLabel("Refresh My Day")

                // Grows the card in place rather than presenting the day somewhere else. The
                // arrows point the way the card is about to move, which is why this is no longer
                // the "↗" that meant "open elsewhere".
                Button {
                    isExpanded.toggle()
                } label: {
                    Image(systemName: isExpanded
                          ? "arrow.down.right.and.arrow.up.left"
                          : "arrow.up.left.and.arrow.down.right")
                        .frame(width: OGMetrics.minTouchTarget, height: OGMetrics.minTouchTarget)
                }
                .buttonStyle(.plain)
                .foregroundStyle(accent)
                .accessibilityLabel(isExpanded ? "Show the My Day summary"
                                               : "Show the full day in My Day")
                .accessibilityHint(isExpanded
                                   ? "Returns the card to the first few items."
                                   : "Grows the card to today's whole list.")
            }

            Button {
                isCollapsed.toggle()
                // A collapsed card always reopens as the summary it is recognised by — expansion
                // is a glance, not a setting, so it does not survive being put away.
                if isCollapsed { isExpanded = false }
            } label: {
                Image(systemName: "chevron.down")
                    .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                    .frame(width: OGMetrics.minTouchTarget, height: OGMetrics.minTouchTarget)
            }
            .buttonStyle(.plain)
            .foregroundStyle(accent)
            .accessibilityLabel(isCollapsed ? "Expand My Day" : "Collapse My Day")
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        // The row's empty space toggles too, but only the empty space: `contentShape` on the HStack
        // would swallow the buttons beside it, so the gesture rides the background instead.
        .background(
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    isCollapsed.toggle()
                    if isCollapsed { isExpanded = false }
                }
        )
    }

    /// The one line a collapsed card can still afford. Only when the snapshot is loaded — a
    /// collapsed card should never be the place a "Building your day…" spinner hides.
    private var collapsedHeadline: String? {
        guard case .loaded(let snapshot) = service.state else { return nil }
        return snapshot.headline
    }

    @ViewBuilder
    private var stateContent: some View {
        switch service.state {
        case .idle:
            progressRow("Building your day…")
        case .loading(let previous):
            if let previous {
                snapshotContent(previous)
                progressRow("Refreshing…")
            } else {
                progressRow("Building your day…")
            }
        case .loaded(let snapshot):
            snapshotContent(snapshot)
        }
    }

    @ViewBuilder
    private func snapshotContent(_ snapshot: MyDaySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(snapshot.headline)
                .font(.body.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)

            // Plan KT §5.2: the top card, compact, and "N more ready". With no cards this is the
            // card it always was.
            let home = PreparedCardHomeModel.make(service.preparedFeed, memory: cardStore.memory,
                                                  now: Date(), calendar: .autoupdatingCurrent)
            if let top = home.top, let card = service.card(top.id) {
                PreparedCardCompactView(home: home, handlers: appState.cardHandlers(for: card)) {
                    showDetail = true
                }
            }

            // Rows a card already says are left to the card.
            let absorbed = service.todayFeed.absorbed
            let dayItems = snapshot.items.filter { !absorbed.contains(CardRowID($0.id)) }
            let wholeDay = snapshot.allItems.filter { !absorbed.contains(CardRowID($0.id)) }

            if dayItems.isEmpty && home.top == nil {
                Label("Nothing urgent", systemImage: "checkmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                // Expanded, the card *is* the full day — the whole list, not the card's share of
                // it, which is what the modal used to be for.
                let visibleItems = isExpanded && !compact
                    ? wholeDay
                    : Array(dayItems.prefix(home.top == nil ? (compact ? 1 : 3) : (compact ? 0 : 2)))
                ForEach(visibleItems) { item in
                    MyDaySwipeToClear(label: item.title) {
                        Task { await service.dismiss(item) }
                    } content: {
                        HStack(alignment: .top, spacing: 10) {
                            Button {
                                // Tapping a row is "show me more", which now happens here rather
                                // than by leaving for a screen. Already expanded, the row's own
                                // action button is the thing to press, so this settles to a no-op.
                                isExpanded = true
                            } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: MyDayView.icon(for: item))
                                        .foregroundStyle(OGTheme.tintedAccentLabel(accent))
                                        .frame(width: 20)
                                        .accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.title)
                                            .font(.footnote.weight(item.urgency >= .important ? .semibold : .regular))
                                            .foregroundStyle(.primary)
                                            .fixedSize(horizontal: false, vertical: true)
                                        if !compact, let detail = item.detail {
                                            Text(detail)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                    Spacer(minLength: 4)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(isExpanded)
                            // The detail carries which Reminders list a task came from, and the
                            // compact card does not draw it — so it is spoken explicitly rather
                            // than left to whatever happened to be rendered.
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel([item.title, item.detail]
                                .compactMap { $0 }
                                .joined(separator: ", "))
                            .accessibilityAddTraits(isExpanded ? [] : .isButton)
                            .accessibilityHint(isExpanded ? "" : "Shows the full day in the card.")

                            // Expanded, each row carries the action the full screen used to own —
                            // completing a reminder, directions, opening an event. Moving the list
                            // into the card without these would have made "in place" a downgrade.
                            if isExpanded && !compact {
                                actionButton(for: item)
                            }
                        }
                    }
                }

                // Apple requires its Weather credit wherever WeatherKit data is displayed. The
                // compact card draws titles only, so the forecast itself is not on screen there.
                // Outside the rows, because a link inside a row's button could not be tapped.
                if !compact, visibleItems.contains(where: { $0.kind == .weather }) {
                    WeatherAttributionView()
                        .padding(.leading, 30)
                }

                // Counts the whole day, not the capped list. It used to count `items`, which is
                // what the cap left — so a row that arrived when another was cleared looked like
                // it had materialised, when it had been on the list the whole time and nothing on
                // screen could say so.
                let total = wholeDay.count
                if !compact, !isExpanded, total > visibleItems.count {
                    Button("See all \(total) items") {
                        isExpanded = true
                    }
                    .font(.footnote.weight(.semibold))
                    .accessibilityHint("Grows the card to today's whole list. \(total - visibleItems.count) more than the card shows.")
                }
            }

            if !compact {
                let unavailableCount = snapshot.sourceStates.filter {
                    $0.availability != .available
                }.count
                if unavailableCount > 0 {
                    // The one thing the card still sends elsewhere, and the only reason the full
                    // screen survives: repairing a source needs its own message and a Settings
                    // deep link per source. Reached from the line that reports the problem, which
                    // is where a wearer looks for it — not from the expand control.
                    Button {
                        showDetail = true
                    } label: {
                        Label(
                            unavailableCount == 1 ? "1 source needs attention" : "\(unavailableCount) sources need attention",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the sources that need attention.")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// The action a row carries once the card is expanded — the same set, and the same calls, the
    /// full screen offers. Ported rather than reimplemented so "in place" costs the wearer nothing.
    @ViewBuilder
    private func actionButton(for item: MyDayItem) -> some View {
        if item.actions.contains(.complete) {
            Button {
                Task { await complete(item) }
            } label: {
                Image(systemName: "checkmark.circle")
                    .frame(width: OGMetrics.minTouchTarget, height: OGMetrics.minTouchTarget)
            }
            .buttonStyle(.plain)
            .foregroundStyle(accent)
            .accessibilityLabel(item.id.source == .goals ? "Mark \(item.title) done" : "Complete \(item.title)")
        } else if item.actions.contains(.directions),
                  let url = service.directionsURL(for: item.id) {
            Button {
                service.recordAction(.startDirections)
                openURL(url)
            } label: {
                Image(systemName: "arrow.triangle.turn.up.right.diamond")
                    .frame(width: OGMetrics.minTouchTarget, height: OGMetrics.minTouchTarget)
            }
            .buttonStyle(.plain)
            .foregroundStyle(accent)
            .accessibilityLabel("Start directions for \(item.title)")
        } else if item.actions.contains(.dismiss) {
            Button {
                Task { await service.dismissDigestItem(id: item.id.rawValue) }
            } label: {
                Image(systemName: "xmark.circle")
                    .frame(width: OGMetrics.minTouchTarget, height: OGMetrics.minTouchTarget)
            }
            .buttonStyle(.plain)
            .foregroundStyle(accent)
            .accessibilityLabel("Dismiss \(item.title)")
        } else if item.actions.contains(.open), let dueAt = item.dueAt {
            Button {
                service.recordAction(.openEvent)
                let seconds = dueAt.timeIntervalSinceReferenceDate
                if let url = URL(string: "calshow:\(seconds)") { openURL(url) }
            } label: {
                Image(systemName: "arrow.up.forward.square")
                    .frame(width: OGMetrics.minTouchTarget, height: OGMetrics.minTouchTarget)
            }
            .buttonStyle(.plain)
            .foregroundStyle(accent)
            .accessibilityLabel("Open \(item.title) in Calendar")
        }
    }

    private func progressRow(_ label: LocalizedStringKey) -> some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(label)
                .font(.footnote)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .accessibilityElement(children: .combine)
    }

}

extension MyDayView {
    /// A row's glyph. A goals row is a `.preparation` row with a goal's own glyph (Plan IW P2), so
    /// it reads as the wearer's goal rather than as getting ready for an event.
    static func icon(for item: MyDayItem) -> String {
        if item.id.source == .goals { return "target" }
        switch item.kind {
        case .event: return "calendar"
        case .leaveBy: return "location.fill"
        case .preparation: return "checkmark.seal"
        case .reminder: return "checklist"
        case .update: return "bell.badge"
        case .weather: return "cloud.sun"
        }
    }

    /// What to say when a row's item went away before it could be completed.
    static func goneMessage(for item: MyDayItem) -> String {
        item.id.source == .goals
            ? String(localized: "That step is no longer on your goals.", comment: "My Day: a goal step that went away.")
            : String(localized: "That reminder is no longer available.", comment: "My Day: a reminder that went away.")
    }
}
