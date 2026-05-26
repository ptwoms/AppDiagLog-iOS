import Foundation

@usableFromInline
func DLCondition<DLError: Error>(_ condition: @autoclosure () -> Bool, _ error: @autoclosure () -> DLError) throws {
    guard condition() else {
        throw error()
    }
}

