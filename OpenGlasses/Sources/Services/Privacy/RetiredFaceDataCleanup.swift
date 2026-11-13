import Foundation

/// Removes what face recognition left on the phone. Face recognition was removed from the app on
/// 2026-11-13: Meta's Wearables Developer Acceptable Use Policy does not allow glasses sensors to
/// be used to identify people from their faces, and it was the one feature that made the app a
/// remote biometric identification system under the EU AI Act.
///
/// A wearer who enrolled anyone still has their templates on disk: `Documents/known_faces.json`,
/// sealed under the `.faces` scoped key, plus a few preferences. Those are biometric data about
/// people who never installed the app, and the feature that justified keeping them is gone, so
/// they are erased at the first launch of a build without it — not left as a dead store.
///
/// The erasure is the class erasure the app already has (`ScopedKeyring.eraseClass`): the key is
/// destroyed first, then the file, so a copy in a snapshot or an old backup is ciphertext nobody
/// can open. It runs at launch until it has completed once — a Keychain that cannot be reached
/// before first unlock leaves the done-marker unset, so the next launch tries again — and again
/// whenever the database file is found, should one ever come back with a restored container. It
/// writes no erasure-ledger entry: nobody asked for this erasure, and there is nothing to replay.
enum RetiredFaceDataCleanup {

    /// Written once the key is destroyed and the file is gone.
    static let doneKey = "retiredFaceRecognitionCleanup.v1"

    /// Where the face database lived, relative to the Documents directory.
    static let databaseFileName = "known_faces.json"

    /// The preferences face recognition kept: its switch, its near-tie margin, and the marker of
    /// the migration that carried its default from on to off.
    static let retiredPreferenceKeys = [
        "faceRecognitionEnabled",
        "faceMatchAmbiguityMargin",
        "capabilityDefaultMigration.faceRecognition.v1",
    ]

    enum Outcome: Equatable {
        /// Done on an earlier launch, and no database has come back since.
        case alreadyDone
        /// The key is destroyed and the database, if there was one, removed.
        case erased(filesRemoved: Int)
        /// The key could not be destroyed or the file could not be removed. Tried again next launch.
        case incomplete
    }

    /// The database's location under `directory` (the Documents directory by default).
    static func databaseURL(in directory: URL? = nil, fileManager: FileManager = .default) -> URL? {
        let docs = directory ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
        return docs?.appendingPathComponent(databaseFileName)
    }

    /// Erase what is left. Must run at launch beside the other once-behind-a-flag migrations;
    /// `OpenGlassesApp.init()` calls it. Cheap once done: one preference read and one file check.
    @discardableResult
    static func run(defaults: UserDefaults = .standard,
                    directory: URL? = nil,
                    keyring: ScopedKeyring = .shared,
                    fileManager: FileManager = .default) -> Outcome {
        let database = databaseURL(in: directory, fileManager: fileManager)
        let databaseIsBack = database.map { fileManager.fileExists(atPath: $0.path) } ?? false
        if defaults.bool(forKey: doneKey) && !databaseIsBack { return .alreadyDone }

        let receipt = keyring.eraseClass(.faces, files: database.map { [$0] } ?? [],
                                         fileManager: fileManager)
        for key in retiredPreferenceKeys { defaults.removeObject(forKey: key) }
        guard receipt.keyDestroyed, receipt.failures == 0 else { return .incomplete }
        defaults.set(true, forKey: doneKey)
        return .erased(filesRemoved: receipt.filesRemoved)
    }
}
