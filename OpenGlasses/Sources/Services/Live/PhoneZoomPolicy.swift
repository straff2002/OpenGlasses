import Foundation
import CoreGraphics

/// Plan CB P3 — pinch-zoom arithmetic for the phone-camera capture sheet (pure).
///
/// Zooming at the sensor beats enlarging after the fact: the detail is *captured* larger, so the
/// preview and the captured still improve together — both come off the same session. Two rules
/// worth writing down:
///
/// - **Cap at 8×.** Past roughly there the wide-angle sensor is upscaling, which spends bytes
///   without adding detail — the opposite of the point. The device's own `videoMaxZoomFactor` is
///   respected when it is lower.
/// - **A magnification gesture reports scale against its own start**, not the last committed
///   value. The zoom at gesture start is captured once and multiplied — accumulating the deltas
///   instead makes zoom run away quadratically mid-gesture.
enum PhoneZoomPolicy {

    /// Hard ceiling before the sensor is just upscaling.
    static let maxUsefulZoom: CGFloat = 8.0

    /// Zoom factors below this render no on-screen readout: at rest a label would sit on top of
    /// the scene for no reason.
    static let readoutThreshold: CGFloat = 1.05

    /// The factor to apply during a gesture: the factor at gesture start times the gesture's own
    /// scale, clamped to `[1, min(maxUsefulZoom, deviceMax)]`.
    static func factor(
        gestureStart: CGFloat,
        gestureScale: CGFloat,
        deviceMax: CGFloat
    ) -> CGFloat {
        let ceiling = min(maxUsefulZoom, max(1, deviceMax))
        return min(max(gestureStart * gestureScale, 1), ceiling)
    }

    static func showsReadout(factor: CGFloat) -> Bool {
        factor > readoutThreshold
    }

    /// "2.3×"-style label for the readout.
    static func readoutLabel(factor: CGFloat) -> String {
        String(format: "%.1f×", factor)
    }
}
