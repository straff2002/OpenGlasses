import Foundation

/// Plan GH — the one active parking spot, and (only when the wearer turns it on) the last ten.
///
/// A JSON file and a folder of sign photos under Application Support, first-unlock protected
/// (`completeUntilFirstUserAuthentication`, so an automatic save at a CarPlay disconnect still
/// lands while the phone is locked) and excluded from backup — a spot is useful for hours, and a
/// copy restored onto a new phone months later is only a record of where somebody was. A replaced
/// or forgotten spot takes its photo with it. Registered in `DataStoreRegistry` as `parkingSpots`.
@MainActor
final class ParkingStore: ObservableObject {

    static let historyCap = 10
    static let fileName = "parking.json"
    static let photoFolderName = "photos"

    @Published private(set) var active: ParkingSpot?
    @Published private(set) var history: [ParkingSpot] = []

    let directory: URL
    /// Whether replaced spots are kept. Read at every save so the setting applies immediately.
    var keepHistory: () -> Bool
    private let fileManager: FileManager

    static let shared = ParkingStore(directory: defaultDirectory)

    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Parking", isDirectory: true)
    }

    init(directory: URL,
         keepHistory: @escaping () -> Bool = { Config.parkingKeepHistory },
         fileManager: FileManager = .default) {
        self.directory = directory
        self.keepHistory = keepHistory
        self.fileManager = fileManager
        load()
    }

    private var fileURL: URL { directory.appendingPathComponent(Self.fileName) }
    private var photoFolder: URL { directory.appendingPathComponent(Self.photoFolderName, isDirectory: true) }

    func photoURL(for spot: ParkingSpot) -> URL? {
        guard let name = spot.photoFile else { return nil }
        return photoFolder.appendingPathComponent(name)
    }

    // MARK: - Writes

    /// Make `spot` the active one, with `photo` stored beside it when given. The previous active
    /// spot moves to history when history is on; otherwise it, and its photo, are deleted.
    @discardableResult
    func save(_ spot: ParkingSpot, photo: Data? = nil) -> ParkingSpot {
        var stored = spot
        if let photo, let name = writePhoto(photo, for: spot.id) {
            stored.photoFile = name
        }
        if let previous = active, previous.id != stored.id {
            retire(previous)
        }
        active = stored
        persist()
        return stored
    }

    /// Apply an automatic detection under the replacement policy. Returns the stored spot, or nil
    /// when a recent manual spot was kept instead.
    @discardableResult
    func saveAutomatic(_ candidate: ParkingSpot, now: Date) -> ParkingSpot? {
        switch ParkingReplacementPolicy.resolve(existing: active, candidate: candidate, now: now) {
        case .keepExisting: return nil
        case .replace(let spot): return save(spot)
        }
    }

    /// Save a spot the wearer gave, merging a coordinate from a moments-old automatic spot when
    /// this one has none.
    @discardableResult
    func saveManual(_ candidate: ParkingSpot, photo: Data? = nil, now: Date) -> ParkingSpot {
        switch ParkingReplacementPolicy.resolve(existing: active, candidate: candidate, now: now) {
        case .keepExisting: return save(candidate, photo: photo)   // not reachable for manual spots
        case .replace(let spot): return save(spot, photo: photo)
        }
    }

    /// Attach a sign photo and its reading to the active spot, replacing any earlier photo.
    @discardableResult
    func attachPhoto(_ data: Data, fields: ParkingFields) -> ParkingSpot? {
        guard var spot = active else { return nil }
        if let old = photoURL(for: spot) { try? fileManager.removeItem(at: old) }
        spot.photoFile = writePhoto(data, for: spot.id)
        spot.merge(fields)
        active = spot
        persist()
        return spot
    }

    /// Replace the details of the active spot (the wearer corrected a reading).
    @discardableResult
    func updateActive(_ fields: ParkingFields) -> ParkingSpot? {
        guard var spot = active else { return nil }
        spot.merge(fields)
        active = spot
        persist()
        return spot
    }

    /// Forget the active spot and its photo. History is untouched.
    func clear() {
        guard let spot = active else { return }
        deletePhoto(of: spot)
        active = nil
        persist()
    }

    /// Forget every past spot and their photos.
    func clearHistory() {
        history.forEach(deletePhoto(of:))
        history = []
        persist()
    }

    /// Everything: the active spot, history, photos and the file. What erasure calls.
    func clearAll() {
        active = nil
        history = []
        try? fileManager.removeItem(at: photoFolder)
        try? fileManager.removeItem(at: fileURL)
    }

    // MARK: - Internals

    private func retire(_ spot: ParkingSpot) {
        guard keepHistory() else {
            deletePhoto(of: spot)
            if !history.isEmpty { clearHistoryInMemory() }
            return
        }
        history.insert(spot, at: 0)
        while history.count > Self.historyCap {
            deletePhoto(of: history.removeLast())
        }
    }

    private func clearHistoryInMemory() {
        history.forEach(deletePhoto(of:))
        history = []
    }

    private func deletePhoto(of spot: ParkingSpot) {
        guard let url = photoURL(for: spot) else { return }
        try? fileManager.removeItem(at: url)
    }

    private func writePhoto(_ data: Data, for id: UUID) -> String? {
        do {
            try ensureDirectory(photoFolder)
            let name = "\(id.uuidString)-\(UUID().uuidString.prefix(8)).jpg"
            let url = photoFolder.appendingPathComponent(name)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            StoreProtection.apply(.completeUntilFirstUserAuthentication, backupExcluded: true, to: url,
                                  fileManager: fileManager)
            return name
        } catch {
            PrivacyLog.store(.parking, .writeFailed, error: SafeErrorSummary(error))
            return nil
        }
    }

    private struct Snapshot: Codable {
        var active: ParkingSpot?
        var history: [ParkingSpot]
    }

    private func persist() {
        do {
            try ensureDirectory(directory)
            let data = try JSONEncoder().encode(Snapshot(active: active, history: history))
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            StoreProtection.apply(.completeUntilFirstUserAuthentication, backupExcluded: true, to: fileURL,
                                  fileManager: fileManager)
        } catch {
            PrivacyLog.store(.parking, .writeFailed, error: SafeErrorSummary(error))
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        active = snapshot.active
        history = Array(snapshot.history.prefix(Self.historyCap))
        // Apply the posture to a file an older build wrote, the same idempotent way other stores do.
        StoreProtection.apply(.completeUntilFirstUserAuthentication, backupExcluded: true, to: fileURL,
                              fileManager: fileManager)
    }

    private func ensureDirectory(_ url: URL) throws {
        guard !fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true,
                                        attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        StoreProtection.apply(.completeUntilFirstUserAuthentication, backupExcluded: true, to: url,
                              fileManager: fileManager)
    }
}
