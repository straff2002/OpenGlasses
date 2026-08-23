import Photos
import UIKit

enum GlassesPhotoAlbum {
    private static let albumName = "Glasses"
    private static let albumIDKey = "GlassesPhotoAlbumLocalIdentifier"

    static func ensureAddOnlyAuthorization() async -> PHAuthorizationStatus {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status != .notDetermined { return status }
        return await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    }

    static func ensureAddOnlyAuthorization(completion: @escaping (PHAuthorizationStatus) -> Void) {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status != .notDetermined {
            completion(status)
            return
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly, handler: completion)
    }

    static func resolveAlbum() -> PHAssetCollection? {
        if let cachedID = UserDefaults.standard.string(forKey: albumIDKey),
           let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [cachedID], options: nil).firstObject {
            return album
        }
        return createAlbum()
    }

    private static func createAlbum() -> PHAssetCollection? {
        var localIdentifier: String?
        do {
            try PHPhotoLibrary.shared().performChangesAndWait {
                let createRequest = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: albumName)
                localIdentifier = createRequest.placeholderForCreatedAssetCollection.localIdentifier
            }
        } catch {
            NSLog("[GlassesPhotoAlbum] Failed to create album: %@", error.localizedDescription)
            return nil
        }
        guard let localIdentifier else { return nil }
        UserDefaults.standard.set(localIdentifier, forKey: albumIDKey)
        return PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [localIdentifier], options: nil).firstObject
    }
}
