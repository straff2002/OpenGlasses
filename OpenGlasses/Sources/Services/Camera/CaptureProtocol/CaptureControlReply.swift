import Foundation

/// Plan CQ P4 — a reply to a control command, and the one trap in this protocol worth building
/// the parser around.
///
/// # Why "unreadable" is a first-class outcome
///
/// The vendor's own parser fills in the status fields for an allowlist of control sub-types, and
/// that allowlist excludes several sub-types the device really does accept. For those, the reply
/// arrives, the command has *executed*, and the status fields still hold their default — which
/// reads as an error. Anything that treats "no readable success" as "failure" will therefore
/// report working commands as broken, and, worse, retry them.
///
/// So this parser distinguishes three outcomes, not two: it succeeded, it failed, or **we cannot
/// tell from this reply**. Callers must handle the third explicitly. Collapsing it into failure
/// is the bug; collapsing it into success is a different bug.
///
/// Everything here is a community reconstruction, unverified against hardware.
struct CaptureControlReply: Equatable {

    enum Status: Equatable {
        /// Executed, and the reply said so. `workType` is the device's mode indicator.
        case ok(workType: UInt8)
        /// Executed and reported a failure code.
        case failed(code: UInt8)
        /// Structurally valid, but this reply carries no status we can trust. **Not a failure.**
        case unreadable
    }

    /// Which control behaviour this reply is about.
    let subtype: UInt8
    let status: Status
    /// The raw payload, kept so a diagnostics surface or a capture-log replay can show what we
    /// could not interpret.
    let payload: [UInt8]

    /// Control sub-types whose replies leave the status fields unpopulated.
    ///
    /// This is the allowlist gap described above, expressed as its complement. If a capture log
    /// ever shows one of these carrying a real status, remove it from the set — that is the only
    /// change needed, which is why it lives here as data.
    static let subtypesWithoutStatusFields: Set<UInt8> = [0x09, 0x0A, 0x0D, 0x0E]

    // MARK: - Assumed layout
    //
    // Byte offsets within a control reply payload. Grouped and named rather than scattered as
    // literals because they are the least-verified thing in this file: if the reconstruction is
    // wrong about the frame body, it is wrong *here*, and this is where a capture log should be
    // compared first.
    private static let subtypeOffset = 0
    private static let errorCodeOffset = 1
    private static let workTypeOffset = 2
    /// Shortest payload that could carry sub-type, error code and work type.
    private static let minimumStatusPayloadLength = 3

    static func parse(_ payload: [UInt8]) -> CaptureControlReply {
        guard payload.count > subtypeOffset else {
            return CaptureControlReply(subtype: 0, status: .unreadable, payload: payload)
        }
        let subtype = payload[subtypeOffset]

        // Known-gap sub-type: the fields are present but meaningless. Report that we cannot
        // tell, and never manufacture a failure out of a default value.
        guard !subtypesWithoutStatusFields.contains(subtype) else {
            return CaptureControlReply(subtype: subtype, status: .unreadable, payload: payload)
        }

        // Too short to hold a status. Also unreadable rather than failed — a truncated reply
        // says nothing about whether the command ran.
        guard payload.count >= minimumStatusPayloadLength else {
            return CaptureControlReply(subtype: subtype, status: .unreadable, payload: payload)
        }

        let code = payload[errorCodeOffset]
        let status: Status = code == 0
            ? .ok(workType: payload[workTypeOffset])
            : .failed(code: code)
        return CaptureControlReply(subtype: subtype, status: status, payload: payload)
    }

    /// Whether this reply is positive evidence the command failed.
    ///
    /// Named for what it actually means, so a call site cannot accidentally read
    /// `!isSuccess` as failure — on this protocol those are different questions.
    var isConfirmedFailure: Bool {
        if case .failed = status { return true }
        return false
    }

    /// Whether the reply confirms success. False for `.unreadable`, which is not a denial.
    var isConfirmedSuccess: Bool {
        if case .ok = status { return true }
        return false
    }
}
