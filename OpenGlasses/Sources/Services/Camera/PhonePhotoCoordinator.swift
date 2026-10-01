import Foundation
import Combine

/// One request for the user to take a photo on the phone (Plan GV).
struct PhonePhotoRequest: Identifiable, Equatable {
    let id: UUID
    /// The tool asking, or nil for a tile's own photo before its prompt.
    let toolName: String?
    /// One line shown over the camera, saying what to frame.
    let hint: String

    init(id: UUID = UUID(), toolName: String?, hint: String) {
        self.id = id
        self.toolName = toolName
        self.hint = hint
    }
}

/// The seam `CameraService` asks for a phone photo through. Tests fake it; the app's conformance
/// is `PhonePhotoCoordinator`.
@MainActor
protocol PhonePhotoRequesting: AnyObject {
    /// Suspends until the user takes the photo or the request ends. Never throws: every ending is
    /// an outcome the caller turns into a sentence.
    func requestPhoto(_ request: PhonePhotoRequest) async -> PhonePhotoOutcome
}

/// Owns the phone-camera request a tool call is waiting on.
///
/// At most one request is open at a time — a second is answered `.busy` rather than queued, since
/// two cameras in a row from one sentence confuse more than they help, and the model can ask
/// again. The root view presents `pending` from any tab and reports back through `fulfil`,
/// `cancel` and `notePresented`. Every way out — photo, cancel, timeout, the camera never
/// appearing, the waiting task being cancelled — resumes the caller exactly once.
@MainActor
final class PhonePhotoCoordinator: ObservableObject, PhonePhotoRequesting {

    /// The request the camera sheet should be showing, if any.
    @Published private(set) var pending: PhonePhotoRequest?

    /// Whether a camera can be put on screen now. Wired to the application state by `AppState`;
    /// the default keeps the coordinator constructible in tests.
    var isAppActive: () -> Bool = { true }
    /// Called when the camera opens and when it closes, so the turn's audio can step aside.
    var onWaitBegan: (() -> Void)?
    var onWaitEnded: (() -> Void)?

    private let timeout: TimeInterval
    private let presentationGrace: TimeInterval
    private let stagedLifetime: TimeInterval
    private let sleep: @MainActor (TimeInterval) async -> Void
    private let now: () -> Date

    private var continuation: CheckedContinuation<PhonePhotoOutcome, Never>?
    private var presented = false
    private var timers: [Task<Void, Never>] = []
    private var staged: (data: Data, expires: Date)?

    init(timeout: TimeInterval = PhoneCapturePolicy.requestTimeout,
         presentationGrace: TimeInterval = PhoneCapturePolicy.presentationGrace,
         stagedLifetime: TimeInterval = PhoneCapturePolicy.stagedPhotoLifetime,
         sleep: (@MainActor (TimeInterval) async -> Void)? = nil,
         now: @escaping () -> Date = Date.init) {
        self.timeout = timeout
        self.presentationGrace = presentationGrace
        self.stagedLifetime = stagedLifetime
        self.sleep = sleep ?? { seconds in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
        self.now = now
    }

    // MARK: - Requests

    /// A tool's request. Takes a photo a tile staged for this turn before opening the camera.
    func requestPhoto(_ request: PhonePhotoRequest) async -> PhonePhotoOutcome {
        if let data = takeStaged() { return .photo(data) }
        return await present(request)
    }

    /// A tile's own photo, taken before its prompt is sent. Never consumes a staged photo.
    func preCapture(hint: String) async -> PhonePhotoOutcome {
        await present(PhonePhotoRequest(toolName: nil, hint: hint))
    }

    private func present(_ request: PhonePhotoRequest) async -> PhonePhotoOutcome {
        guard pending == nil else { return .busy }
        guard isAppActive() else { return .appNotOnScreen }
        guard !Task.isCancelled else { return .cancelled }
        let id = request.id
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<PhonePhotoOutcome, Never>) in
                self.continuation = continuation
                self.presented = false
                self.pending = request
                self.onWaitBegan?()
                self.startTimers(for: id)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resolve(id, .cancelled) }
        }
    }

    // MARK: - From the camera view

    /// The user took the photo.
    func fulfil(_ id: UUID, data: Data) { resolve(id, .photo(data)) }

    /// The user closed the camera (or the capture failed — the view treats both the same).
    func cancel(_ id: UUID) { resolve(id, .cancelled) }

    /// The camera view is on screen. Disarms the presentation watchdog.
    func notePresented(_ id: UUID) {
        guard pending?.id == id else { return }
        presented = true
    }

    // MARK: - Staged photo (Field Assist tiles)

    /// Keep a tile's photo for the first camera request of its turn.
    func stage(_ data: Data) {
        staged = (data, now().addingTimeInterval(stagedLifetime))
    }

    /// Forget a staged photo the turn did not use.
    func clearStaged() { staged = nil }

    var hasStagedPhoto: Bool {
        guard let staged else { return false }
        return staged.expires > now()
    }

    private func takeStaged() -> Data? {
        defer { staged = nil }
        guard let staged, staged.expires > now() else { return nil }
        return staged.data
    }

    // MARK: - Ending

    private func startTimers(for id: UUID) {
        let grace = presentationGrace
        let limit = timeout
        timers = [
            Task { @MainActor [weak self] in
                await self?.sleep(grace)
                guard let self, !Task.isCancelled, self.pending?.id == id, !self.presented else { return }
                self.resolve(id, .couldNotPresent)
            },
            Task { @MainActor [weak self] in
                await self?.sleep(limit)
                guard let self, !Task.isCancelled else { return }
                self.resolve(id, .timedOut)
            },
        ]
    }

    private func resolve(_ id: UUID, _ outcome: PhonePhotoOutcome) {
        guard pending?.id == id, let continuation else { return }
        self.continuation = nil
        pending = nil
        presented = false
        timers.forEach { $0.cancel() }
        timers = []
        onWaitEnded?()
        continuation.resume(returning: outcome)
    }
}
