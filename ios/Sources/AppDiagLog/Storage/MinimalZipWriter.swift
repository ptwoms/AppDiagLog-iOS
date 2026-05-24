import Foundation

/// Minimal ZIP writer — STORED (uncompressed) entries only.
///
/// Why: our `.enc` payloads are AES-GCM ciphertext (high entropy → incompressible), so
/// DEFLATE adds CPU cost without reducing size. By supporting only STORED entries we
/// avoid pulling in any compression library and stay native to Foundation.
///
/// Spec implemented:
///   - Local file header (0x04034b50) + file name + raw data
///   - Central directory (0x02014b50)
///   - End of central directory (0x06054b50)
///   - No data descriptors, no Zip64, no UTF-8 flag beyond the standard practice of
///     encoding UTF-8 filenames (which is widely accepted even without the bit set).
final class MinimalZipWriter {
    private let handle: FileHandle
    private var entries: [CentralEntry] = []
    private var position: UInt32 = 0

    private struct CentralEntry {
        let fileName: String
        let crc32: UInt32
        let size: UInt32
        let localHeaderOffset: UInt32
    }

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        self.handle = try FileHandle(forWritingTo: url)
    }

    func close() throws {
        try writeCentralDirectory()
        try handle.close()
    }

    func append(fileName: String, data: Data) throws {
        let nameBytes = Array(fileName.utf8)
        let crc = crc32(data)
        let size = UInt32(data.count)
        let localOffset = position

        var header = Data()
        header.append(Self.u32(0x04034b50))    // local file header signature
        header.append(Self.u16(20))            // version needed
        header.append(Self.u16(0x0800))        // general purpose bit flag (UTF-8 names)
        header.append(Self.u16(0))             // compression method: stored
        header.append(Self.u16(0))             // mod time
        header.append(Self.u16(0))             // mod date
        header.append(Self.u32(crc))           // crc-32
        header.append(Self.u32(size))          // compressed size
        header.append(Self.u32(size))          // uncompressed size
        header.append(Self.u16(UInt16(nameBytes.count))) // file name length
        header.append(Self.u16(0))             // extra field length
        header.append(contentsOf: nameBytes)
        handle.write(header)
        handle.write(data)
        position &+= UInt32(header.count) &+ size

        entries.append(CentralEntry(
            fileName: fileName,
            crc32: crc,
            size: size,
            localHeaderOffset: localOffset
        ))
    }

    private func writeCentralDirectory() throws {
        let cdOffset = position
        var cdSize: UInt32 = 0

        for e in entries {
            let nameBytes = Array(e.fileName.utf8)
            var cdh = Data()
            cdh.append(Self.u32(0x02014b50))    // central dir signature
            cdh.append(Self.u16(20))            // version made by
            cdh.append(Self.u16(20))            // version needed
            cdh.append(Self.u16(0x0800))        // flags (UTF-8)
            cdh.append(Self.u16(0))             // method
            cdh.append(Self.u16(0))             // mod time
            cdh.append(Self.u16(0))             // mod date
            cdh.append(Self.u32(e.crc32))
            cdh.append(Self.u32(e.size))
            cdh.append(Self.u32(e.size))
            cdh.append(Self.u16(UInt16(nameBytes.count)))
            cdh.append(Self.u16(0))             // extra length
            cdh.append(Self.u16(0))             // comment length
            cdh.append(Self.u16(0))             // disk number
            cdh.append(Self.u16(0))             // internal attrs
            cdh.append(Self.u32(0))             // external attrs
            cdh.append(Self.u32(e.localHeaderOffset))
            cdh.append(contentsOf: nameBytes)
            handle.write(cdh)
            cdSize &+= UInt32(cdh.count)
        }

        var eocd = Data()
        eocd.append(Self.u32(0x06054b50))       // end of central dir signature
        eocd.append(Self.u16(0))                // disk number
        eocd.append(Self.u16(0))                // disk with CD
        eocd.append(Self.u16(UInt16(entries.count))) // entries on this disk
        eocd.append(Self.u16(UInt16(entries.count))) // total entries
        eocd.append(Self.u32(cdSize))
        eocd.append(Self.u32(cdOffset))
        eocd.append(Self.u16(0))                // comment length
        handle.write(eocd)
    }

    // MARK: - Helpers

    private static func u16(_ v: UInt16) -> Data {
        var le = v.littleEndian
        return withUnsafeBytes(of: &le) { Data($0) }
    }
    private static func u32(_ v: UInt32) -> Data {
        var le = v.littleEndian
        return withUnsafeBytes(of: &le) { Data($0) }
    }

    /// Standard IEEE 802.3 CRC32 table.
    private func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in data {
            let idx = Int((crc ^ UInt32(b)) & 0xFF)
            crc = (crc >> 8) ^ Self.crcTable[idx]
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static let crcTable: [UInt32] = {
        var t = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
            }
            t[i] = c
        }
        return t
    }()
}
