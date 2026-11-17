#if DAT_EXPERIMENTAL
import Foundation
import MWDATCore

// Plan JV P1: the only code that touches the SDK's [Experimental] voice invocations. Compiled only
// in a project generated with AVENKIN_DAT_EXPERIMENTAL=1 (TestFlight only, never submitted for
// review).

/// Voice-invocation streams from Meta's SDK: one `VoiceInvocationsStream` per connected device,
/// created with `Wearables.shared` and started for that device. It needs no `DeviceSession`.
struct MetaVoiceInvocationSource: VoiceInvocationSource {

    func openChannel(deviceId: String,
                     onRequest: @escaping @MainActor @Sendable (VoiceInvocationRequest) -> Void,
                     onFailure: @escaping @MainActor @Sendable (VoiceInvocationFailure) -> Void) throws
        -> VoiceInvocationChannel {
        // The link is up, so the SDK has been configured; this only makes that the permission to
        // touch `Wearables.shared`, as everywhere else.
        guard WearablesBootstrap.ensureConfigured() else { throw VoiceInvocationError.invalidWearablesInterface }
        return try MetaVoiceInvocationChannel(deviceId: deviceId, onRequest: onRequest, onFailure: onFailure)
    }

    func failure(for error: Error) -> VoiceInvocationFailure {
        guard let error = error as? VoiceInvocationError else { return .unknown }
        return Self.failure(error)
    }

    /// Not frozen: a case added in a later SDK is `.unknown` until it is read and named here.
    nonisolated static func failure(_ error: VoiceInvocationError) -> VoiceInvocationFailure {
        switch error {
        case .deviceNotFound: return .deviceNotFound
        case .invalidWearablesInterface: return .invalidWearablesInterface
        case .channelNotConnected: return .channelNotConnected
        case .channelError: return .channelError
        case .failToSendInitRequest: return .failToSendInitRequest
        case .failToSendMessage: return .failToSendMessage
        case .initRequestError: return .initRequestError
        case .invalidActionMessageProto: return .invalidActionMessageProto
        case .unknownMessageType: return .unknownMessageType
        case .actionFailed: return .actionFailed
        case .invalidSessionState: return .invalidSessionState
        @unknown default: return .unknown
        }
    }
}

/// One device's stream. Its two listeners are kept in a `ListenerTokenBag` and cancelled together
/// when the stream stops.
@MainActor
final class MetaVoiceInvocationChannel: VoiceInvocationChannel {
    private let deviceId: String
    private let stream: VoiceInvocationsStream
    private let tokens = ListenerTokenBag()

    init(deviceId: String,
         onRequest: @escaping @MainActor @Sendable (VoiceInvocationRequest) -> Void,
         onFailure: @escaping @MainActor @Sendable (VoiceInvocationFailure) -> Void) throws {
        self.deviceId = deviceId
        stream = try VoiceInvocationsStream(wearables: Wearables.shared)
        stream.invocationsPublisher.listen { invocation in
            // "Launch" is the only request the SDK sends today; another has no handle the app
            // knows how to answer, so it is only recorded.
            guard let launch = invocation as? LaunchApp else {
                Task { @MainActor in onFailure(.unsupportedInvocation) }
                return
            }
            let handle = launch.responseHandle
            let request = VoiceInvocationRequest(deviceId: deviceId) { success, actionOutput in
                success
                    ? await handle.sendSuccess(actionOutput: actionOutput)
                    : await handle.sendFailure(actionOutput: actionOutput)
            }
            Task { @MainActor in onRequest(request) }
        }.store(in: tokens)
        stream.errorPublisher.listen { error in
            let failure = MetaVoiceInvocationSource.failure(error)
            Task { @MainActor in onFailure(failure) }
        }.store(in: tokens)
    }

    func start() throws {
        try stream.start(deviceIdentifier: deviceId)
    }

    func stop() {
        stream.stop()
        let tokens = tokens
        Task { await tokens.cancelAll() }
    }
}
#endif
