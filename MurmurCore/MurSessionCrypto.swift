//
//  MurSessionCrypto.swift
//  MurmurCore
//
//  Passphrase encryption for `.mur` sessions (X63-D).
//
//  ## Why a passphrase and not a key
//
//  MurmurCore is MIT-licensed and public, so a key compiled into it is a key
//  published with it. A Keychain-held key would make a package unopenable on
//  any other machine, which would end `.mur` as the sharing/reproducibility
//  surface project_mur_save_format_spec.md defines. An analyst passphrase is
//  the only model that is both genuinely secret and genuinely portable.
//
//  ## Primitives — Apple-native, nothing vendored
//
//  PBKDF2-HMAC-SHA256 (CommonCrypto) → AES-256-GCM (CryptoKit). CryptoKit has
//  no password-based KDF and Apple ships no Argon2; the spec is explicit that
//  none is to be vendored for this.
//
//  Iteration count and salt are RECORDED IN THE MANIFEST rather than assumed,
//  so raising the count later cannot make existing packages unopenable.
//
//  ## What must never regress
//
//  A wrong passphrase and a tampered file raise the SAME CryptoKit error. It
//  is mapped to "wrong passphrase", because telling an analyst their file is
//  damaged when they merely mistyped is the worst message this feature could
//  produce — and it is the one the API's default description invites.
//

import CommonCrypto
import CryptoKit
import Foundation

enum MurSessionCrypto {

    /// OWASP's current floor for PBKDF2-HMAC-SHA256. Recorded per package, so
    /// this constant moving does not strand older files.
    static let defaultIterations = 600_000
    static let saltByteCount = 16

    static let kdfIdentifier = "pbkdf2-hmac-sha256"
    static let cipherIdentifier = "aes-256-gcm"

    static func makeSalt() -> Data {
        var bytes = [UInt8](repeating: 0, count: saltByteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }

    /// Stretch a passphrase into a 256-bit key.
    ///
    /// Throws rather than returning a degenerate key: a KDF failure that
    /// silently yielded zeroes would encrypt everything under a constant key.
    static func deriveKey(
        passphrase: String,
        salt: Data,
        iterations: Int
    ) throws -> SymmetricKey {
        let passwordBytes = Array(passphrase.utf8)
        var derived = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { saltBuffer -> Int32 in
            guard let saltBase = saltBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return Int32(kCCParamError)
            }
            return CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                passwordBytes.map { Int8(bitPattern: $0) },
                passwordBytes.count,
                saltBase,
                salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                UInt32(iterations),
                &derived,
                derived.count
            )
        }
        guard status == kCCSuccess else {
            throw MurSessionError.malformedPackage("its encryption parameters could not be applied")
        }
        return SymmetricKey(data: Data(derived))
    }

    /// Seal `plaintext`, binding `authenticating` (the plaintext manifest) so
    /// the header cannot be swapped without failing authentication.
    static func seal(_ plaintext: Data, key: SymmetricKey, authenticating: Data) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: key, authenticating: authenticating)
        guard let combined = box.combined else {
            throw MurSessionError.malformedPackage("its encrypted payload could not be written")
        }
        return combined
    }

    /// Open a sealed payload.
    ///
    /// `authenticationFailure` means the key is wrong OR the bytes were
    /// altered. We cannot distinguish those — that is what an AEAD guarantees —
    /// and between the two possible messages, "wrong passphrase" is the one
    /// that is usually true and never destroys an analyst's confidence in a
    /// file that is actually intact.
    static func open(_ sealed: Data, key: SymmetricKey, authenticating: Data) throws -> Data {
        do {
            let box = try AES.GCM.SealedBox(combined: sealed)
            return try AES.GCM.open(box, using: key, authenticating: authenticating)
        } catch {
            throw MurSessionError.wrongPassphrase
        }
    }
}
