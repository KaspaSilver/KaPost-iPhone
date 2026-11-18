import Foundation
import CryptoKit
import P256K

/// Group messaging crypto for KaChat's group chat feature.
///
/// Protocol ported from the Kasia web client's `spike/groupchats` reference implementation
/// (see GROUP_MESSAGING_SPEC.md at github.com/K-Kluster/Kasia, branch `spike/groupchats`).
/// A prior revision of this file also had a KaChat-specific invite-beacon extension (join a
/// group deterministically from a shared code, no prior 1:1 handshake needed) - removed once
/// group chats route through indexers: a publicly-joinable beacon would let anyone discover and
/// join a group's *encrypted* chat, which is exactly the kind of thing that could be used to
/// infer something bad is happening inside it and pressure an indexer operator into censoring.
/// Every member now has to be added directly by the admin, who already knows who they are.
///
/// Trust model: a single admin controls membership and key rotation. All members share a
/// symmetric epoch root key; forward secrecy is at epoch granularity (bumped on membership
/// change), not per-message. Same primitives as 1:1 messaging (`KasiaCipher`): ChaCha20-Poly1305
/// AEAD, HKDF-SHA256, Schnorr/secp256k1 signatures - reused here for consistency, not reinvented.
///
/// This file is pure crypto/codec - no transaction building, no persistence, no network I/O.
/// Wiring this into actual sends/receives (self-stash tx construction, GroupBag storage, UTXO
/// subscription) is a separate layer.
enum GroupCipher {

    // MARK: - Key Derivation

    /// sender_id = SHA256(sender_address_string_bytes)
    static func deriveSenderId(senderAddress: String) -> Data {
        CryptoUtils.sha256(senderAddress)
    }

    // MARK: - Signing (gctl_root / gctl_epoch control messages, and gcomm message authenticity)

    /// Raw Schnorr sign over arbitrary bytes, matching KasiaTransactionBuilder's tx-signing pattern.
    static func sign(_ message: Data, privateKey: Data) throws -> Data {
        let schnorrPrivKey = try P256K.Schnorr.PrivateKey(dataRepresentation: privateKey)
        var messageBytes = [UInt8](message)
        let signature = try schnorrPrivKey.signature(message: &messageBytes, auxiliaryRand: nil)
        for index in messageBytes.indices { messageBytes[index] = 0 }
        return Data(signature.bytes)
    }

    /// Raw Schnorr verify, matching KasiaTransactionBuilder's tx-verification pattern.
    static func verify(_ signature: Data, message: Data, xOnlyPublicKey: Data) -> Bool {
        // From a group payload: the key type doesn't check its length itself.
        guard xOnlyPublicKey.count == 32 else { return false }
        guard let schnorrSig = try? P256K.Schnorr.SchnorrSignature(dataRepresentation: signature) else {
            return false
        }
        let xonlyKey = P256K.Schnorr.XonlyKey(dataRepresentation: xOnlyPublicKey)
        var messageBytes = [UInt8](message)
        let isValid = xonlyKey.isValid(schnorrSig, for: &messageBytes)
        for index in messageBytes.indices { messageBytes[index] = 0 }
        return isValid
    }
}
