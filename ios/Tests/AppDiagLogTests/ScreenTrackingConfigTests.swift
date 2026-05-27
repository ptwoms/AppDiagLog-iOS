import XCTest
@testable import AppDiagLog

final class ScreenTrackingConfigTests: XCTestCase {

    func testDefaultFilterSkipsFrameworkAndSwiftUIContainerControllers() {
        let config = AutomaticScreenTrackConfig()

        XCTAssertFalse(config.shouldTrack(controllerName: "UINavigationController"))
        XCTAssertFalse(config.shouldTrack(controllerName: "UITabBarController"))
        XCTAssertFalse(config.shouldTrack(controllerName: "TabHostingController"))
        XCTAssertFalse(config.shouldTrack(controllerName: "NavigationStackHostingController<AnyView>"))
        XCTAssertFalse(config.shouldTrack(controllerName: "UIHostingController<SettingsView>"))
        XCTAssertFalse(config.shouldTrack(controllerName: "_UIRemoteKeyboardViewController"))
    }

    func testDefaultFilterAllowsAppControllersIncludingCustomHostingWrappers() {
        let config = AutomaticScreenTrackConfig()

        XCTAssertTrue(config.shouldTrack(controllerName: "CheckoutViewController"))
        XCTAssertTrue(config.shouldTrack(controllerName: "AutoTrackingDetailHostingController"))
    }

    func testAllowListRestrictsTrackedControllerNames() {
        let config = AutomaticScreenTrackConfig(
            allowedControllerNamePrefixes: ["Checkout", "Settings"]
        )

        XCTAssertTrue(config.shouldTrack(controllerName: "CheckoutViewController"))
        XCTAssertTrue(config.shouldTrack(controllerName: "SettingsViewController"))
        XCTAssertFalse(config.shouldTrack(controllerName: "ProfileViewController"))
    }

    func testCustomPredicateCanDenyOtherwiseAllowedControllerName() {
        let config = AutomaticScreenTrackConfig { name in
            name != "DebugOverlayViewController"
        }

        XCTAssertTrue(config.shouldTrack(controllerName: "CheckoutViewController"))
        XCTAssertFalse(config.shouldTrack(controllerName: "DebugOverlayViewController"))
    }

    func testAccessibilityIdentifierTrackingRequiresNonEmptyIdentifier() {
        let config = AccessibilityIdentifierScreenTrackConfig()

        XCTAssertTrue(config.shouldTrack(identifier: "checkout_screen"))
        XCTAssertFalse(config.shouldTrack(identifier: ""))
    }

    func testAccessibilityIdentifierTrackingCanRequirePrefix() {
        let config = AccessibilityIdentifierScreenTrackConfig(requiredPrefix: "screen.")

        XCTAssertTrue(config.shouldTrack(identifier: "screen.checkout"))
        XCTAssertFalse(config.shouldTrack(identifier: "checkout_button"))
    }
}
