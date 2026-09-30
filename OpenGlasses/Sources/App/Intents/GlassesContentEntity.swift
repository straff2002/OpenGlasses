import AppIntents
import CoreSpotlight
import CoreTransferable
import Foundation

/// One piece of user-exposed OpenGlasses content (note, meeting summary, saved location,
/// …), donated to Spotlight via `IndexedEntity` so Siri and search can find it — Plan BQ P2.
struct GlassesContentEntity: AppEntity, IndexedEntity, Identifiable, Transferable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Avenkin Content"
    static var defaultQuery = GlassesContentQuery()

    /// Composite "type:itemId" — stable across re-donations (`IndexableRecord.id`).
    let id: String
    let contentTypeRaw: String
    let title: String
    let text: String
    let keywords: [String]
    let date: Date?

    init(record: IndexableRecord) {
        self.id = record.id
        self.contentTypeRaw = record.contentType.rawValue
        self.title = record.title
        self.text = record.text
        self.keywords = record.keywords
        self.date = record.date
    }

    var typeLabel: String {
        SiriContentType(rawValue: contentTypeRaw)?.displayLabel ?? "Content"
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(typeLabel)")
    }

    /// Spotlight attributes. `text` is whatever the adapter chose to donate — already
    /// metadata-only for the sensitive types, so no further filtering happens here.
    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = title
        attributes.contentDescription = text
        attributes.keywords = keywords + [typeLabel]
        attributes.contentModificationDate = date
        return attributes
    }

    var plainText: String {
        text.isEmpty ? title : "\(title)\n\n\(text)"
    }

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: \.plainText)
    }
}

/// Resolves content entities against the same gathered records the index donates —
/// Spotlight results, Shortcuts pickers, and spoken references all see one truth.
struct GlassesContentQuery: EntityStringQuery {
    func entities(for identifiers: [GlassesContentEntity.ID]) async throws -> [GlassesContentEntity] {
        let records = await SiriContentProvider.currentRecords()
        return identifiers.compactMap { id in
            records.first { $0.id == id }.map(GlassesContentEntity.init)
        }
    }

    func suggestedEntities() async throws -> [GlassesContentEntity] {
        await SiriContentProvider.currentRecords()
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            .prefix(20)
            .map(GlassesContentEntity.init)
    }

    func entities(matching string: String) async throws -> [GlassesContentEntity] {
        let target = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !target.isEmpty else { return [] }
        return await SiriContentProvider.currentRecords()
            .filter {
                $0.title.lowercased().contains(target)
                    || $0.keywords.contains { $0.lowercased().contains(target) }
            }
            .map(GlassesContentEntity.init)
    }
}

/// Opens a Spotlight/Shortcuts content result in the app (read-only detail sheet; the
/// full record stays in its owning store — field-session bodies behind the vault).
struct OpenGlassesContentIntent: OpenIntent {
    static var title: LocalizedStringResource = "Open Avenkin Content"
    static var description = IntentDescription("Open a note, summary, or other saved content")

    static var isDiscoverable: Bool { true }
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Content")
    var target: GlassesContentEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        let appState = try await IntentSupport.awaitConnectedAppState()
        appState.pendingSiriContent = SiriContentLink(
            id: target.id,
            typeLabel: target.typeLabel,
            title: target.title,
            text: target.text,
            date: target.date
        )
        return .result()
    }
}
