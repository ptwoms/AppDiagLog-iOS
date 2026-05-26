import Foundation

// MARK: - Symmetric cipher errors

enum SymCipherError: Error {
    case invalidKeyLength
    case invalidIvLength
    case invalidCiphertextAndTag
    case randomFailed
}

// MARK: - Common extensions

extension Data {
    mutating func wipe() {
        let count = self.count
        guard count > 0 else { return }
        // Access the raw, mutable memory buffer directly
        self.withUnsafeMutableBytes { (bufferPointer: UnsafeMutableRawBufferPointer) in
            if let baseAddress = bufferPointer.baseAddress {
                _ = memset_s(baseAddress, count, 0, count)
            }
        }
    }

    static func randomBytes(_ count: Int) throws -> Data {
        var bytes = Data(count: count)
        let result = bytes.withUnsafeMutableBytes { ptr -> Int32 in
            SecRandomCopyBytes(kSecRandomDefault, count, ptr.baseAddress!)
        }
        try DLCondition(result == errSecSuccess, SymCipherError.randomFailed)
        return bytes
    }
}
