import XCTest
@testable import OpenGlasses

/// Issue 427: a conversations file that could not be read at launch blocked saves for the rest of
/// the process.
///
/// The file is written with `.completeFileProtection`, so an app that launches before the device's
/// first unlock reads Cocoa 257 and latches `saveBlocked`. `loadThreads()` only ever ran from
/// `init`, and `protectedDataDidBecomeAvailable()` rebuilt recall from memory without re-reading —
/// so nothing could ever clear the latch. Field trace: launched 07:19 locked, active at 07:51,
/// every single turn afterwards dropped with `saveSkipped detail=loadFailed`.
@MainActor
final class ConversationStoreLoadRetryTests: XCTestCase {

    private var tempDir: URL!
    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConversationStoreLoadRetryTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        fileURL = tempDir.appendingPathComponent("conversations.json")
    }

    override func tearDown() {
        // Always restore permissions or the directory cannot be removed.
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)
        try? FileManager.default.removeItem(at: tempDir)
        Config.setConversationEncryptionEnabled(false)
        super.tearDown()
    }

    private func writeThreads(_ threads: [ConversationThread]) throws {
        try JSONEncoder().encode(threads).write(to: fileURL, options: .atomic)
    }

    private func readThreadsFromDisk() throws -> [ConversationThread] {
        try JSONDecoder().decode([ConversationThread].self, from: Data(contentsOf: fileURL))
    }

    /// Makes the file unreadable and confirms the OS actually enforces it in this test process —
    /// a root test runner could read a 0o000 file and quietly invalidate the whole scenario.
    private func denyReadsOrSkip() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o000],
                                              ofItemAtPath: fileURL.path)
        if (try? Data(contentsOf: fileURL)) != nil {
            throw XCTSkip("this process can read a 0o000 file (running as root?) — "
                          + "the unreadable-load path cannot be simulated here")
        }
    }

    func testLoadFailureBlocksSavesAndTheUnlockRetryRestoresThem() throws {
        let onDisk = ConversationThread(mode: "direct", title: "Written before the lock")
        try writeThreads([onDisk])

        try denyReadsOrSkip()

        // Launch with the file unreadable — exactly the locked-device case.
        let store = ConversationStore(directory: tempDir)
        XCTAssertTrue(store.saveBlocked, "an unreadable existing file must block saves")
        XCTAssertTrue(store.threads.isEmpty, "nothing was loaded")

        // A conversation happens anyway. It lives only in memory: the save is refused.
        let live = store.startThread(mode: "direct", personaId: nil)
        store.appendMessage(role: "user", content: "does this survive the unlock?")
        XCTAssertTrue(store.saveBlocked, "still blocked — nothing has re-read the file")

        // The device is unlocked: protected data becomes available.
        try FileManager.default.setAttributes([.posixPermissions: 0o644],
                                              ofItemAtPath: fileURL.path)
        store.protectedDataDidBecomeAvailable()

        XCTAssertFalse(store.saveBlocked, "a successful re-read must lift the latch")
        let ids = Set(store.threads.map(\.id))
        XCTAssertEqual(ids, [onDisk.id, live.id],
                       "the on-disk thread is recovered and the unsaved live one is kept")

        // And the merged set is now actually on disk — the retry persists it.
        let persisted = try readThreadsFromDisk()
        XCTAssertEqual(Set(persisted.map(\.id)), [onDisk.id, live.id])
        XCTAssertEqual(persisted.first(where: { $0.id == live.id })?.messages.count, 1)

        // Saves work from here on.
        store.appendMessage(role: "assistant", content: "it did")
        XCTAssertFalse(store.saveBlocked)
        XCTAssertEqual(try readThreadsFromDisk().first(where: { $0.id == live.id })?.messages.count, 2)
    }

    /// A file that is still unreadable when the notification fires must leave the latch on —
    /// writing now would put an empty history over data that may be perfectly intact.
    func testRetryLeavesSavesBlockedWhileTheFileIsStillUnreadable() throws {
        let onDisk = ConversationThread(mode: "direct", title: "Untouched")
        try writeThreads([onDisk])
        try denyReadsOrSkip()

        let store = ConversationStore(directory: tempDir)
        XCTAssertTrue(store.saveBlocked)

        store.protectedDataDidBecomeAvailable()
        XCTAssertTrue(store.saveBlocked, "still unreadable — the store must stay closed for writes")

        // The original bytes are untouched.
        try FileManager.default.setAttributes([.posixPermissions: 0o644],
                                              ofItemAtPath: fileURL.path)
        XCTAssertEqual(try readThreadsFromDisk().map(\.id), [onDisk.id])
    }

    /// The merge keeps the store's newest-first ordering rather than parking a brand-new
    /// conversation at the bottom of the list.
    func testMergedThreadsStayNewestFirst() throws {
        let old = ConversationThread(mode: "direct", title: "Older")
        try writeThreads([old])
        try denyReadsOrSkip()

        let store = ConversationStore(directory: tempDir)
        let live = store.startThread(mode: "direct", personaId: nil)

        try FileManager.default.setAttributes([.posixPermissions: 0o644],
                                              ofItemAtPath: fileURL.path)
        store.protectedDataDidBecomeAvailable()

        XCTAssertEqual(store.threads.first?.id, live.id,
                       "the thread started during the outage is the most recent one")
    }

    // MARK: - Encrypted stores

    /// The retry must never hand an encrypted file to the plaintext reader.
    ///
    /// `ConversationEncryptionService.isFileEncrypted(at:)` answers `false` for a file it cannot
    /// *read*, so a locked-device launch with encryption on latches `saveBlocked` down the same
    /// plaintext branch an unencrypted store takes. If the retry then re-read it as plaintext, the
    /// `OGENC1` bytes would decode as `.corrupt`, `StoreRecovery` would move the user's history
    /// aside, and `save()` would write an empty file over the top — a save outage turned into data
    /// loss for exactly the wearers who opted into more protection.
    ///
    /// The decrypt itself cannot succeed in a test process (no Keychain key, so `retrieveKey()`
    /// returns `errSecItemNotFound` without prompting — and any other Keychain outcome fails the
    /// same way on a payload that was never sealed with a real key). That is the point: whatever
    /// the decrypt does, the ciphertext on disk must come back byte-for-byte identical.
    func testEncryptedFileIsNotClobberedByTheRetry() throws {
        Config.setConversationEncryptionEnabled(true)

        // A plausible encrypted file: the magic header plus opaque bytes.
        var ciphertext = Data("OGENC1".utf8)
        ciphertext.append(Data(repeating: 0xAB, count: 256))
        try ciphertext.write(to: fileURL, options: .atomic)

        try denyReadsOrSkip()

        let store = ConversationStore(directory: tempDir)
        XCTAssertTrue(store.saveBlocked,
                      "an unreadable file latches the same way whether or not it is encrypted")

        // A conversation happens during the outage, as in the plaintext case.
        _ = store.startThread(mode: "direct", personaId: nil)
        store.appendMessage(role: "user", content: "written while saves were blocked")

        // Protected data becomes available.
        try FileManager.default.setAttributes([.posixPermissions: 0o644],
                                              ofItemAtPath: fileURL.path)
        store.protectedDataDidBecomeAvailable()

        // Taking the decrypt branch is observable: only that branch closes the store while it runs.
        XCTAssertTrue(store.isLocked,
                      "an encrypted file must go through the decrypt path, not the plaintext reader")
        XCTAssertTrue(store.saveBlocked,
                      "the latch stays on until a decrypt actually succeeds")

        // The bytes are the whole point.
        XCTAssertEqual(try Data(contentsOf: fileURL), ciphertext,
                       "the encrypted history must be untouched by the retry")
    }

    /// The decrypt branch actually runs, actually fails here, and still leaves the file alone.
    ///
    /// The wait is observable rather than timed: a local `DiagnosticRing` taps the privacy log and
    /// the test blocks until the failure event appears, so this cannot pass by asserting before the
    /// task has run.
    func testFailedDecryptLeavesTheStoreClosedAndTheFileIntact() async throws {
        Config.setConversationEncryptionEnabled(true)

        var ciphertext = Data("OGENC1".utf8)
        ciphertext.append(Data(repeating: 0xCD, count: 128))
        try ciphertext.write(to: fileURL, options: .atomic)

        try denyReadsOrSkip()
        let store = ConversationStore(directory: tempDir)
        XCTAssertTrue(store.saveBlocked)

        let ring = DiagnosticRing(capacity: 200)
        ring.attach()
        defer { ring.detach() }

        try FileManager.default.setAttributes([.posixPermissions: 0o644],
                                              ofItemAtPath: fileURL.path)
        store.protectedDataDidBecomeAvailable()

        // Wait for the decrypt task to report its failure.
        var reported = false
        for _ in 0..<200 {
            if ring.entries.contains(where: { $0.line.contains("awaitingAuthentication") }) {
                reported = true
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(reported,
                      "the retry must have gone through the decrypt path and reported its failure")

        XCTAssertTrue(store.isLocked, "a store whose decrypt failed stays closed")
        XCTAssertTrue(store.saveBlocked, "and stays unwritable")
        XCTAssertEqual(try Data(contentsOf: fileURL), ciphertext,
                       "the ciphertext is untouched by a failed retry")
    }
}
