import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Persists a tiny crash marker outside the encrypted session files.
///
/// Crash handlers cannot safely run the full logging pipeline. They write only this
/// marker, then the next launch consumes it and records a normal encrypted `crash`
/// event into the newly opened session.
struct CrashMarkerStore: Sendable {
    let markerFile: URL

    init(paths: AppDiagLogPaths) {
        self.markerFile = paths.crashMarkerFile
    }

    var markerPath: String {
        markerFile.path
    }

    func consume() -> CrashMarker? {
        guard FileManager.default.fileExists(atPath: markerFile.path) else {
            return nil
        }
        defer {
            try? FileManager.default.removeItem(at: markerFile)
        }

        do {
            let data = try Data(contentsOf: markerFile)
            return try JSONDecoder().decode(CrashMarker.self, from: data)
        } catch {
            SdkLog.warn("crash marker unreadable — dropping", error: error)
            return nil
        }
    }
}

struct CrashMarker: Codable, Sendable {
    let version: Int
    let type: String
    let reason: String
    let crashedAtUnixSeconds: Int64

    var eventProperties: [String: String] {
        [
            "type": type,
            "reason": reason,
            "cause": CrashCause.describe(type: type),
            "source": "previous_app_close",
            "captured_on": "next_launch",
            "crashed_at_unix_seconds": String(crashedAtUnixSeconds)
        ]
    }

    static func signal(_ signal: Int32) -> CrashMarker {
        CrashMarker(
            version: 1,
            type: "Signal:\(CrashSignal.name(signal))",
            reason: "signal \(signal)",
            crashedAtUnixSeconds: Int64(Date().timeIntervalSince1970)
        )
    }

    static func exception(_ exception: NSException) -> CrashMarker {
        CrashMarker(
            version: 1,
            type: "NSException:\(exception.name.rawValue)",
            reason: exception.reason ?? "",
            crashedAtUnixSeconds: Int64(Date().timeIntervalSince1970)
        )
    }
}

enum CrashCause {
    static func describe(type: String) -> String {
        switch type {
        case "Signal:SIGABRT":
            return "abort"
        case "Signal:SIGILL":
            return "illegal_instruction"
        case "Signal:SIGSEGV":
            return "segmentation_fault"
        case "Signal:SIGBUS":
            return "bus_error"
        case "Signal:SIGFPE":
            return "arithmetic_exception"
        case "Signal:SIGPIPE":
            return "broken_pipe"
        case "Signal:SIGTRAP":
            return "swift_trap_or_breakpoint"
        default:
            if type.hasPrefix("NSException:") {
                return "uncaught_ns_exception"
            }
            if type.hasPrefix("Signal:") {
                return "signal"
            }
            return "unknown"
        }
    }
}

enum CrashSignal {
    static func name(_ signal: Int32) -> String {
        switch signal {
        case SIGABRT: return "SIGABRT"
        case SIGILL:  return "SIGILL"
        case SIGSEGV: return "SIGSEGV"
        case SIGBUS:  return "SIGBUS"
        case SIGFPE:  return "SIGFPE"
        case SIGPIPE: return "SIGPIPE"
        #if canImport(Darwin)
        case SIGTRAP: return "SIGTRAP"
        #endif
        default:      return "SIG\(signal)"
        }
    }
}

#if canImport(Darwin)
enum CrashMarkerWriter {
    static func writeSignal(_ signal: Int32, to path: String) {
        let payload = signalPayload(signal)
        path.withCString { markerPath in
            let fd = open(markerPath, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
            guard fd >= 0 else { return }
            _ = write(fd, payload.utf8Start, payload.utf8CodeUnitCount)
            _ = fsync(fd)
            _ = close(fd)
        }
    }

    private static func signalPayload(_ signal: Int32) -> StaticString {
        switch signal {
        case SIGABRT:
            return #"{"version":1,"type":"Signal:SIGABRT","reason":"signal 6","crashedAtUnixSeconds":0}"#
        case SIGILL:
            return #"{"version":1,"type":"Signal:SIGILL","reason":"signal 4","crashedAtUnixSeconds":0}"#
        case SIGSEGV:
            return #"{"version":1,"type":"Signal:SIGSEGV","reason":"signal 11","crashedAtUnixSeconds":0}"#
        case SIGBUS:
            return #"{"version":1,"type":"Signal:SIGBUS","reason":"signal 10","crashedAtUnixSeconds":0}"#
        case SIGFPE:
            return #"{"version":1,"type":"Signal:SIGFPE","reason":"signal 8","crashedAtUnixSeconds":0}"#
        case SIGPIPE:
            return #"{"version":1,"type":"Signal:SIGPIPE","reason":"signal 13","crashedAtUnixSeconds":0}"#
        case SIGTRAP:
            return #"{"version":1,"type":"Signal:SIGTRAP","reason":"signal 5","crashedAtUnixSeconds":0}"#
        default:
            return #"{"version":1,"type":"Signal:UNKNOWN","reason":"signal","crashedAtUnixSeconds":0}"#
        }
    }
}
#endif
