import Foundation
import os.log

/// Internal SDK logger. Never writes into the encrypted diagnostic stream — that would
/// create feedback loops and could leak implementation detail into the backend.
enum SdkLog {
    nonisolated(unsafe) static var enabled: Bool = false
    private static let logger = Logger(subsystem: "com.appdiaglog.sdk", category: "AppDiagLog")

    static func debug(_ message: String) {
        if enabled { logger.debug("\(message, privacy: .public)") }
    }

    static func info(_ message: String) {
        if enabled { logger.info("\(message, privacy: .public)") }
    }

    static func warn(_ message: String, error: Error? = nil) {
        guard enabled else { return }
        if let error {
            logger.warning("\(message, privacy: .public): \(String(describing: error), privacy: .public)")
        } else {
            logger.warning("\(message, privacy: .public)")
        }
    }

    static func error(_ message: String, error: Error? = nil) {
        guard enabled else { return }
        if let error {
            logger.error("\(message, privacy: .public): \(String(describing: error), privacy: .public)")
        } else {
            logger.error("\(message, privacy: .public)")
        }
    }
}
