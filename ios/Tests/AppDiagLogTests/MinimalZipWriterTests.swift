import XCTest
@testable import AppDiagLog

final class MinimalZipWriterTests: XCTestCase {

    func testProducesParseableZipWithExpectedEntries() throws {
        let dir = TestHelpers.tempDir("zip-tests")
        let zipURL = dir.appendingPathComponent("test.zip")

        let writer = try MinimalZipWriter(url: zipURL)
        try writer.append(fileName: "manifest.json", data: Data("{\"v\":1}".utf8))
        try writer.append(fileName: "sessions/session_a.enc", data: Data(repeating: 0xAB, count: 1024))
        try writer.close()

        // Parse the End-Of-Central-Directory record manually to validate structure.
        let bytes = try Data(contentsOf: zipURL)
        XCTAssertGreaterThan(bytes.count, 0)

        let eocdSig: [UInt8] = [0x50, 0x4b, 0x05, 0x06]
        guard let eocdRange = bytes.range(of: Data(eocdSig)) else {
            return XCTFail("EOCD signature not found")
        }
        let eocdStart = eocdRange.lowerBound
        // Total entries field is at offset eocdStart + 10 (UInt16 LE).
        let entryCount = bytes[eocdStart + 10] | (bytes[eocdStart + 11] << 8)
        XCTAssertEqual(entryCount, 2, "ZIP should report 2 stored entries")

        // Both expected file names appear somewhere in the central directory.
        XCTAssertNotNil(bytes.range(of: Data("manifest.json".utf8)))
        XCTAssertNotNil(bytes.range(of: Data("sessions/session_a.enc".utf8)))
    }

    func testCanBeReadByUnzipShellTool() throws {
        let dir = TestHelpers.tempDir("zip-roundtrip")
        let zipURL = dir.appendingPathComponent("rt.zip")

        let writer = try MinimalZipWriter(url: zipURL)
        try writer.append(fileName: "hello.txt", data: Data("hello world".utf8))
        try writer.close()

        // Use the system `unzip` binary to verify the file is well-formed and
        // round-trips. This test is iOS-target-friendly only on macOS hosts (CI),
        // because `Process` isn't available on iOS — skip otherwise.
        #if os(macOS)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        task.arguments = ["-l", zipURL.path]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        try task.run()
        task.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(task.terminationStatus, 0, "unzip -l failed: \(output)")
        XCTAssertTrue(output.contains("hello.txt"), "expected hello.txt in unzip listing, got: \(output)")
        #endif
    }
}
