import Foundation
import CryptoKit

/// ML-KEM provider abstraction. iOS 18 SDK ships ML-KEM in CryptoKit (swift-crypto 4+);
/// older targets need a liboqs XCFramework injected at init. This protocol decouples
/// the SDK from either source so apps pick what fits.
public protocol PQCProvider: Sendable {
    /// Returns `true` if this provider can perform ML-KEM operations on the current runtime.
    /// The SDK checks this synchronously at `initialize()` time and raises `assertionFailure`
    /// if the configured key is ML-KEM but the provider is unavailable.
    var isAvailable: Bool { get }

    /// Encapsulates a shared secret against the given public key. Returns
    /// (`kemCiphertext`, `sharedSecret`). The caller wraps the DEK with the shared
    /// secret using AES-KWP.
    func encapsulate(publicKey: Data) throws -> (kemCiphertext: Data, sharedSecret: Data)

    /// Decapsulate — used by tests / backend only. The client SDK rarely calls this.
    func decapsulate(privateKey: Data, kemCiphertext: Data) throws -> Data
}

/// Thrown when ML-KEM is unsupported on the current runtime and no provider is injected.
public struct PQCUnavailableError: Error, CustomStringConvertible {
    public let description = """
        ML-KEM is not available on this runtime. Provide a custom PQCProvider \
        (e.g. liboqs via XCFramework) at init time, or target iOS 18+ where CryptoKit \
        supplies the primitive natively. Alternatively pick AsymmetricKey.rsaOaep3072 \
        or .ecdhP256 for cryptographic-agility fallback.
        """
}

public struct SystemPQCProvider: PQCProvider {
    public init() {}

    public var isAvailable: Bool {
        if #available(iOS 26.0, macOS 26.0, *) { return true }
        return false
    }

    public func encapsulate(publicKey: Data) throws -> (kemCiphertext: Data, sharedSecret: Data) {
        if #available(iOS 26.0, macOS 26.0, *) {
            let pk = try MLKEM768.PublicKey(rawRepresentation: publicKey)
            let enc = try pk.encapsulate()
            return (enc.encapsulated, enc.sharedSecret.withUnsafeBytes({ Data($0) }))
        }
        throw PQCUnavailableError()
    }

    public func decapsulate(privateKey: Data, kemCiphertext: Data) throws -> Data {
        if #available(iOS 26.0, macOS 26.0, *) {
            let shared = try MLKEM768.PrivateKey(integrityCheckedRepresentation: privateKey)
                .decapsulate(kemCiphertext)
            return shared.withUnsafeBytes({ Data($0) })
        }
        throw PQCUnavailableError()
    }
}
