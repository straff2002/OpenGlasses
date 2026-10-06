import Foundation

/// Plan HP P1 item 1 — carries an existing install across a capability whose default changed.
///
/// Face recognition used to default **on** and now defaults **off** (EU AI Act review §3.1: a
/// biometric identification feature should be something a wearer chooses, not something they
/// find running). The owner's constraint is that nobody who already had the capability loses it
/// because a default moved. The default alone cannot tell those two people apart — an install that
/// never touched the switch reads the default either way — so this decides once, at the first
/// launch of the build that changed it, and writes the answer down as a stored value.
///
/// The decision is pure (`decide(_:)`), so the four corners and idempotence are tested without
/// `UserDefaults` or a face database; `run(defaults:faceDatabaseHasEntries:)` is the thin adapter
/// that reads the real inputs and writes the result.
enum CapabilityDefaultMigration {

    /// The preferences key the migration seeds. The same key `Config.faceRecognitionEnabled` and
    /// the registry's switch use.
    static let faceRecognitionKey = "faceRecognitionEnabled"

    /// Written once the migration has decided, whatever it decided. Versioned so a later default
    /// change can run its own pass without being mistaken for this one.
    static let doneKey = "capabilityDefaultMigration.faceRecognition.v1"

    /// The preference `Config.hasCompletedOnboarding` reads.
    static let onboardingKey = "hasCompletedOnboarding"

    /// What the decision is made from. Plain values, so a test states each corner directly.
    struct Inputs: Equatable {
        /// The `faceRecognitionEnabled` key holds a stored value — the wearer, a test or an earlier
        /// build wrote it. Whatever is there is a choice somebody made, and it is kept.
        var keyEverWritten: Bool
        /// Onboarding was completed before this launch: the install predates this build.
        var hasCompletedOnboarding: Bool
        /// At least one face is enrolled. Someone who enrolled a face used the capability.
        var faceDatabaseHasEntries: Bool
        /// The migration already ran on this install.
        var alreadyMigrated: Bool
    }

    enum Decision: Equatable {
        /// An existing user: keep face recognition on, as it was.
        case seedOn
        /// A fresh install: store the new default, off, so a later default change cannot flip it.
        case seedOff
        /// Nothing to do: already migrated, or the switch already holds a value.
        case leaveAlone
    }

    /// The rule. Order matters: the done-marker and a stored value both win over every other input,
    /// so running twice — or running after the wearer set the switch — changes nothing.
    static func decide(_ inputs: Inputs) -> Decision {
        if inputs.alreadyMigrated || inputs.keyEverWritten { return .leaveAlone }
        if inputs.hasCompletedOnboarding || inputs.faceDatabaseHasEntries { return .seedOn }
        return .seedOff
    }

    /// Read the inputs, apply the decision, and mark the migration done. Must run at launch before
    /// anything reads `AIFeatureGate` — `OpenGlassesApp.init()` calls it beside the other
    /// once-behind-a-flag migrations.
    ///
    /// Writes the raw key rather than going through `Config.faceRecognitionEnabled`'s setter: the
    /// setter is refused while an organisation profile locks the key, and the person's own stored
    /// value is what a ceiling clamps on read, so it must still be recorded.
    @discardableResult
    static func run(defaults: UserDefaults = .standard,
                    faceDatabaseHasEntries: () -> Bool = { knownFacesFileHasEntries() }) -> Decision {
        let alreadyMigrated = defaults.bool(forKey: doneKey)
        let keyEverWritten = defaults.object(forKey: faceRecognitionKey) != nil
        // Skip the file read when the answer cannot depend on it.
        let needsDatabase = !alreadyMigrated && !keyEverWritten && !defaults.bool(forKey: onboardingKey)
        let inputs = Inputs(keyEverWritten: keyEverWritten,
                            hasCompletedOnboarding: defaults.bool(forKey: onboardingKey),
                            faceDatabaseHasEntries: needsDatabase ? faceDatabaseHasEntries() : false,
                            alreadyMigrated: alreadyMigrated)
        let decision = decide(inputs)
        switch decision {
        case .seedOn: defaults.set(true, forKey: faceRecognitionKey)
        case .seedOff: defaults.set(false, forKey: faceRecognitionKey)
        case .leaveAlone: break
        }
        defaults.set(true, forKey: doneKey)
        return decision
    }

    /// Whether the wearer's face database holds at least one enrolled face.
    ///
    /// Reads `Documents/known_faces.json` the way `FaceRecognitionService` does — opened through the
    /// `.faces` keyring, then decoded — without constructing the service, which is main-actor bound
    /// and observes the camera. A file that exists but cannot be read (a locked keychain on a
    /// background launch, say) counts as **non-empty**: the owner's rule is that an existing user
    /// keeps the capability, so an unreadable database errs toward keeping it.
    static func knownFacesFileHasEntries(directory: URL? = nil,
                                         keyring: ScopedKeyring = .shared) -> Bool {
        guard let docs = directory
                ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return false
        }
        let url = docs.appendingPathComponent("known_faces.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        do {
            let raw = try Data(contentsOf: url)
            let data = try keyring.open(raw, for: .faces)
            let faces = try JSONDecoder().decode([FaceRecognitionService.KnownFace].self, from: data)
            return !faces.isEmpty
        } catch {
            return true
        }
    }
}
