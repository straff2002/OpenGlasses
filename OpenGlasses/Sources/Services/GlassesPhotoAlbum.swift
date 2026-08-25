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

    /// Serialises the synchronous PhotoKit work off the main thread. Serial rather than concurrent
    /// so two saves racing the first-ever create cannot both create an album.
    private static let queue = DispatchQueue(label: "openglasses.photo-album", qos: .utility)

    // MARK: - Saving

    /// Save a still image into the Glasses album. Returns whether the asset landed — a denied
    /// library is a normal outcome here, not an error.
    @discardableResult
    static func saveImage(_ image: UIImage) async -> Bool {
        guard await ensureCanSave() else {
            NSLog("[PhotoAlbum] Photo library access denied — image not saved")
            return false
        }
        return await saveTargetingAlbum {
            PHAssetChangeRequest.creationRequestForAsset(from: image)
        }
    }

    /// Save a video file into the Glasses album. Returns whether the asset landed; callers keep
    /// their on-disk copy either way (`RecordingFiler` files to Documents before this runs).
    @discardableResult
    static func saveVideo(at url: URL) async -> Bool {
        guard await ensureCanSave() else {
            NSLog("[PhotoAlbum] Photo library access denied — video not saved")
            return false
        }
        return await saveTargetingAlbum {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }

    // MARK: - Authorization (the one prompt)

    private static func ensureCanSave() async -> Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .notDetermined else { return GlassesPhotoAlbumPolicy.canSave(status) }
        let requested = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return GlassesPhotoAlbumPolicy.canSave(requested)
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
        do {
            try await PHPhotoLibrary.shared().performChanges {
                guard let request = makeRequest() else { return }
                if let album, let placeholder = request.placeholderForCreatedAsset {
                    PHAssetCollectionChangeRequest(for: album)?.addAssets([placeholder] as NSArray)
                }
            }
            return true
        } catch {
            NSLog("[PhotoAlbum] Save failed: %@", error.localizedDescription)
            return false
        }
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
