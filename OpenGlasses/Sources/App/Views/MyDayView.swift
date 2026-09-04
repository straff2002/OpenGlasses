import EventKit
import SwiftUI

/// On-demand phone surface for the same deterministic snapshot used by voice and Siri.
struct MyDayView: View {
    @ObservedObject var service: MyDayService
    @Environment(\.appAccent) private var accent
    @Environment(\.openURL) private var openURL
    @State private var actionMessage: String?

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

        // The whole day, not the card's share of it. This screen is what "See all" opens, so
        // anything the cap held back has to be here — otherwise clearing a row is the only way to
        // discover it existed.
        let allItems = snapshot.allItems
        if allItems.isEmpty {
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
        } else {
            OGSection(header: "Next") {
                ForEach(Array(allItems.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { OGDivider() }
                    MyDaySwipeToClear(label: item.title) {
                        Task { await service.dismiss(item) }
                    } content: {
                        itemRow(item)
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

    private func itemRow(_ item: MyDayItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            OGIconTile(systemName: icon(for: item.kind))
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
            .accessibilityLabel("Complete \(item.title)")
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
                Image(systemName: "arrow.up.right.square")
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
                Text(state.message ?? "This source is unavailable.")
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
            let title = try await service.completeReminder(id: item.id.rawValue)
            if title == nil { actionMessage = "That reminder is no longer available." }
        } catch {
            actionMessage = "The reminder could not be completed."
        }
    }

    private func icon(for kind: MyDayKind) -> String {
        switch kind {
        case .event: "calendar"
        case .leaveBy: "location.fill"
        case .preparation: "checkmark.seal"
        case .reminder: "checklist"
        case .update: "bell.badge"
        case .weather: "cloud.sun"
        }
    }

    private func isStale(_ snapshot: MyDaySnapshot) -> Bool {
        guard let refresh = snapshot.nextRefreshAt else { return false }
        return Date() >= refresh
    }

    private func refreshLabel(_ snapshot: MyDaySnapshot) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        let prefix = isStale(snapshot) ? "Stale — pull to refresh" : "Updated"
        return "\(prefix) \(formatter.string(from: snapshot.generatedAt))"
    }
}

/// Compact home-screen expression of My Day. It replaces the decorative voice waveline with
/// information that is useful before a conversation starts, while keeping the complete review and
/// action surface one tap away.
struct MyDayHomeView: View {
    @ObservedObject var service: MyDayService
    @Binding var isEnabled: Bool
    let compact: Bool

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
        Group {
            if isEnabled {
                enabledCard
            } else {
                setupCard
            }
        }
        .padding(.horizontal, 16)
        .task(id: isEnabled) {
            guard isEnabled else { return }
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
            let title = try await service.completeReminder(id: item.id.rawValue)
            if title == nil { actionMessage = "That reminder is no longer available." }
        } catch {
            actionMessage = "The reminder could not be completed."
        }
    }

    /// Only when the snapshot has aged past the interval it advertises — coming back to the app for
    /// five seconds should not re-hit EventKit.
    private func refreshIfStale() {
        guard isEnabled else { return }
        if case .loaded(let snapshot) = service.state,
           let next = snapshot.nextRefreshAt, Date() < next { return }
        refreshInBackground()
    }

    /// `channel: nil` — this is the card keeping itself current, not the wearer asking for a
    /// briefing, and the metrics should not read as though they did.
    private func refreshInBackground() {
        guard isEnabled else { return }
        // EventKit posts its change notification in bursts; a refresh already in flight is enough.
        if case .loading = service.state { return }
        Task { _ = await service.refresh(channel: nil) }
    }

    private var setupCard: some View {
        OGCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("My Day", systemImage: "sun.max.fill")
                    .font(.headline)
                    .foregroundStyle(OGTheme.tintedAccentLabel(accent))

                Text("Put what matters next here instead of an animation.")
                    .font(.body.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)

                Text("Uses Calendar, Reminders, and Weather only after you choose to set it up.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Set Up My Day") {
                    MyDayMetricsStore.shared.record(.optedIn, at: Date())
                    isEnabled = true
                }
                .buttonStyle(.borderedProminent)
                .frame(minHeight: OGMetrics.minTouchTarget)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
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

            if snapshot.items.isEmpty {
                Label("Nothing urgent", systemImage: "checkmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                // Expanded, the card *is* the full day — the whole list, not the card's share of
                // it, which is what the modal used to be for.
                let visibleItems = isExpanded && !compact
                    ? snapshot.allItems
                    : Array(snapshot.items.prefix(compact ? 1 : 3))
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
                                    Image(systemName: icon(for: item.kind))
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

                // Counts the whole day, not the capped list. It used to count `items`, which is
                // what the cap left — so a row that arrived when another was cleared looked like
                // it had materialised, when it had been on the list the whole time and nothing on
                // screen could say so.
                let total = snapshot.allItems.count
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
            .accessibilityLabel("Complete \(item.title)")
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
                Image(systemName: "arrow.up.right.square")
                    .frame(width: OGMetrics.minTouchTarget, height: OGMetrics.minTouchTarget)
            }
            .buttonStyle(.plain)
            .foregroundStyle(accent)
            .accessibilityLabel("Open \(item.title) in Calendar")
        }
    }

    private func progressRow(_ label: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(label)
                .font(.footnote)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .accessibilityElement(children: .combine)
    }

    private func icon(for kind: MyDayKind) -> String {
        switch kind {
        case .event: "calendar"
        case .leaveBy: "location.fill"
        case .preparation: "checkmark.seal"
        case .reminder: "checklist"
        case .update: "bell.badge"
        case .weather: "cloud.sun"
        }
    }
}
