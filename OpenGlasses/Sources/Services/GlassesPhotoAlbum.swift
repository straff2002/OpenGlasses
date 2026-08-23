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

    static func saveImage(_ image: UIImage, completion: ((Bool) -> Void)? = nil) {
        ensureAddOnlyAuthorization { status in
            guard status == .authorized else {
                NSLog("[GlassesPhotoAlbum] Photo library add access denied")
                completion?(false)
                return
            }
            performSave(image: image, completion: completion)
        }
    }

    static func saveVideo(at url: URL) async -> Bool {
        let status = await ensureAddOnlyAuthorization()
        guard status == .authorized else { return false }
        return await performSave(videoURL: url)
    }

    private static var canOrganizeIntoAlbum: Bool {
        PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
    }

    private static func resolveAlbumIfAllowed() -> PHAssetCollection? {
        guard canOrganizeIntoAlbum else { return nil }
        if let cachedID = UserDefaults.standard.string(forKey: albumIDKey),
           let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [cachedID], options: nil).firstObject {
            return album
        }
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

    private static func performSave(image: UIImage, completion: ((Bool) -> Void)?) {
        let album = resolveAlbumIfAllowed()
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
        let album = resolveAlbumIfAllowed()
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
