import SwiftUI

/// The end-of-shift stock, staged for the technician to send (Plan IH §8).
///
/// What will go is on the sheet before it goes: the short text base reads first, and the workbook
/// attached to it. Send opens the system share sheet with both; nothing leaves before that.
struct VanStockHandoverSheet: View {
    @ObservedObject var service: VanStockHandoverService

    @State private var sharing: ShareItem?

    var body: some View {
        NavigationStack {
            List {
                if let staged = service.staged {
                    Section {
                        Text(staged.message)
                            .font(.callout)
                            .textSelection(.enabled)
                    } header: {
                        Text("The message")
                    }
                    Section {
                        Label(staged.fileURL.lastPathComponent, systemImage: "tablecells")
                    } header: {
                        Text("Attached")
                    } footer: {
                        Text("The whole list as a spreadsheet. The next person opens it in Avenkin to pick the list up.")
                    }
                    Section {
                        Button {
                            sharing = ShareItem(items: [staged.message, staged.fileURL])
                        } label: {
                            Label("Send…", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity, minHeight: OGMetrics.minTouchTarget, alignment: .leading)
                        }
                    } footer: {
                        Text("Nothing has been sent. You choose who it goes to.")
                    }
                }
            }
            .ogFormStyle()
            .navigationTitle("Send the stock list")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { service.discard() }
                }
            }
            .sheet(item: $sharing) { item in
                ShareSheet(items: item.items, onComplete: item.onComplete)
            }
        }
    }
}
