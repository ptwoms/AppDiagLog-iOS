import Foundation

/// Minimal contract every auto-tracker must satisfy. Trackers often hold framework
/// references (UIApplication observers, NWPathMonitor, Objective-C swizzles). `stop()`
/// must detach cleanly — leaks here become lifetime bugs in the host app.
protocol Tracker: Sendable {
    func start() async
    func stop() async
}
