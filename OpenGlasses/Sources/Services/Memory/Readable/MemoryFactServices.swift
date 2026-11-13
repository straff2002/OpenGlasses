import Foundation

/// The readable-memory pieces wired to one set of stores: the repository the screen and the
/// voice tool read, and the forgetter and corrector they both change memory through.
@MainActor
final class MemoryFactServices {

    let stores: MemoryFactStores
    let repository: MemoryFactRepository
    let forgetter: MemoryFactForgetter
    let corrector: MemoryFactCorrector

    init(stores: MemoryFactStores, coordinator: SubjectErasureCoordinator,
         invalidations: [@MainActor () -> Void] = [],
         protectedDataAvailable: @escaping @MainActor () -> Bool = { true }) {
        self.stores = stores
        var sources: [any MemoryFactSource] = []
        if let semantic = stores.semantic { sources.append(SemanticFactSource(store: semantic)) }
        if let brain = stores.brain { sources.append(BrainFactSource(brain: brain)) }
        if let notes = stores.agentDocuments { sources.append(AgentNotesFactSource(documents: notes)) }
        if let objects = stores.objects, let places = stores.savedPlaces {
            sources.append(PlacesFactSource(objects: objects, savedPlaces: places))
        }
        if let conversations = stores.conversations {
            sources.append(ConversationDigestFactSource(conversations: conversations))
        }
        var liveThreadIDs: (@MainActor () -> Set<String>)?
        if let conversations = stores.conversations {
            liveThreadIDs = { Set(conversations.threads.map(\.id)) }
        }
        repository = MemoryFactRepository(sources: sources, protectedDataAvailable: protectedDataAvailable,
                                          liveThreadIDs: liveThreadIDs)
        forgetter = MemoryFactForgetter(stores: stores, coordinator: coordinator,
                                        invalidations: invalidations)
        corrector = MemoryFactCorrector(stores: stores)
    }

    func makeScreenModel(query: String = "") -> MemoryScreenModel {
        MemoryScreenModel(repository: repository, forgetter: forgetter, corrector: corrector,
                          initialQuery: query)
    }
}
