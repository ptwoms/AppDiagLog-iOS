import Foundation

@usableFromInline
func DLCondition<DLError: Error>(_ condition: @autoclosure () -> Bool, _ error: @autoclosure () -> DLError) throws {
    guard condition() else {
        throw error()
    }
}

extension Date {
    static var isoDateFormatter: ISO8601DateFormatter {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt
    }
}
