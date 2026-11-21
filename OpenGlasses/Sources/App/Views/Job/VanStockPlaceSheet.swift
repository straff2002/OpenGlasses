import SwiftUI

/// Name and place (Plan MK §2, §4): the list's name, the kind of place it is kept in, and the
/// book its part numbers are checked against when no job is open.
///
/// The kind sets the words the assistant uses and the screen's title. When the organisation's
/// profile sets it, the picker is shown read-only with who set it, as the accent picker is. The
/// book is this phone's own choice and never goes into the workbook. Nothing is written until
/// Save, and only what changed is written.
struct VanStockPlaceSheet: View {
    @ObservedObject var store: VanStockStore
    /// The vaults this phone can open now, by name.
    let books: [Book]

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var kind = StockPlace.Kind.default
    /// The vault id the picker shows; nil for none.
    @State private var bookID: String?
    @State private var clinical = false
    @State private var loaded = false

    /// A vault the list can name.
    struct Book: Identifiable, Equatable {
        let id: String
        let name: String
    }

    /// Every installed vault the registry unlocks, in the registry's order.
    @MainActor
    static func installedBooks(_ registry: VaultRegistry = .shared) -> [Book] {
        registry.allManifests.filter { registry.isUnlocked($0) }.map { Book(id: $0.id, name: $0.name) }
    }

    private var resolved: StockPlaceSetting.Resolved { store.resolvedPlace }

    private var savedBook: StockPlaceScreenText.Book {
        StockPlaceScreenText.book(saved: store.van?.checkVaultID, installed: Set(books.map(\.id)))
    }

    var body: some View {
        NavigationStack {
            Form {
                nameSection
                placeSection
                clinicalSection
                bookSection
            }
            .ogFormStyle()
            .navigationTitle("Name and place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                        dismiss()
                    }
                    .disabled(store.isUnreadable)
                }
            }
            .onAppear(perform: fill)
        }
    }

    // MARK: - Sections

    private var nameSection: some View {
        Section {
            TextField(StockPlaceScreenText.namePlaceholder(resolved.isLocked ? resolved.kind : kind), text: $name)
                .textInputAutocapitalization(.words)
                .accessibilityLabel(Text("Name"))
                .frame(minHeight: OGMetrics.minTouchTarget)
        } header: {
            Text("Name")
        } footer: {
            Text("The name goes on every spreadsheet, so the office and the next shift know which list it is.")
        }
    }

    @ViewBuilder
    private var placeSection: some View {
        Section {
            if resolved.isLocked {
                // The organisation's profile sets the place: show the kind in force and who set
                // it, rather than a picker that would not take.
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("Kept in") {
                        Text(StockPlaceScreenText.kindName(resolved.kind))
                    }
                    ManagedLockNote(organization: ManagedLockReason.organization)
                }
                .frame(minHeight: OGMetrics.minTouchTarget)
                .accessibilityElement(children: .combine)
            } else {
                Picker("Kept in", selection: $kind) {
                    ForEach(StockPlace.Kind.allCases, id: \.self) { kind in
                        Text(StockPlaceScreenText.kindName(kind)).tag(kind)
                    }
                }
                .frame(minHeight: OGMetrics.minTouchTarget)
            }
        } header: {
            Text("Place")
        } footer: {
            Text("The place sets the words the assistant uses, and the title when the list has no name.")
        }
    }

    /// Whether the list is a clinic's (Plan MY §9): read-only with who set it when the
    /// organisation's profile sets it, as the place is.
    @ViewBuilder
    private var clinicalSection: some View {
        let resolvedClinical = store.resolvedClinical
        Section {
            if resolvedClinical.isLocked {
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("A clinic's stock") {
                        Text(resolvedClinical.clinical ? "On" : "Off")
                    }
                    ManagedLockNote(organization: ManagedLockReason.organization)
                }
                .frame(minHeight: OGMetrics.minTouchTarget)
                .accessibilityElement(children: .combine)
            } else {
                Toggle("A clinic's stock", isOn: $clinical)
                    .frame(minHeight: OGMetrics.minTouchTarget)
            }
        } footer: {
            Text("The assistant then speaks of doses given and wasted, by lot. It's a stock record, not the immunisation record.")
        }
    }

    @ViewBuilder
    private var bookSection: some View {
        Section {
            Picker("Check numbers against", selection: $bookID) {
                Text("None").tag(String?.none)
                ForEach(books) { book in
                    Text(book.name).tag(String?.some(book.id))
                }
                if case .gone(let id) = savedBook {
                    Text("No longer on this phone").tag(String?.some(id))
                }
            }
            .frame(minHeight: OGMetrics.minTouchTarget)
            if case .gone(let id) = savedBook, bookID == id {
                Label("The vault this list named has gone from this phone, so numbers are not checked. Choose another, or None.",
                      systemImage: "exclamationmark.triangle")
                    .font(.callout)
            }
        } header: {
            Text("Check numbers against")
        } footer: {
            Text("With no job open, part numbers are looked up in this vault. With a job open, the job's own vault is used.")
        }
    }

    // MARK: - Saving

    private func fill() {
        guard !loaded else { return }
        loaded = true
        name = store.van?.name ?? ""
        kind = store.van?.place ?? .default
        bookID = store.van?.checkVaultID
        clinical = store.van?.clinical ?? false
    }

    /// Name, place and book, each written only when it changed, so opening the sheet and saving
    /// it as it was writes nothing.
    private func save() {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleaned.isEmpty, cleaned != store.van?.name { store.nameVan(cleaned) }
        // The profile's place is resolved over the list's, never written into it (Plan MK §2).
        if !resolved.isLocked, kind != (store.van?.place ?? .default) { store.setPlace(kind) }
        if bookID != store.van?.checkVaultID { store.checkNumbers(against: bookID) }
        // The profile's flag is resolved over the list's, never written into it.
        if !store.resolvedClinical.isLocked, clinical != (store.van?.clinical ?? false) { store.setClinical(clinical) }
    }
}

/// The Job-tab row's label: the list's name, or the place's title (Plan MK §3). Observes the
/// store, so a list named or placed on the Stock screen is named on the way back.
struct VanStockEntryLabel: View {
    @ObservedObject var store: VanStockStore

    var body: some View {
        Label(store.screenTitle, systemImage: "shippingbox")
    }
}
