import Foundation

/// Re-writes the per-session envelope on every flush.
///
/// Tradeoffs: simple & robust, but re-encrypts all session events
/// on every flush. Acceptable for our bounded-session model (max 1000 events).
actor SessionFileWriter {
    private let paths: AppDiagLogPaths
    private let encoder: JSONEncoder
    private let eventEncoder: JSONEncoder

    init(paths: AppDiagLogPaths) {
        self.paths = paths
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.sortedKeys]
        self.eventEncoder = JSONEncoder()
        self.eventEncoder.outputFormatting = [.sortedKeys]
    }

    struct Args {
        let sessionId: String
        let createdAt: String
        let sealedAt: String?
        let sessionTag: String?
        let deviceMetadata: [String: String]
        let crypto: SessionCryptoMaterial
        let events: [EventEnvelope]
    }

    /// Encrypts and writes. Returns the on-disk size in bytes.
    func write(_ args: Args) throws -> Int64 {
        let plaintext = try eventEncoder.encode(args.events)
        let aad = "\(args.sessionId)|\(args.crypto.keyId)".data(using: .utf8) ?? Data()
        let sealed = try args.crypto.cipher.encrypt(key: args.crypto.dek, plaintext: plaintext, aad: aad)

        let env = SessionEnvelope(
            version: 1,
            sessionId: args.sessionId,
            createdAt: args.createdAt,
            sealedAt: args.sealedAt,
            eventCount: args.events.count,
            sessionTag: args.sessionTag,
            deviceMetadata: args.deviceMetadata,
            encryption: SessionEnvelope.Encryption(
                algorithm: args.crypto.symmetricAlgorithm,
                nonce: sealed.iv.base64EncodedString(),
                kekAlgorithm: args.crypto.kekAlgorithm,
                keyId: args.crypto.keyId,
                kemCiphertext: args.crypto.wrapped.kemCiphertext.base64EncodedString(),
                wrappedDek: args.crypto.wrapped.wrappedDek.base64EncodedString(),
                kekParams: args.crypto.wrapped.kekParams.isEmpty ? nil : args.crypto.wrapped.kekParams
            ),
            payload: sealed.ciphertext.base64EncodedString()
        )
        let data = try encoder.encode(env)
        let target = paths.sessionFile(args.sessionId)
        let tmp = target.appendingPathExtension("tmp")
        try data.write(to: tmp, options: [.atomic])
        _ = try FileManager.default.replaceItemAt(target, withItemAt: tmp)
        let size = (try FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int64) ?? Int64(data.count)
        return size
    }
}
