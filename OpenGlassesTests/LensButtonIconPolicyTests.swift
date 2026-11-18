import XCTest
@testable import OpenGlasses
#if !AVENKIN_PHONE_ONLY
import MWDATDisplay
#endif

/// `LensButtonIconPolicy`: a lens button keeps its icon only when it is primary, so a label is
/// never lost to a bare glyph.
final class LensButtonIconPolicyTests: XCTestCase {

    func testOnlyAPrimaryButtonKeepsItsIcon() {
        XCTAssertEqual(LensButtonIconPolicy.icon(.message, style: .primary), .message)
        XCTAssertEqual(LensButtonIconPolicy.icon(.message, style: .secondary), .none)
        XCTAssertEqual(LensButtonIconPolicy.icon(.navigation, style: .outline), .none)
    }

    func testAButtonWithNoIconStaysWithout() {
        for style: HUDButtonStyle in [.primary, .secondary, .outline] {
            XCTAssertEqual(LensButtonIconPolicy.icon(.none, style: style), .none)
        }
    }

    #if !AVENKIN_PHONE_ONLY
    /// The launcher's secondary branches (Quick Actions, Navigate, Home…) carry icons; on the lens
    /// they go out as labels, and the primary keeps its icon.
    @MainActor
    func testTheMetaScreenSendsSecondaryButtonsAsLabelsOnly() throws {
        let screen = HUDScreen(title: "Menu", lines: [], items: [
            HUDItem(id: "branch:digest", label: "What's new", icon: .info, style: .primary) {},
            HUDItem(id: "branch:quick", label: "Quick Actions", icon: .message, style: .secondary) {},
            HUDItem(id: "branch:home", label: "Home", icon: .location, style: .outline) {},
        ])
        let view = MetaDisplayBackend().makeScreenView(screen)
        let group = try XCTUnwrap(view.children.compactMap { $0 as? ButtonGroup }.first)
        let buttons = group.buttons
        XCTAssertEqual(buttons.map(\.label), ["What's new", "Quick Actions", "Home"], "every label is kept")
        XCTAssertNotNil(buttons[0].iconName, "the primary keeps its icon")
        XCTAssertNil(buttons[1].iconName)
        XCTAssertNil(buttons[2].iconName)
    }
    #endif
}
