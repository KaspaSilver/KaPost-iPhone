import Foundation
import CryptoKit

struct CryptoUtils {
    // MARK: - Hex Encoding/Decoding

    static func hexToData(_ hex: String) -> Data? {
        var data = Data()
        var temp = ""

        let cleanHex = hex.lowercased().replacingOccurrences(of: " ", with: "")
        // A trailing half byte is a damaged value, not one to silently shorten.
        guard cleanHex.count.isMultiple(of: 2) else { return nil }

        for char in cleanHex {
            temp += String(char)
            if temp.count == 2 {
                if let byte = UInt8(temp, radix: 16) {
                    data.append(byte)
                } else {
                    return nil
                }
                temp = ""
            }
        }

        return data
    }

    // MARK: - Hashing

    static func sha256(_ data: Data) -> Data {
        let hash = SHA256.hash(data: data)
        return Data(hash)
    }

    static func sha256(_ string: String) -> Data {
        let data = string.data(using: .utf8) ?? Data()
        return sha256(data)
    }

    // MARK: - Encryption/Decryption

    static func encrypt(_ data: Data, using key: SymmetricKey) throws -> Data {
        let sealedBox = try AES.GCM.seal(data, using: key)
        guard let combined = sealedBox.combined else {
            throw CryptoError.encryptionFailed
        }
        return combined
    }

    static func decrypt(_ data: Data, using key: SymmetricKey) throws -> Data {
        let sealedBox = try AES.GCM.SealedBox(combined: data)
        return try AES.GCM.open(sealedBox, using: key)
    }
}

// MARK: - Secure Memory Zeroing

extension Data {
    /// Zero out the contents of this Data buffer using memset_s (guaranteed not to be optimized away).
    /// Note: Swift Data is a value type with copy-on-write. This zeros the primary storage location
    /// but cannot guarantee all transient copies are erased.
    mutating func zeroOut() {
        guard !isEmpty else { return }
        withUnsafeMutableBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            _ = memset_s(base, ptr.count, 0, ptr.count)
        }
    }
}

enum CryptoError: LocalizedError {
    case encryptionFailed
    case decryptionFailed
    case invalidKey
    case invalidData

    var errorDescription: String? {
        switch self {
        case .encryptionFailed:
            return "Failed to encrypt data"
        case .decryptionFailed:
            return "Failed to decrypt data"
        case .invalidKey:
            return "Invalid encryption key"
        case .invalidData:
            return "Invalid data format"
        }
    }
}
