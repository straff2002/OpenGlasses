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

        if snapshot.items.isEmpty {
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
                ForEach(Array(snapshot.items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { OGDivider() }
                    itemRow(item)
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
        } else if item.actions.contains(.open), let dueAt = item.dueAt {
            Button {
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
        case .reminder: "checklist"
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
