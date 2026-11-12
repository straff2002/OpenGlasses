import SwiftUI

/// Plan LR — the company's vaults under *Managed by ⟨org⟩*: each vault's name, version and when it
/// updated, and on the line below it any failure by name or what it is waiting for, with *Download
/// now* when its manuals wait for Wi-Fi. Then *Check for Updates*.
struct CompanyVaultRowsView: View {
    @ObservedObject var manager: OrgProfileManager
    let organization: String
    @State private var checking = false

    private var service: CompanyVaultService { .shared }

    var body: some View {
        // Read through the manager, which publishes the record the rows are made from.
        let _ = manager.record?.companyVaults
        let rows = service.rows()
        if let problem = service.listProblem() {
            OGDivider()
            OGNotice(text: problem, systemImage: "exclamationmark.triangle")
                .padding(12)
        }
        ForEach(rows) { row in
            OGDivider()
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: "books.vertical")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(verbatim: row.name)
                        .font(.body)
                    Spacer(minLength: 8)
                    if let version = row.version {
                        Text("Version \(version)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let updated = row.updatedAt {
                    Text("Updated \(updated.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
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
                if row.offersDownloadNow {
                    Button("Download now") {
                        Task { await service.downloadNow(row.vaultId) }
                    }
                    .font(.footnote.weight(.semibold))
                    .accessibilityHint(Text("Downloads these manuals over mobile data, this once."))
                }
            }
            .padding(12)
            .accessibilityElement(children: .combine)
        }
        if let removed = manager.record?.companyVaults?.removedNames, !removed.isEmpty {
            OGDivider()
            OGNotice(text: String(localized: "\(organization) removed \(removed.joined(separator: ", ")) from this phone, with the manuals in it."),
                     systemImage: "minus.circle")
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
