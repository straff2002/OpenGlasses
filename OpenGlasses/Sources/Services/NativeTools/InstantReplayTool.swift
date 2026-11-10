import Foundation

/// "Keep the last 30 seconds" — save part of the Instant Replay buffer (Instant Replay §6).
///
/// The one camera tool that looks backwards. It never starts the camera: the buffer exists only
/// while the glasses camera is already streaming for something else, and when it isn't, the tool
/// says why. It does not claim the bare "save that", which a job debrief already answers to.
@MainActor
struct InstantReplayTool: NativeTool {
    let name = "instant_replay"
    let description = """
    Keep a moment that has just happened on the glasses camera, from Instant Replay's rolling \
    buffer — "keep the last 30 seconds", "save the replay", "save the last minute", "save the \
    replay to the job", "save the replay to Photos", "is instant replay on?". Pass 'action' \
    ("save", the default, or "status"), optional 'seconds' (default 30, at most what the buffer \
    keeps), optional 'destination' ("recordings", the default; "job" only when the wearer says \
    the job, which needs a job open and keeps at most a minute; "photos" only when they say \
    Photos) and an optional 'caption' for a job clip. The clip is silent. Instant Replay only runs \
    while the camera is already on for something else and is off unless the wearer turned it on \
    in Settings; it never starts the camera, and when it isn't running the tool says why.
    """
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": [
                "type": "string",
                "enum": ["save", "status"],
                "description": "Save part of the buffer, or report whether it is running. Defaults to save."
            ],
            "seconds": [
                "type": "number",
                "description": "How far back to keep, in seconds. Defaults to 30."
            ],
            "destination": [
                "type": "string",
                "enum": ["recordings", "job", "photos"],
                "description": "Where it goes: Recordings unless the wearer named the job or Photos."
            ],
            "caption": [
                "type": "string",
                "description": "What a job clip shows, in the technician's own words."
            ]
        ],
        "required": [] as [String]
    ]

    /// How the tool reaches the buffer. Injected so a headless test drives it with no `AppState`.
    struct Seams {
        var save: (ReplaySaveRequest) async -> ReplaySaveOutcome
        var status: () -> String
    }

    private let seams: Seams

    init(seams: Seams) {
        self.seams = seams
    }

    /// The app's own buffer. A second initialiser rather than a default argument, because a
    /// default is evaluated outside the actor and every closure here is main-actor state.
    init() {
        self.init(seams: Seams(
            save: { request in
                guard let app = AppStateProvider.shared else {
                    return ReplaySaveOutcome(result: .refused(.couldNotSave))
                }
                return await app.saveInstantReplay(request)
            },
            status: { AppStateProvider.shared?.instantReplay.statusLine
                ?? ReplayOffReason.cameraOff.spoken }))
    }

    func execute(args: [String: Any]) async throws -> String {
        switch (args["action"] as? String)?.lowercased() ?? "save" {
        case "status":
            return seams.status()
        default:
            return await seams.save(ReplaySaveRequest(arguments: args)).spoken
        }
    }
}
