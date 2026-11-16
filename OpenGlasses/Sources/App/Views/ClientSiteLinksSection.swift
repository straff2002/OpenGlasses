import SwiftUI

/// The Workiz clients this phone remembers a documented site for (Plan MD §4), listed so each can
/// be forgotten. Shown only when there is at least one. Nothing here is ever sent to Workiz.
struct ClientSiteLinksSection: View {
    @ObservedObject var store: ClientSiteLinkStore

    private var workizLinks: [ClientSiteLink] { store.links.filter { $0.system == "workiz" } }

    var body: some View {
        if !workizLinks.isEmpty {
            Section {
                ForEach(workizLinks) { link in
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(link.siteLabel)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("Workiz client \(link.clientID)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                        Button(role: .destructive) {
                            store.forget(id: link.id)
                        } label: {
                            Text("Forget")
                                .frame(minWidth: OGMetrics.minTouchTarget, minHeight: OGMetrics.minTouchTarget)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(OGTheme.errorLabel)
                        .accessibilityLabel("Forget \(link.siteLabel) for Workiz client \(link.clientID)")
                        .accessibilityHint("Their next Workiz jobs no longer start at this site by themselves.")
                    }
                }
            } header: {
                Text("Sites remembered for clients")
            } footer: {
                Text("When you choose a documented site for a Workiz job on New job, this phone remembers it for that client's next jobs. Kept on this phone only, and never sent to Workiz.")
            }
        }
    }
}
