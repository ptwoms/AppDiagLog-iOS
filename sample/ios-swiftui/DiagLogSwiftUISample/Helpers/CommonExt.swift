import Foundation

extension Date {
    static var timestamp: String {
        Date.now.formatted(date: .omitted, time: .standard)
    }
}

// MARK: - Log Entry
struct LogEntry: Identifiable {
    let id = UUID()
    let message: String
    init(_ message: String) { self.message = message }
}

extension Array where Element == LogEntry {
    mutating func append(_ message: String, maxEntries: Int = 12) {
        insert(LogEntry("\(Date.timestamp)  \(message)"), at: 0)
        self = Array(prefix(maxEntries))
    }
}
