import XCTest
@testable import AppDiagLog

final class ScreenTrackingConfigTests: XCTestCase {

    // MARK: - UIKit controller pre-filter

    func testDefaultConfigSkipsFrameworkAndSwiftUIContainerControllers() {
        let config = ScreenTrackingConfig()

        XCTAssertTrue(config.shouldSkipController(name: "UINavigationController"))
        XCTAssertTrue(config.shouldSkipController(name: "UITabBarController"))
        XCTAssertTrue(config.shouldSkipController(name: "TabHostingController"))
        XCTAssertTrue(config.shouldSkipController(name: "NavigationStackHostingController<AnyView>"))
        XCTAssertTrue(config.shouldSkipController(name: "UIHostingController<SettingsView>"))
        XCTAssertTrue(config.shouldSkipController(name: "_UIRemoteKeyboardViewController"))
    }

    func testDefaultConfigAllowsAppControllers() {
        let config = ScreenTrackingConfig()

        XCTAssertFalse(config.shouldSkipController(name: "CheckoutViewController"))
        XCTAssertFalse(config.shouldSkipController(name: "AutoTrackingDetailHostingController"))
    }

    // MARK: - Shared screen name filter

    func testSharedFilterRejectsEmptyName() {
        let config = ScreenTrackingConfig()

        XCTAssertFalse(config.shouldTrack(screenName: ""))
    }

    func testSharedFilterAllowsAnyNameByDefault() {
        let config = ScreenTrackingConfig()

        XCTAssertTrue(config.shouldTrack(screenName: "CheckoutViewController"))
        XCTAssertTrue(config.shouldTrack(screenName: "screen.checkout"))
        XCTAssertTrue(config.shouldTrack(screenName: "RootTabView"))
    }

    func testSharedFilterIgnoresScreenPrefixes() {
        let config = ScreenTrackingConfig(ignoredScreenPrefixes: ["Debug", "Internal."])

        XCTAssertFalse(config.shouldTrack(screenName: "DebugOverlayView"))
        XCTAssertFalse(config.shouldTrack(screenName: "Internal.SettingsView"))
        XCTAssertTrue(config.shouldTrack(screenName: "CheckoutViewController"))
    }

    func testSharedFilterRestrictsToAllowedPrefixes() {
        let config = ScreenTrackingConfig(allowedScreenPrefixes: ["Checkout", "Settings"])

        XCTAssertTrue(config.shouldTrack(screenName: "CheckoutViewController"))
        XCTAssertTrue(config.shouldTrack(screenName: "SettingsViewController"))
        XCTAssertFalse(config.shouldTrack(screenName: "ProfileViewController"))
    }

    func testSharedFilterCustomPredicateCanDeny() {
        let config = ScreenTrackingConfig { name in
            name != "DebugOverlayViewController"
        }

        XCTAssertTrue(config.shouldTrack(screenName: "CheckoutViewController"))
        XCTAssertFalse(config.shouldTrack(screenName: "DebugOverlayViewController"))
    }

    func testAllowedPrefixesFilterAppliesToSwiftUIIdentifiers() {
        let config = ScreenTrackingConfig(allowedScreenPrefixes: ["screen."])

        XCTAssertTrue(config.shouldTrack(screenName: "screen.checkout"))
        XCTAssertFalse(config.shouldTrack(screenName: "Checkout"))
        XCTAssertFalse(config.shouldTrack(screenName: ""))
    }

    // MARK: - UIKit and SwiftUI use the same filter

    func testUIKitAndSwiftUIScreenNamesShareSameFilter() {
        let config = ScreenTrackingConfig(
            ignoredScreenPrefixes: ["Debug"],
            allowedScreenPrefixes: ["Checkout", "screen."]
        )

        // UIKit-derived name
        XCTAssertTrue(config.shouldTrack(screenName: "CheckoutViewController"))
        XCTAssertFalse(config.shouldTrack(screenName: "ProfileViewController"))

        // SwiftUI identifier — same rules
        XCTAssertTrue(config.shouldTrack(screenName: "screen.checkout"))
        XCTAssertFalse(config.shouldTrack(screenName: "HomeView"))

        // Both reject debug prefix
        XCTAssertFalse(config.shouldTrack(screenName: "DebugViewController"))
        XCTAssertFalse(config.shouldTrack(screenName: "DebugView"))
    }

    // MARK: - UIKit naming strategy

    func testClassNameIsDefaultNamingStrategy() {
        let config = ScreenTrackingConfig()
        XCTAssertEqual(config.uikitNaming, .className)
    }

    func testAccessibilityIdentifierNamingCanBeSelected() {
        let config = ScreenTrackingConfig(uikitNaming: .accessibilityIdentifier)
        XCTAssertEqual(config.uikitNaming, .accessibilityIdentifier)
    }
}

