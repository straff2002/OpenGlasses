import Foundation

enum LiveCameraFailureInstruction {
    /// Real images remain the authority even if camera availability changes after setup.
    static func unavailable(reason: String?) -> String {
        let status = reason.map { "Camera startup failed. Tell the user: \($0)" }
            ?? "No camera images are available. Tell the user to check the camera status in the app."
        return """


        VISION:
        You have not received any camera images. \(status)
        A glasses audio or Bluetooth connection does not mean the camera is working.
        Do not claim the camera is still connecting or promise that waiting will fix it.
        If images arrive later, analyze those actual images when asked to look.
        Never guess what the user is looking at without an image.
        """
    }
}
