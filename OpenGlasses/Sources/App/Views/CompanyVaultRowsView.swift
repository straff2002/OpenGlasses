import SwiftUI

/// Plan LR — the company's vaults under *Managed by ⟨org⟩*: each vault's name, version and when it
/// updated, and on the line below it any failure by name or what it is waiting for, with *Download
/// now* when its manuals wait for Wi-Fi. Then *Check for Updates*.
///
/// Plan LV: a published vault's row also says whose it is and at which of the partner's versions
/// ("from ⟨partner⟩ · version 5"), that it is no longer updated when its partner has ended, and the
/// manuals it was written against against the ones this phone holds, opening a list naming each.
struct CompanyVaultRowsView: View {
    @ObservedObject var manager: OrgProfileManager
    let organization: String
    @State private var checking = false

    private var service: CompanyVaultService { .shared }

    var body: some View {
        // Read through the manager, which publishes the record the rows are made from.
        let _ = manager.record?.companyVaults
        if let problem = service.listProblem() {
            OGDivider()
            OGNotice(text: problem, systemImage: "exclamationmark.triangle")
                .padding(12)
        }
        CompanyVaultRowList(rows: service.rows(), onDownloadNow: { id in Task { await service.downloadNow(id) } })
        if let removed = manager.record?.companyVaults?.removedNames, !removed.isEmpty {
            OGDivider()
            OGNotice(text: String(localized: "\(organization) removed \(removed.joined(separator: ", ")) from this phone, with the manuals in it."),
                     systemImage: "minus.circle")
                .padding(12)
        }
        ForEach(CompanyVaultRowList.removalNotices(manager.record?.companyVaults?.removedPublished ?? []), id: \.self) { notice in
            OGDivider()
            OGNotice(text: notice, systemImage: "minus.circle")
                .padding(12)
        }
        OGDivider()
        Button {
            guard !checking else { return }
            checking = true
            Task {
                await manager.checkForUpdates()
                checking = false
            }
        } label: {
            OGRow("Check for Updates", icon: "arrow.triangle.2.circlepath", showsChevron: false) {
                if checking { ProgressView() } else { EmptyView() }
            }
        }
        .buttonStyle(.plain)
        .disabled(checking)
    }
}

/// The rows themselves, drawn from `CompanyVaultRow`s alone so the same view serves the managed
/// section and the UI test that photographs it.
struct CompanyVaultRowList: View {
    let rows: [CompanyVaultRow]
    var onDownloadNow: (String) -> Void = { _ in }

    /// "⟨vault⟩ was removed by ⟨partner⟩", one per published vault its partner took off this phone.
    static func removalNotices(_ removed: [CompanyVaultState.RemovedPublished]) -> [String] {
        removed.map { String(localized: "\($0.name) was removed by \($0.publisher).") }
    }

    var body: some View {
        ForEach(rows) { row in
            OGDivider()
            VStack(alignment: .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: "books.vertical")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text(verbatim: row.name)
                            .font(.body)
                        Spacer(minLength: 8)
                        // A published vault says the partner's version on the line below instead.
                        if row.byline == nil, let version = row.version {
                            Text("Version \(version)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let byline = row.byline {
                        Text(verbatim: byline)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let layer = row.layerNote {
                        Text(verbatim: layer)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let updated = row.updatedAt {
                        Text("Updated \(updated.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let frozen = row.frozenNote {
                        Label {
                            Text(verbatim: frozen)
                        } icon: {
                            Image(systemName: "pause.circle")
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                    if let status = row.status {
                        Label {
                            Text(verbatim: status)
                        } icon: {
                            Image(systemName: row.isProblem ? "exclamationmark.triangle" : "arrow.down.circle")
                        }
                        .font(.footnote)
                        .foregroundStyle(row.isProblem ? Color.orange : Color.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                if let checklist = row.checklist {
                    NavigationLink {
                        CompanyVaultChecklistView(vaultName: row.name, checklist: checklist)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: checklist.hasDifferences ? "doc.badge.ellipsis" : "checkmark.circle")
                                .accessibilityHidden(true)
                            Text(verbatim: checklist.summary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.forward")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        .font(.footnote)
                        .foregroundStyle(checklist.hasDifferences ? Color.orange : Color.secondary)
                        .frame(minHeight: OGMetrics.minTouchTarget)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: checklist.summary))
                    .accessibilityHint(Text("Lists the manuals this vault was written for, and which this phone holds."))
                    .accessibilityIdentifier("companyVaultChecklist.\(row.vaultId)")
                }
                if row.offersDownloadNow {
                    Button("Download now") {
                        onDownloadNow(row.vaultId)
                    }
                    .font(.footnote.weight(.semibold))
                    .accessibilityHint(Text("Downloads these manuals over mobile data, this once."))
                }
            }
            .padding(12)
        }
    }
}

/// Plan LV — the manuals a published vault was written against, each named with whether this
/// phone holds it, holds another revision of it, or doesn't hold it. Your administrator adds the
/// missing ones in the portal; nothing here is reported anywhere.
struct CompanyVaultChecklistView: View {
    let vaultName: String
    let checklist: CompanyVaultRow.ManualChecklist

    var body: some View {
        OGScrollPage {
            OGSection(footer: "Your administrator adds missing manuals, or replaces one at a different revision, in your organisation's portal.") {
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: checklist.summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(12)
                    ForEach(checklist.entries) { entry in
                        OGDivider()
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: Self.symbol(entry.state))
                                .foregroundStyle(Self.isDifference(entry.state) ? Color.orange : Color.secondary)
                                .accessibilityHidden(true)
                            Text(verbatim: entry.title)
                                .font(.body)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            Text(verbatim: entry.status)
                                .font(.footnote)
                                .foregroundStyle(Self.isDifference(entry.state) ? Color.orange : Color.secondary)
                                .multilineTextAlignment(.trailing)
                        }
                        .padding(12)
                        .frame(minHeight: OGMetrics.minTouchTarget)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .navigationTitle(Text(verbatim: vaultName))
        .navigationBarTitleDisplayMode(.inline)
    }

    private static func isDifference(_ state: ExpectedManualMatch.Status) -> Bool {
        if case .matched = state { return false }
        return true
    }

    private static func symbol(_ state: ExpectedManualMatch.Status) -> String {
        switch state {
        case .matched: return "checkmark.circle"
        case .differentRevision: return "doc.badge.ellipsis"
        case .missing: return "questionmark.circle"
        }
    }
}
