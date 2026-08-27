import SwiftUI

/// Read-only detail for a Spotlight/Siri content result (Plan BQ P2 `OpenIntent`).
/// Deliberately generic: the index entry carries title + donated text; the full record
/// stays in its owning store (field-session bodies remain behind the encrypted vault).
struct SiriContentDetailView: View {
    let link: SiriContentLink
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        OGChip(text: link.typeLabel)
                        Spacer()
                        if let date = link.date {
                            Text(date, style: .date)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text(link.title)
                        .font(.title3.weight(.semibold))

                    if !link.text.isEmpty {
                        Text(link.text)
                            .font(.body)
                            .textSelection(.enabled)
                    } else {
                        Text("Open the owning section in the app for the full record.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle("Found Content")
            .navigationBarTitleDisplayMode(.inline)
            .siriOnscreenContent(GlassesContentEntity(link: link))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
