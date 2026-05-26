import XCTest
@testable import AppDiagLog

final class FacadeStateTests: XCTestCase {

    func testBuffersLogsAfterInitializeStartsUntilRuntimeIsPublished() async {
        let state = FacadeState()
        let pending = PendingLog(
            sequence: 1,
            event: "startup_probe",
            level: .info,
            properties: ["phase": "didFinishLaunching"],
            observedAt: Date(timeIntervalSince1970: 1_777_000_000)
        )

        if case .discarded = state.routeLog(pending) {
            // Expected: calls made before initialize starts remain no-ops.
        } else {
            XCTFail("Expected logs before initialize to be discarded")
        }

        XCTAssertTrue(state.markInitialized())

        if case .queued = state.routeLog(pending) {
            // Expected: initialize started, but the async runtime is not published yet.
        } else {
            XCTFail("Expected logs during bootstrap to be queued")
        }

        let runtime = await AppDiagLogRuntime.make(
            config: AppDiagLogConfig(
                keyWrap: .mlKem768(keyId: "test-key", publicKey: Data(repeating: 0xAB, count: 1184)),
                autoTrack: AutoTrackConfig(
                    appLifecycle: false,
                    screenViews: false,
                    taps: false,
                    apiCalls: false,
                    crashes: false,
                    connectivity: false,
                    deepLinks: false,
                    deviceSnapshot: false,
                    memoryPressure: false,
                    batteryThermal: false
                )
            ),
            pqcProvider: TestHelpers.StubPQCProvider()
        )

        XCTAssertEqual(state.setRuntime(runtime), [pending])

        let later = PendingLog(
            sequence: 2,
            event: "post_bootstrap_probe",
            level: .debug,
            properties: [:],
            observedAt: Date(timeIntervalSince1970: 1_777_000_001)
        )
        if case .runtime(let routedRuntime, let routedLog) = state.routeLog(later) {
            XCTAssertTrue(routedRuntime === runtime)
            XCTAssertEqual(routedLog.sequence, 2)
        } else {
            XCTFail("Expected logs after runtime publication to route directly")
        }
    }

    func testEventSequencesStartAtOneForEachSession() {
        let generator = EventSequenceGenerator()

        XCTAssertEqual(generator.next(), 1)
        XCTAssertEqual(generator.next(), 2)

        generator.resetForNewSession()

        XCTAssertEqual(generator.next(), 1)
    }
}
