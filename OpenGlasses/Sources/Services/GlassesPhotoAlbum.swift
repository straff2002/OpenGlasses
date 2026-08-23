import Photos
import UIKit

enum GlassesPhotoAlbum {
    private static let albumName = "Glasses"
    private static let albumIDKey = "GlassesPhotoAlbumLocalIdentifier"

    static func saveImage(_ image: UIImage, completion: ((Bool) -> Void)? = nil) {
        ensureCanSave { canSave in
            guard canSave else {
                NSLog("[GlassesPhotoAlbum] Photo library access denied")
                completion?(false)
                return
            }
            performSave(image: image, completion: completion)
        }
    }

    static func saveVideo(at url: URL) async -> Bool {
        guard await ensureCanSave() else { return false }
        return await performSave(videoURL: url)
    }

    private static func ensureCanSave() async -> Bool {
        await withCheckedContinuation { continuation in
            ensureCanSave { continuation.resume(returning: $0) }
        }
    }

    private static func ensureCanSave(completion: @escaping (Bool) -> Void) {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch status {
        case .authorized:
            completion(true)
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { newStatus in
                completion(newStatus == .authorized)
            }
        default:
            completion(false)
        }
    }

    private static func resolveAlbum() -> PHAssetCollection? {
        if let cachedID = UserDefaults.standard.string(forKey: albumIDKey) {
            if let album = fetchAlbum(localIdentifier: cachedID) {
                return album
            }
            UserDefaults.standard.removeObject(forKey: albumIDKey)
        }

        if let existing = findAlbumByTitle() {
            cacheAlbumID(existing.localIdentifier)
            return existing
        }

        return createAlbum()
    }

    private static func fetchAlbum(localIdentifier: String) -> PHAssetCollection? {
        PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [localIdentifier], options: nil).firstObject
    }

    private static func findAlbumByTitle() -> PHAssetCollection? {
        let readWriteStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard readWriteStatus == .authorized || readWriteStatus == .limited else { return nil }
        let fetchOptions = PHFetchOptions()
        fetchOptions.predicate = NSPredicate(format: "title = %@", albumName)
        return PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: fetchOptions).firstObject
    }

    private static func createAlbum() -> PHAssetCollection? {
        var localIdentifier: String?
        do {
            try PHPhotoLibrary.shared().performChangesAndWait {
                let createRequest = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: albumName)
                localIdentifier = createRequest.placeholderForCreatedAssetCollection.localIdentifier
            }
        } catch {
            if isAlbumAlreadyExistsError(error), let existing = findAlbumByTitle() {
                cacheAlbumID(existing.localIdentifier)
                return existing
            }
            NSLog("[GlassesPhotoAlbum] Failed to create album: %@", error.localizedDescription)
            return nil
        }

        guard let localIdentifier else { return nil }
        cacheAlbumID(localIdentifier)
        return fetchAlbum(localIdentifier: localIdentifier)
    }

    private static func cacheAlbumID(_ localIdentifier: String) {
        UserDefaults.standard.set(localIdentifier, forKey: albumIDKey)
    }

    private static func isAlbumAlreadyExistsError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == PHPhotosErrorDomain && nsError.code == 3311
    }

    private static func performSave(image: UIImage, completion: ((Bool) -> Void)?) {
        let album = resolveAlbum()
        PHPhotoLibrary.shared().performChanges {
            let creationRequest = PHAssetChangeRequest.creationRequestForAsset(from: image)
            if let album, let placeholder = creationRequest.placeholderForCreatedAsset {
                PHAssetCollectionChangeRequest(for: album)?.addAssets([placeholder] as NSArray)
            }
        } completionHandler: { success, error in
            if let error {
                NSLog("[GlassesPhotoAlbum] Save failed: %@", error.localizedDescription)
            }
            completion?(success)
        }
    }

    private static func performSave(videoURL: URL) async -> Bool {
        let album = resolveAlbum()
        do {
            try await PHPhotoLibrary.shared().performChanges {
                guard let creationRequest = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: videoURL) else { return }
                if let album, let placeholder = creationRequest.placeholderForCreatedAsset {
                    PHAssetCollectionChangeRequest(for: album)?.addAssets([placeholder] as NSArray)
                }
            }
            return true
        } catch {
            NSLog("[GlassesPhotoAlbum] Video save failed: %@", error.localizedDescription)
            return false
        }
    }
}
