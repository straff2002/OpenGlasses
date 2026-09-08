import XCTest
@testable import OpenGlasses

/// The single seam that says "a conversation was left behind".
///
/// A thread stops being the active one in six places across the app, and the brain's distillation
/// pass has to run when it does. Rather than a `distill` call copied into all six, the store
/// announces the hand-off once and `AppState` wires that announcement to the brain — so this is
/// the whole contract, and it is a pure test of the store.
@MainActor
final class ConversationThreadHandoffTests: XCTestCase {

    private var tempDir: URL!
    private var store: ConversationStore!
    private var left: [String] = []

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConversationThreadHandoffTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        left = []
        store = ConversationStore(directory: tempDir)
        store.endThread()   // discard any session restored from UserDefaults
        left = []
        store.onThreadLeft = { [weak self] id in self?.left.append(id) }
    }

    override func tearDown() {
        store = nil
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    /// Ending a thread hands its id over — the ordinary end of a session.
    func testEndingAThreadAnnouncesIt() {
        let thread = store.startThread(mode: "direct")
        XCTAssertEqual(left, [], "Starting the first thread leaves nothing behind")
        store.endThread()
        XCTAssertEqual(left, [thread.id])
    }

    /// Starting a thread while another is live is a hand-off too: the old one is what the brain
    /// has to distil, and nobody will ever call `endThread` on it.
    func testStartingAThreadAnnouncesTheOneItReplaced() {
        let first = store.startThread(mode: "direct")
        let second = store.startThread(mode: "direct")
        XCTAssertEqual(left, [first.id], "The replaced thread, not the new one")
        XCTAssertEqual(store.activeThreadId, second.id)
    }

    /// Nothing was left behind, so nothing is announced — a pass over an empty session would only
    /// be noise.
    func testEndingWithNoActiveThreadAnnouncesNothing() {
        store.endThread()
        XCTAssertEqual(left, [])
    }

    /// Resuming is not leaving: the thread being resumed becomes active without the previous one
    /// ending, and the hand-off is announced for the thread that was displaced.
    func testResumingDoesNotAnnounceTheResumedThread() {
        let thread = store.startThread(mode: "direct")
        store.endThread()
        left = []
        _ = store.resumeThread(thread.id)
        XCTAssertEqual(left, [])
    }
}
