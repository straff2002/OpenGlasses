import XCTest
@testable import OpenGlasses

/// Build 770: the names a lens page press is logged under (`LensOpeningPress.token(for:)`). The
/// rule itself is driven through the session in `LensPageSessionTests` and `LensPageAtWorkTests`.
final class LensOpeningPressTests: XCTestCase {
    private typealias ID = HUDPageScreenBuilder.ItemID

    func testAPressIsLoggedByTheButtonsOwnNameWithoutAnIndex() {
        XCTAssertEqual(LensOpeningPress.token(for: ID.readIt), "read")
        XCTAssertEqual(LensOpeningPress.token(for: ID.rows), "rows")
        XCTAssertEqual(LensOpeningPress.token(for: ID.wholePicture), "whole")
        XCTAssertEqual(LensOpeningPress.token(for: ID.back), "back")
        XCTAssertEqual(LensOpeningPress.token(for: ID.row(7)), "row")
        XCTAssertEqual(LensOpeningPress.token(for: ID.slice(2)), "slice")
        XCTAssertEqual(LensOpeningPress.token(for: "someone's words"), "other")
    }

    func testOnlyRowsAndReadItAreTakenToTheCloseUp() {
        XCTAssertEqual(LensOpeningPress.redirected, [ID.rows, ID.readIt])
    }

    func testEveryLoggedNameIsAPlainToken() {
        let ids = [ID.back, ID.rows, ID.nextPage, ID.close, ID.showHere, ID.nextText, ID.previousText,
                   ID.showPicture, ID.readIt, ID.wholePicture, ID.row(3), ID.slice(1)]
        for id in ids {
            let token = LensOpeningPress.token(for: id)
            XCTAssertEqual(PrivacyToken(token).description, token, id)
        }
    }
}
