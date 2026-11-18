import XCTest
@testable import OpenGlasses

/// The card that says which device is in use names an iPad as one.
final class ThisDeviceLabelTests: XCTestCase {
    func testAnIPadIsCalledAnIPad() {
        XCTAssertEqual(ThisDeviceLabel.title(isPad: true), "This iPad")
        XCTAssertEqual(ThisDeviceLabel.symbol(isPad: true), "ipad")
        XCTAssertEqual(ThisDeviceLabel.title(isPad: false), "This iPhone")
        XCTAssertEqual(ThisDeviceLabel.symbol(isPad: false), "iphone")
    }
}
