#if DAT_EXPERIMENTAL && canImport(MWDATMotion)
import MWDATMotion
import XCTest
@testable import OpenGlasses

/// The SDK's Motion words in the app's (Plan NB §5). Compiled only in a flagged project; nothing
/// here opens a session.
final class MetaMotionSourceTests: XCTestCase {

    func testASampleKeepsItsTimeOrientationAndGyroscopeOnly() {
        let sample = MWDATMotion.MotionSample(
            timestampNs: 123_456_789,
            accelerometer: Vector3(x: 9, y: 9, z: 9),
            gyroscope: Vector3(x: 0.5, y: -1.25, z: 2),
            magnetometer: Vector3(x: 7, y: 7, z: 7),
            orientation: Quaternion(x: 0, y: 0.5, z: 0, w: 0.75),
            source: .neuralBand)
        let mapped = MetaMotionSource.sample(sample)
        XCTAssertEqual(mapped.timestampNs, 123_456_789)
        XCTAssertEqual(mapped.orientation, WristQuaternion(x: 0, y: 0.5, z: 0, w: 0.75))
        XCTAssertEqual(mapped.gyroscope, WristVector(x: 0.5, y: -1.25, z: 2))
        let bare = MetaMotionSource.sample(MWDATMotion.MotionSample(timestampNs: 1))
        XCTAssertNil(bare.orientation)
        XCTAssertNil(bare.gyroscope)
    }

    func testSourcesStatesAndErrors() {
        XCTAssertEqual(MetaMotionSource.origin(.neuralBand), .neuralBand)
        XCTAssertEqual(MetaMotionSource.origin(.glasses), .glasses)
        XCTAssertEqual(MetaMotionSource.origin(.unknown), .unknown)
        XCTAssertEqual(MetaMotionSource.state(.started), .started)
        XCTAssertEqual(MetaMotionSource.state(.starting), .starting)
        XCTAssertEqual(MetaMotionSource.state(.stopping), .stopping)
        XCTAssertEqual(MetaMotionSource.state(.stopped), .stopped)
        XCTAssertEqual(MetaMotionSource.failure(.sensorUnavailable), .sensorUnavailable)
        XCTAssertEqual(MetaMotionSource.failure(.capabilityClosed), .capabilityClosed)
        XCTAssertEqual(MetaMotionSource.failure(.deviceDisconnected), .deviceDisconnected)
    }

    func testThirtyHertz() {
        XCTAssertEqual(WristMotionConfiguration.sdk.samplingRate, .hz30)
    }
}
#endif
