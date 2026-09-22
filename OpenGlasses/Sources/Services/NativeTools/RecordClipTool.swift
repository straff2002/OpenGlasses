import Foundation

/// "Record a clip of this" — a short, length-capped video of the job (Plan FO P2b).
///
/// The sibling of `photo_log`, for the faults a still cannot show: a compressor short-cycling, a
/// fan wobbling, a flame lifting, a relay chattering. Like `photo_log` it files the result under
/// the open job's own evidence, and like `photo_log` it asks no question at the time — what of it
/// goes to the customer is decided once, at close, in the evidence review.
///
/// It refuses rather than improvises. No job open, or a camera that is not currently producing
/// pictures, is a spoken refusal — never a black clip, and never a thirty-second recording of the
/// last frame the glasses managed before they went flat.
@MainActor
struct RecordClipTool: NativeTool {
    let name = "record_clip"
    let description = """
    Record a short video clip of what the technician is looking at and file it with the open job — \
    "record a clip of this", "get a video of that noise", "film this while it's doing it", \
    "stop the clip". Use it for a fault a photograph cannot show: something moving, cycling, \
    vibrating or arcing. Pass 'action' ("start" or "stop"; start is assumed), an optional \
    'caption' saying what the clip shows, and optional 'seconds' when the technician asks for a \
    particular length — otherwise it runs to the standard limit and stops itself. The clip is \
    silent, is capped in length, and stays on the phone with the job until the technician chooses \
    at close whether it goes to the customer. Requires a job to be open and the glasses camera to \
    be streaming; if either is missing the tool says so instead of recording nothing.
    """
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": [
                "type": "string",
                "enum": ["start", "stop", "status"],
                "description": "Start a clip, stop the one running, or report on it. Defaults to start."
            ],
            "caption": [
                "type": "string",
                "description": "What the clip shows, in the technician's own words. Printed under it in the report."
            ],
            "seconds": [
                "type": "number",
                "description": "How long to record for. Clamped to the app's clip limit; omit for the standard length."
            ]
        ],
        "required": [] as [String]
    ]

    /// How the tool reaches the recorder. Injected so a headless test drives the whole tool
    /// without an `AppState`, a camera or a relay.
    struct Seams {
        var start: (String?, TimeInterval?) -> Result<TimeInterval, JobClipRecorder.StartRefusal>
        var stop: () async -> JobClipRecorder.Finished?
        var isRecording: () -> Bool
        var elapsed: () -> TimeInterval
    }

    private let seams: Seams

    init(seams: Seams) {
        self.seams = seams
    }

    /// The app's own recorder. A second initialiser rather than a default argument, because a
    /// default is evaluated outside the actor and every closure here is main-actor state.
    init() {
        self.init(seams: Seams(
            start: { caption, seconds in
                guard let app = AppStateProvider.shared else {
                    return .failure(.couldNotWrite)
                }
                return app.startJobClip(caption: caption, seconds: seconds)
            },
            stop: { await AppStateProvider.shared?.stopJobClip() },
            isRecording: { AppStateProvider.shared?.jobClips.isRecording ?? false },
            elapsed: { AppStateProvider.shared?.jobClips.elapsed ?? 0 }))
    }

    func execute(args: [String: Any]) async throws -> String {
        guard Config.fieldAssistActive else {
            return "Field Assist is disabled. Enable it in Settings → Field Assist."
        }
        switch (args["action"] as? String)?.lowercased() ?? "start" {
        case "stop":
            guard seams.isRecording() else { return "No clip is being recorded." }
            guard let finished = await seams.stop() else {
                return "The clip stopped, but nothing could be saved — no video was written."
            }
            return finished.spoken + " It stays with the job until you choose what goes to the "
                + "customer when the job is closed."

        case "status":
            guard seams.isRecording() else { return "No clip is being recorded." }
            let elapsed = Int(seams.elapsed().rounded())
            return "Recording a clip — \(elapsed) second\(elapsed == 1 ? "" : "s") so far."

        default:
            let caption = (args["caption"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let seconds = (args["seconds"] as? NSNumber)?.doubleValue ?? args["seconds"] as? Double
            switch seams.start(caption?.isEmpty == false ? caption : nil, seconds) {
            case .failure(let refusal):
                return refusal.spoken
            case .success(let cap):
                let whole = Int(cap.rounded())
                var line = "Recording — up to \(whole) second\(whole == 1 ? "" : "s"). "
                    + "Say stop the clip when you've got it, or it stops itself at the limit."
                if let seconds, seconds > cap {
                    line = "That's longer than a job clip goes; I'll record \(whole) seconds. "
                        + line
                }
                return line
            }
        }
    }
}
