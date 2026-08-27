import Foundation
import Photos
import UIKit

/// The pure half of the Glasses-album save path: which authorization states may save, which album
/// a save should target given what the identifier cache and a title lookup found, and whether a
/// failed create was PhotoKit's "an album with that title already exists" race.
///
/// No PhotoKit calls happen here, so all of it is unit-testable headless; `GlassesPhotoAlbum` is
/// the thin edge that talks to the library.
enum GlassesPhotoAlbumPolicy {

    /// Whether a save may proceed under this authorization status.
    ///
    /// `.limited` counts, as it did before the consolidation: the wearer has granted access to a
    /// selection and adding new assets still works. Album *targeting* may not, which the save path
    /// handles by falling back to an untargeted save rather than by refusing.
    static func canSave(_ status: PHAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .limited:
            return true
        case .notDetermined, .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    /// Where the next save should get its album from.
    enum Resolution: Equatable {
        /// The cached local identifier still resolves — use it, no title lookup needed. This is
        /// the steady state, and the reason the cache exists: a title fetch on every save is both
        /// slower and ambiguous once the wearer has an album of their own with the same name.
        case useCached(String)
        /// No usable cached identifier, but an album with our title exists — adopt it and cache
        /// its identifier so the next save takes the fast path.
        case adoptFoundByTitle
        /// Nothing to adopt: create the album (and cache what comes back).
        case create
    }

    static func resolution(cachedIdentifier: String?,
                           cachedAlbumStillExists: Bool,
                           albumFoundByTitle: Bool) -> Resolution {
        if let cachedIdentifier, cachedAlbumStillExists { return .useCached(cachedIdentifier) }
        return albumFoundByTitle ? .adoptFoundByTitle : .create
    }

    /// The error code PhotoKit reports when a collection with that title already exists. Two saves
    /// racing the first-ever create both try; the loser has to adopt the winner's album instead of
    /// logging a failure and dropping the asset loose in the library.
    static let albumAlreadyExistsCode = 3311

    static func isAlbumAlreadyExists(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == PHPhotosErrorDomain && nsError.code == albumAlreadyExistsCode
    }

    /// A word for an authorization status, for the diagnostics log. "Photo library access denied"
    /// was the only thing a failed save ever said, which cannot tell apart a wearer who declined,
    /// a device where the library is restricted, and a prompt that was never presented at all —
    /// the three cases that look identical from the outside and need completely different answers.
    static func describe(_ status: PHAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .limited: return "limited"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not determined"
        @unknown default: return "unknown"
        }
    }
}

/// How a save to the photo library ended.
///
/// Three outcomes rather than a Bool, because "it didn't save" is not one thing: a library the
/// wearer has never been asked about, one they said no to, and a change request that failed all
/// need to be told apart — the first two are answered in Settings and the third is not.
enum PhotoLibrarySaveResult: Equatable {
    case saved
    /// Authorization does not allow adding — carries the status seen so the caller can say which.
    case notPermitted(PHAuthorizationStatus)
    /// Authorized, but the asset did not land.
    case failed

    var didSave: Bool { self == .saved }
}

/// Every write this app makes to the photo library goes through here.
///
/// It used to go through two: `CameraService` and `VideoRecordingService` each carried a private
/// `fetchGlassesAlbum()` and each requested authorization itself, so the wearer could be asked for
/// the photo library twice and the two copies were free to drift apart. One place asks, one place
/// resolves the album, one place saves.
///
/// Authorization is `.readWrite`, requested exactly once — on the first save of any kind.
/// Add-only is the narrower ask and was the obvious thing to want, but album *targeting* needs
/// read access: `PHAssetCollection.fetchAssetCollections` returns nothing under `.addOnly`, so the
/// cached identifier fails to validate on every save, the title lookup finds nothing either, and
/// the create path runs again — a fresh empty "Glasses" album per photo, or none at all. Until
/// PhotoKit can target an album without reading one, readWrite-once is the honest trade.
enum GlassesPhotoAlbum {

    /// Name of the Photos album where glasses photos and recordings are saved.
    static let albumName = "Glasses"

    private static let albumIDKey = "GlassesPhotoAlbumLocalIdentifier"

    /// Reported to the on-screen diagnostics log. Set once at app start; nothing here depends on
    /// it being wired. `nonisolated(unsafe)` because this type is a namespace of statics reached
    /// from every capture path — it is assigned exactly once, before any capture can run.
    nonisolated(unsafe) static var onDebugEvent: (@Sendable (String) -> Void)?

    /// Serialises the synchronous PhotoKit work off the main thread. Serial rather than concurrent
    /// so two saves racing the first-ever create cannot both create an album.
    private static let queue = DispatchQueue(label: "openglasses.photo-album", qos: .utility)

    // MARK: - Saving

    /// Save a still image into the Glasses album. A library that has not been granted is a normal
    /// outcome here rather than an error, and it comes back distinguishable from a save that was
    /// allowed and still failed.
    @discardableResult
    static func saveImage(_ image: UIImage) async -> PhotoLibrarySaveResult {
        let status = await ensureCanSave()
        guard GlassesPhotoAlbumPolicy.canSave(status) else {
            report("Photo library \(GlassesPhotoAlbumPolicy.describe(status)) — image not saved")
            return .notPermitted(status)
        }
        let saved = await saveTargetingAlbum {
            PHAssetChangeRequest.creationRequestForAsset(from: image)
        }
        // Plan DE: the first photo is one of the four moments the hub may quietly
        // point at the next capability. Recorded here rather than at any one call
        // site because every route into the album passes through this function.
        if saved { SettingsJourneyStore.note(.firstPhotoCaptured) }
        report(saved ? "Photo saved to the \(albumName) album" : "Photo library save failed")
        return saved ? .saved : .failed
    }

    /// Save a video file into the Glasses album. Callers keep their on-disk copy whatever this
    /// returns (`RecordingFiler` files to Documents before this runs).
    @discardableResult
    static func saveVideo(at url: URL) async -> PhotoLibrarySaveResult {
        let status = await ensureCanSave()
        guard GlassesPhotoAlbumPolicy.canSave(status) else {
            report("Photo library \(GlassesPhotoAlbumPolicy.describe(status)) — recording not saved")
            return .notPermitted(status)
        }
        let saved = await saveTargetingAlbum {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
        report(saved ? "Recording saved to the \(albumName) album" : "Photo library save failed")
        return saved ? .saved : .failed
    }

    // MARK: - Authorization (the one prompt)

    /// The authorization status a save may proceed on, asking for it if it has never been asked.
    ///
    /// Runs on the main actor. Presenting the system prompt is UI work, and a request made from a
    /// background context is exactly the shape of failure the field report showed: no prompt ever
    /// appeared on a fresh install, every save declined, nothing said. The status seen is returned
    /// rather than a Bool so the caller can be specific about why nothing landed.
    @MainActor
    private static func ensureCanSave() async -> PHAuthorizationStatus {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .notDetermined else { return status }
        report("Asking for photo library access")
        let requested = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        report("Photo library access \(GlassesPhotoAlbumPolicy.describe(requested))")
        return requested
    }

    private static func report(_ message: String) {
        NSLog("[PhotoAlbum] %@", message)
        onDebugEvent?(message)
    }

    // MARK: - The change request

    private static func saveTargetingAlbum(
        _ makeRequest: @escaping () -> PHAssetChangeRequest?
    ) async -> Bool {
        let album = await resolveAlbum()
        if await commit(album: album, makeRequest: makeRequest) { return true }
        guard album != nil else { return false }

        // Album targeting is the fragile half — a collection that has since been deleted fails the
        // whole change block, taking the asset with it. Forget it and save the asset loose rather
        // than lose the capture; the next save re-resolves from scratch.
        forgetCachedAlbum()
        NSLog("[PhotoAlbum] Retrying save without album targeting")
        return await commit(album: nil, makeRequest: makeRequest)
    }

    private static func commit(album: PHAssetCollection?,
                               makeRequest: @escaping () -> PHAssetChangeRequest?) async -> Bool {
        // PhotoKit reports an empty change block as a *successful* set of changes, so a request it
        // declined to build (an unreadable file, an asset type it won't take) would otherwise be
        // reported to the caller as a save that landed.
        let built = RequestFlag()
        do {
            try await PHPhotoLibrary.shared().performChanges {
                guard let request = makeRequest() else { return }
                built.value = true
                if let album, let placeholder = request.placeholderForCreatedAsset {
                    PHAssetCollectionChangeRequest(for: album)?.addAssets([placeholder] as NSArray)
                }
            }
        } catch {
            NSLog("[PhotoAlbum] Save failed: %@", error.localizedDescription)
            return false
        }
        if !built.value {
            NSLog("[PhotoAlbum] No change request could be built for that asset")
        }
        return built.value
    }

    /// Carries the "did we actually build a request" answer out of the change block, which runs
    /// on PhotoKit's own queue.
    private final class RequestFlag: @unchecked Sendable {
        var value = false
    }

    // MARK: - Album resolution

    private static func resolveAlbum() async -> PHAssetCollection? {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: resolveAlbumSynchronously()) }
        }
    }

    private static func resolveAlbumSynchronously() -> PHAssetCollection? {
        let cachedIdentifier = UserDefaults.standard.string(forKey: albumIDKey)
        let cachedAlbum = cachedIdentifier.flatMap { fetchAlbum(localIdentifier: $0) }
        let foundByTitle = cachedAlbum == nil ? findAlbumByTitle() : nil

        switch GlassesPhotoAlbumPolicy.resolution(cachedIdentifier: cachedIdentifier,
                                                  cachedAlbumStillExists: cachedAlbum != nil,
                                                  albumFoundByTitle: foundByTitle != nil) {
        case .useCached:
            return cachedAlbum
        case .adoptFoundByTitle:
            guard let foundByTitle else { return nil }
            cacheAlbumID(foundByTitle.localIdentifier)
            return foundByTitle
        case .create:
            forgetCachedAlbum()
            return createAlbum()
        }
    }

    private static func fetchAlbum(localIdentifier: String) -> PHAssetCollection? {
        PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [localIdentifier],
                                                options: nil).firstObject
    }

    private static func findAlbumByTitle() -> PHAssetCollection? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title = %@", albumName)
        return PHAssetCollection.fetchAssetCollections(with: .album,
                                                       subtype: .any,
                                                       options: options).firstObject
    }

    private static func createAlbum() -> PHAssetCollection? {
        var localIdentifier: String?
        do {
            try PHPhotoLibrary.shared().performChangesAndWait {
                let request = PHAssetCollectionChangeRequest
                    .creationRequestForAssetCollection(withTitle: albumName)
                localIdentifier = request.placeholderForCreatedAssetCollection.localIdentifier
            }
        } catch {
            if GlassesPhotoAlbumPolicy.isAlbumAlreadyExists(error), let existing = findAlbumByTitle() {
                cacheAlbumID(existing.localIdentifier)
                return existing
            }
            NSLog("[PhotoAlbum] Failed to create album: %@", error.localizedDescription)
            return nil
        }

        guard let localIdentifier else { return nil }
        cacheAlbumID(localIdentifier)
        return fetchAlbum(localIdentifier: localIdentifier)
    }

    // MARK: - Identifier cache

    private static func cacheAlbumID(_ localIdentifier: String) {
        UserDefaults.standard.set(localIdentifier, forKey: albumIDKey)
    }

    private static func forgetCachedAlbum() {
        UserDefaults.standard.removeObject(forKey: albumIDKey)
    }
}
