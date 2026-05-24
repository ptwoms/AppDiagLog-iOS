import Foundation
import CryptoKit
#if canImport(CommonCrypto)
import CommonCrypto
#endif

/// AES Key Wrap with Padding (RFC 5649). Used to wrap the DEK with the KEM-derived
/// shared secret so the resulting ciphertext is deterministic and integrity-checked.
///
/// CommonCrypto's `CCSymmetricKeyWrap` implements AES-KW (RFC 3394). For RFC 5649
/// (with padding) we layer a minimal padding adapter here.
///
/// For this SDK the KEM shared secret is 32 bytes and the DEK is also 32 bytes, so
/// we're always in the "exact multiple of 8" fast path. The padding branch is still
/// included for robustness / forward-compat.
enum AesKwp {
    static func wrap(kek: Data, key: Data) throws -> Data {
        let padded = rfc5649Pad(key)
        return try ccKeyWrap(kek: kek, plaintext: padded, encrypt: true)
    }

    static func unwrap(kek: Data, wrapped: Data) throws -> Data {
        let padded = try ccKeyWrap(kek: kek, plaintext: wrapped, encrypt: false)
        return try rfc5649Unpad(padded)
    }

    // MARK: - Internal

    private static func rfc5649Pad(_ data: Data) -> Data {
        var out = Data(count: 4)
        // MSB marker 0xA65959A6
        out[0] = 0xA6; out[1] = 0x59; out[2] = 0x59; out[3] = 0xA6
        let lenBytes = UInt32(data.count).bigEndian
        withUnsafeBytes(of: lenBytes) { out.append(contentsOf: $0) }
        out.append(data)
        let pad = (8 - (out.count % 8)) % 8
        if pad > 0 { out.append(contentsOf: Data(count: pad)) }
        return out
    }

    private static func rfc5649Unpad(_ data: Data) throws -> Data {
        guard data.count >= 8 else { throw NSError(domain: "AesKwp", code: 1) }
        let marker = data.prefix(4)
        let expected: [UInt8] = [0xA6, 0x59, 0x59, 0xA6]
        guard Array(marker) == expected else { throw NSError(domain: "AesKwp", code: 2) }
        let len = data.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: UInt32.self) }.bigEndian
        let plain = data.subdata(in: 8..<Int(8 + len))
        return plain
    }

    // Minimal AES-KW (RFC 3394) via CommonCrypto
    private static func ccKeyWrap(kek: Data, plaintext: Data, encrypt: Bool) throws -> Data {
        #if canImport(CommonCrypto)
        // CCSymmetricKeyWrap works on multiples of 8 bytes plaintext; we guarantee that
        // via rfc5649Pad above.
        var output = Data(count: plaintext.count + 8) // wrap adds one block (8 bytes)
        let iv: [UInt8] = [0xA6, 0xA6, 0xA6, 0xA6, 0xA6, 0xA6, 0xA6, 0xA6]
        var outLen: Int = output.count

        let result: Int32 = kek.withUnsafeBytes { kekBytes in
            plaintext.withUnsafeBytes { ptBytes in
                output.withUnsafeMutableBytes { outBytes in
                    if encrypt {
                        return CCSymmetricKeyWrap(
                            CCWrappingAlgorithm(kCCWRAPAES),
                            iv, 8,
                            kekBytes.bindMemory(to: UInt8.self).baseAddress!, kek.count,
                            ptBytes.bindMemory(to: UInt8.self).baseAddress!, plaintext.count,
                            outBytes.bindMemory(to: UInt8.self).baseAddress!, &outLen
                        )
                    } else {
                        return CCSymmetricKeyUnwrap(
                            CCWrappingAlgorithm(kCCWRAPAES),
                            iv, 8,
                            kekBytes.bindMemory(to: UInt8.self).baseAddress!, kek.count,
                            ptBytes.bindMemory(to: UInt8.self).baseAddress!, plaintext.count,
                            outBytes.bindMemory(to: UInt8.self).baseAddress!, &outLen
                        )
                    }
                }
            }
        }
        guard result == kCCSuccess else {
            throw NSError(domain: "AesKwp", code: Int(result), userInfo: [NSLocalizedDescriptionKey: "CCSymmetricKey\(encrypt ? "Wrap" : "Unwrap") failed"])
        }
        if encrypt {
            output.count = outLen
        } else {
            // Unwrap shrinks by 8 bytes
            output = output.prefix(outLen)
        }
        return Data(output)
        #else
        throw NSError(domain: "AesKwp", code: -1, userInfo: [NSLocalizedDescriptionKey: "CommonCrypto unavailable"])
        #endif
    }
}
