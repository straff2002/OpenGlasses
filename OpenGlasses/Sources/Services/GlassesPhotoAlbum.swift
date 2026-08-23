import Photos
import UIKit

enum GlassesPhotoAlbum {
    private static let albumName = "Glasses"
    private static let albumIDKey = "GlassesPhotoAlbumLocalIdentifier"

    static func saveImage(_ image: UIImage, completion: ((Bool) -> Void)? = nil) {
        ensureCanSave { canSave, canUseAlbum in
            guard canSave else {
                NSLog("[GlassesPhotoAlbum] Photo library access denied")
                completion?(false)
                return
            }
            performSave(image: image, useAlbum: canUseAlbum, completion: completion)
        }
    }

    static func saveVideo(at url: URL) async -> Bool {
        let (canSave, canUseAlbum) = await ensureCanSave()
        guard canSave else { return false }
        return await performSave(videoURL: url, useAlbum: canUseAlbum)
    }

    private static func ensureCanSave() async -> (canSave: Bool, canUseAlbum: Bool) {
        await withCheckedContinuation { continuation in
            ensureCanSave { canSave, canUseAlbum in
                continuation.resume(returning: (canSave, canUseAlbum))
            }
        }
    }

    private static func ensureCanSave(completion: @escaping (_ canSave: Bool, _ canUseAlbum: Bool) -> Void) {
        // We only ever ADD new assets here — we never browse or read the user's existing
        // library — so request .addOnly, not .readWrite. .readWrite is what puts the user into
        // the "Select Photos / Allow Full Access" flow, and once they pick "Select Photos" iOS
        // periodically re-shows that picker as a reminder on later library access — that's the
        // repeated prompt on every capture. .addOnly is a plain yes/no grant with no limited-
        // selection state, so it's asked once and never nags again, and it still lets us create
        // the "Glasses" album and add photos to it.
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch status {
        case .authorized, .limited:
            completion(true, true)
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { newStatus in
                let granted = newStatus == .authorized || newStatus == .limited
                completion(granted, granted)
            }
        default:
            completion(false, false)
        }
    }

    private static func resolveAlbum() -> PHAssetCollection? {
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

    private static func performSave(image: UIImage, useAlbum: Bool, completion: ((Bool) -> Void)?) {
        let album = useAlbum ? resolveAlbum() : nil
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

    private static func performSave(videoURL: URL, useAlbum: Bool) async -> Bool {
        let album = useAlbum ? resolveAlbum() : nil
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
