import Foundation

/// Coin holds read as sets, for kUSDT (`TokenWallet.apply`, `KusdtTransfer.prepare`): KaPost's
/// side of KaPay's `WalletService+Holds.swift`. Token coins are held by
/// `NodePoolService.submitRpcTransaction` like any other input (`ChatService.reservedMessageOutpoints`),
/// but they aren't `UTXO`s, so `unreservedUtxos` doesn't fit them.
@MainActor
enum KusdtHolds {
    /// How long a "Not confirmed" kUSDT send's coins lead the next build (as KaPay's
    /// `unknownOutcomeHold`): long enough for a lost transaction to land or leave the mempool.
    static let unknownOutcomeHold: TimeInterval = 600

    /// "txid:index" of every coin a "Not confirmed" kUSDT send spent, until when.
    private static var unknownOutcome: [String: Date] = [:]

    /// Every "txid:index" a send from this app is holding right now (in flight, or sent and not
    /// yet in a block).
    static func heldOutpointKeys() -> Set<String> {
        let now = Date()
        return Set(ChatService.shared.reservedMessageOutpoints.filter { $0.value > now }.keys.map { $0.lowercased() })
    }

    /// A kUSDT send ended "Not confirmed" (`KusdtTransfer.send`): its coins aren't held (the node
    /// pool gives them back), so the next build spends one of them too and the two conflict.
    static func rememberUnknownOutcome(_ keys: [String]) {
        let until = Date().addingTimeInterval(unknownOutcomeHold)
        for key in keys { unknownOutcome[key.lowercased()] = until }
    }

    /// Every "txid:index" a "Not confirmed" send spent: the next send from those coins must spend
    /// one of them too, so at most one of the two can land.
    static func unknownOutcomeKeys() -> Set<String> {
        let now = Date()
        unknownOutcome = unknownOutcome.filter { $0.value > now }
        return Set(unknownOutcome.keys)
    }

    /// The KAS coin a build must spend first: the largest one a "Not confirmed" send also spent,
    /// so the two conflict and at most one can land. nil if none is among these.
    static func conflictingOutpoint(in spendable: [UTXO]) -> String? {
        let unknown = unknownOutcomeKeys()
        guard !unknown.isEmpty else { return nil }
        return spendable
            .filter { unknown.contains(key($0)) }
            .max { $0.amount < $1.amount }
            .map { key($0) }
    }

    static func key(_ utxo: UTXO) -> String {
        "\(utxo.outpoint.transactionId.lowercased()):\(utxo.outpoint.index)"
    }

    static func key(_ coin: KusdtBalances.Coin) -> String {
        "\(coin.transactionId.lowercased()):\(coin.index)"
    }
}
