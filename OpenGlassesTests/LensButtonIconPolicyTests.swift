import XCTest
@testable import OpenGlasses
#if !AVENKIN_PHONE_ONLY
import MWDATDisplay
#endif

/// `LensButtonIconPolicy`: no lens button is sent with an icon, whatever its style, so a label is
/// never lost to a bare glyph (on the simulated Display any button with an icon draws as the icon
/// alone).
final class LensButtonIconPolicyTests: XCTestCase {

    func testNoButtonStyleKeepsItsIcon() {
        XCTAssertEqual(LensButtonIconPolicy.icon(.message, style: .primary), .none)
        XCTAssertEqual(LensButtonIconPolicy.icon(.reminder, style: .primary), .none)
        XCTAssertEqual(LensButtonIconPolicy.icon(.message, style: .secondary), .none)
        XCTAssertEqual(LensButtonIconPolicy.icon(.navigation, style: .outline), .none)
    }

    func testAButtonWithNoIconStaysWithout() {
        for style: HUDButtonStyle in [.primary, .secondary, .outline] {
            XCTAssertEqual(LensButtonIconPolicy.icon(.none, style: style), .none)
        }
    }

    /// The budget never counts an icon for a button that is sent without one.
    func testTheBudgetCountsNoIconForASentButton() {
        let withIcon = HUDItem(id: "ready", label: "Ready", icon: .reminder, style: .primary) {}
        let without = HUDItem(id: "ready", label: "Ready", style: .primary) {}
        XCTAssertEqual(LensButtonRowBudget.width(of: withIcon), LensButtonRowBudget.width(of: without))
    }

    #if !AVENKIN_PHONE_ONLY
    /// The launcher's branches carry icons, the primary included; on the lens every one goes out as
    /// its label alone.
    @MainActor
    func testTheMetaScreenSendsEveryButtonAsItsLabelOnly() throws {
        let screen = HUDScreen(title: "Menu", lines: [], items: [
            HUDItem(id: "branch:digest", label: "What's new", icon: .info, style: .primary) {},
            HUDItem(id: "branch:quick", label: "Quick Actions", icon: .message, style: .secondary) {},
            HUDItem(id: "branch:home", label: "Home", icon: .location, style: .outline) {},
        ])
        let view = MetaDisplayBackend().makeScreenView(screen)
        let group = try XCTUnwrap(view.children.compactMap { $0 as? ButtonGroup }.first)
        let buttons = group.buttons
        XCTAssertEqual(buttons.map(\.label), ["What's new", "Quick Actions", "Home"], "every label is kept")
        XCTAssertNil(buttons[0].iconName, "the primary is sent without its icon too")
        XCTAssertNil(buttons[1].iconName)
        XCTAssertNil(buttons[2].iconName)
    }

    /// Line icons are not buttons: the Today screen's clock line still goes out with its icon,
    /// while the ready button beside it goes out as its label.
    @MainActor
    func testALineKeepsItsIcon() throws {
        let screen = HUDScreen(title: "Today", lines: [HUDLine("09:41", icon: .clock, emphasis: .meta)], items: [
            HUDItem(id: "ready", label: "Ready", icon: .reminder, style: .primary) {},
        ])
        let view = MetaDisplayBackend().makeScreenView(screen)
        let iconRows = view.children.compactMap { $0 as? FlexBox }
            .filter { $0.children.contains { $0 is Icon } }
        XCTAssertEqual(iconRows.count, 1, "the clock line is drawn with its icon")
        let group = try XCTUnwrap(view.children.compactMap { $0 as? ButtonGroup }.first)
        XCTAssertNil(group.buttons[0].iconName)
    }
    #endif
}
