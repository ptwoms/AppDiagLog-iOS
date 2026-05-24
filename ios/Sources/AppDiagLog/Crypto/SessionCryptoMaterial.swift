import Foundation

/// Holds the per-session key material that lives in RAM for the duration of a session.
/// The DEK is wiped when the session is sealed.
final class SessionCryptoMaterial: @unchecked Sendable {
    private(set) var dek: Data
    let wrapped: WrappedDek
    let keyId: String
    let cipher: SymmetricCipher

    var kekAlgorithm: String { wrapped.kekAlgorithm }
    var symmetricAlgorithm: String { cipher.algorithmId }

    private init(dek: Data, wrapped: WrappedDek, keyId: String, cipher: SymmetricCipher) {
        self.dek = dek
        self.wrapped = wrapped
        self.keyId = keyId
        self.cipher = cipher
    }

    static func generate(
        key: AsymmetricKey,
        symmetric: SymmetricAlgorithm,
        pqcProvider: PQCProvider
    ) throws -> SessionCryptoMaterial {
        let cipher = SymmetricCipherFactory.make(symmetric)
        let dek = cipher.generateKey()
        let wrapper = KemWrapperFactory.make(for: key, pqcProvider: pqcProvider)
        let wrapped = try wrapper.wrap(dek: dek, key: key)
        return SessionCryptoMaterial(dek: dek, wrapped: wrapped, keyId: key.keyId, cipher: cipher)
    }

    func wipe() {
        for i in 0..<dek.count { dek[i] = 0 }
    }
}
