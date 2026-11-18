import Foundation

extension KachatNames {

    // MARK: - Version-1 transaction model (rusty-kaspa a41a333, consensus/core/src/tx.rs)

    struct Outpoint: Equatable, Hashable {
        /// Transaction id, 32 bytes in hashing order (the hex string as written by the node).
        var txid: Data
        var index: UInt32
    }

    struct UtxoEntry: Equatable {
        var amount: UInt64
        var scriptVersion: UInt16 = 0
        var script: Data
        var blockDaaScore: UInt64
        var isCoinbase: Bool = false
        /// KIP-20 covenant id the UTXO carries (gaps and names: the registry id).
        var covenantId: Data?
    }

    struct Utxo: Equatable {
        var outpoint: Outpoint
        var entry: UtxoEntry
    }

    struct CovenantBinding: Equatable {
        var authorizingInput: UInt16
        var covenantId: Data
    }

    struct TxInput: Equatable {
        var outpoint: Outpoint
        var signatureScript: Data
        var sequence: UInt64
        /// Version-1 compute budget (1 unit = 10,000 script units; 9,999 free per input).
        var computeBudget: UInt16
    }

    struct TxOutput: Equatable {
        var value: UInt64
        var scriptVersion: UInt16 = 0
        var script: Data
        var covenant: CovenantBinding?
    }

    /// A version-1 (Toccata) transaction: output covenant bindings, per-input compute budgets,
    /// native subnetwork, no gas, and the KIP-9 storage-mass commitment.
    struct Tx: Equatable {
        var version: UInt16 = 1
        var inputs: [TxInput]
        var outputs: [TxOutput]
        var lockTime: UInt64
        var subnetworkId = Data(repeating: 0, count: 20)
        var gas: UInt64 = 0
        var payload: Data
        var storageMass: UInt64 = 0

        var isNativeSubnetwork: Bool { subnetworkId == Data(repeating: 0, count: 20) }

        // MARK: Serialization (rusty-kaspa consensus/core/src/hashing/tx.rs `write_transaction`)

        private func write(excludeSignatureScripts: Bool, excludeMassCommit: Bool, excludePayload: Bool) -> Data {
            precondition(version >= 1, "the name core builds version-1 transactions only")
            var d = Data()
            d.append(le16(version))
            d.append(le64(UInt64(inputs.count)))
            for i in inputs {
                d.append(i.outpoint.txid)
                d.append(le32(i.outpoint.index))
                if excludeSignatureScripts {
                    d.append(le64(0))
                } else {
                    d.append(le64(UInt64(i.signatureScript.count)))
                    d.append(i.signatureScript)
                }
                d.append(le64(i.sequence))
                if !excludeMassCommit {
                    d.append(le16(i.computeBudget))
                }
            }
            d.append(le64(UInt64(outputs.count)))
            for o in outputs {
                Tx.appendOutput(o, to: &d)
            }
            d.append(le64(lockTime))
            d.append(subnetworkId)
            d.append(le64(gas))
            if excludePayload {
                d.append(le64(0))
            } else {
                d.append(le64(UInt64(payload.count)))
                d.append(payload)
            }
            if !excludeMassCommit {
                d.append(le64(storageMass))
            }
            return d
        }

        fileprivate static func appendOutput(_ o: TxOutput, to d: inout Data) {
            d.append(le64(o.value))
            d.append(le16(o.scriptVersion))
            d.append(le64(UInt64(o.script.count)))
            d.append(o.script)
            d.append(o.covenant == nil ? 0 : 1)
            if let c = o.covenant {
                d.append(le16(c.authorizingInput))
                d.append(c.covenantId)
            }
        }

        /// The TransactionHash preimage (`write_transaction(tx, FULL)`).
        var fullPreimage: Data { write(excludeSignatureScripts: false, excludeMassCommit: false, excludePayload: false) }

        /// `transaction_v1_rest_preimage`: no payload, signature scripts or mass commitments.
        var restPreimage: Data { write(excludeSignatureScripts: true, excludeMassCommit: true, excludePayload: true) }

        /// The v1 transaction id: `TransactionV1Id(PayloadDigest(payload) || TransactionRest(rest))`.
        var id: Data {
            var d = blake3Keyed("PayloadDigest", payload)
            d.append(blake3Keyed("TransactionRest", restPreimage))
            return blake3Keyed("TransactionV1Id", d)
        }

        var idHex: String { hex(id) }

        /// The transaction hash (commits to signature scripts, budgets and the storage mass).
        var hash: Data { blake2bKeyed("TransactionHash", fullPreimage) }
    }
}

// Stored with the names Your Domains caches (`KachatOwnedNamesCache`).
extension KachatNames.Outpoint: Codable {}
