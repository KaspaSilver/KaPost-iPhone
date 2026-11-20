import Foundation

/// The `.kachat` actions KaPost still takes: saving the address profile (`kchat:1:profile:`) and
/// following that transaction until it shows, plus reading which names this wallet holds. Claiming, renewing, selling, transferring, buying and offers are KaPay's (owner's
/// call, 2026-11-18), so nothing here signs a registry transaction.
@MainActor
final class KachatNamesActions: ObservableObject {
    static let shared = KachatNamesActions()

    private init() {}

    private var service: KachatNamesService { KachatNamesService.shared }
    private var registry: KachatNamesRegistry { KachatNamesRegistry.shared }

    enum ActionError: LocalizedError {
        case noWallet
        case keyMismatch

        var errorDescription: String? {
            switch self {
            case .noWallet: return AppLocalization.string("No wallet is open.")
            case .keyMismatch: return AppLocalization.string("This wallet's key does not match its address.")
            }
        }
    }

    /// A unix-ms day ("Oct 12, 2027") in the in-app language, with the time when it is within two
    /// days (testnet's 24-hour periods, or a renewal that opens tomorrow).
    nonisolated static func dayString(_ ms: Int64) -> String {
        let f = DateFormatter()
        f.locale = AppLocalization.locale
        f.dateStyle = .medium
        f.timeStyle = abs(ms - KachatNames.nowMs()) < 2 * 86_400_000 ? .short : .none
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
    }

    // MARK: - Wallet

    struct Signer {
        let address: String
        let privateKey: Data
        let me: Data
    }

    /// The current wallet's chatting address and key on the network the app runs on - the
    /// profile record's signer. It isn't testnet-only: profiles work on mainnet
    /// before its registry launches (`KachatNamesService.profilesEnabled`).
    func profileSigner() throws -> Signer {
        guard KachatNamesService.profilesEnabled else { throw KachatNamesService.ServiceError.testnetOnly }
        guard let address = WalletManager.shared.currentWallet?.publicAddress.lowercased(),
              let key = WalletManager.shared.getPrivateKey() else { throw ActionError.noWallet }
        guard NetworkType.isOnActiveNetwork(address) else { throw KachatNamesService.ServiceError.wrongAddressNetwork }
        let me = try KachatNamesService.xonlyKey(privateKey: key)
        guard let a = KaspaAddress(address: address), a.type == .pubKey, a.payload == me else { throw ActionError.keyMismatch }
        return Signer(address: address, privateKey: key, me: me)
    }

    // MARK: - This wallet's keys (IOS-085 / XP-024)

    private var nameKeysCache: (key: String, at: Date, keys: [Data])?

    /// The keys worth asking the registry about (one lookup each): the chatting key, then every
    /// revealed spending address that has ever been used - a name needs KAS on its address. The
    /// used/unused answers are cached (used is for good), so after the first time this costs no
    /// requests; the list itself is kept ten minutes.
    func ownNameKeys() async -> [Data] {
        guard let wallet = myAddress, let me = myKey else { return [] }
        let manager = WalletManager.shared
        let cacheKey = "\(wallet)|\(manager.maxSpendingAddressIndex)"
        if let cached = nameKeysCache, cached.key == cacheKey, Date().timeIntervalSince(cached.at) < 600 {
            return cached.keys
        }
        let spending = manager.spendingAddresses(inRange: 0..<(max(0, manager.maxSpendingAddressIndex) + 1))
            .sorted { $0.key < $1.key }.map(\.value)
        let chat = ChatService.shared
        var used: [String: Bool] = [:]
        var toProbe: [String] = []
        for address in spending {
            if let known = chat.cachedSpendingAddressUsedState(address) { used[address] = known } else { toProbe.append(address) }
        }
        var pending = toProbe.makeIterator()
        await withTaskGroup(of: (String, Bool?).self) { group in
            for _ in 0..<8 {
                guard let address = pending.next() else { break }
                group.addTask { (address, await chat.spendingAddressUsedState(address)) }
            }
            while let (address, answer) = await group.next() {
                used[address] = answer ?? false
                if let next = pending.next() {
                    group.addTask { (next, await chat.spendingAddressUsedState(next)) }
                }
            }
        }
        var keys = [me]
        for address in spending where used[address] == true {
            if let key = KachatNamesRegistry.keyOf(address), !keys.contains(key) { keys.append(key) }
        }
        guard myAddress == wallet else { return [] }
        nameKeysCache = (cacheKey, Date(), keys)
        return keys
    }

    /// The names held (active or in grace) on this wallet's keys (`ownNameKeys`). KaPost shows
    /// names only, so no offers are read.
    func ownHeldNames() async throws -> [KachatNames.NameInfo] {
        try await heldNames(of: await ownNameKeys())
    }

    /// The names held on `keys`, asked a few at a time.
    func heldNames(of keys: [Data]) async throws -> [KachatNames.NameInfo] {
        let registry = KachatNamesRegistry.shared
        var names: [KachatNames.NameInfo] = []
        let lookUp: @MainActor (Data) async throws -> [KachatNames.NameInfo] = { key in
            try await registry.heldNames(owner: key)
        }
        try await withThrowingTaskGroup(of: [KachatNames.NameInfo].self) { group in
            var it = keys.makeIterator()
            for _ in 0..<4 {
                guard let key = it.next() else { break }
                group.addTask { try await lookUp(key) }
            }
            while let n = try await group.next() {
                names += n
                if let key = it.next() { group.addTask { try await lookUp(key) } }
            }
        }
        return names
    }

    /// The current wallet's x-only key, without touching the private key.
    var myKey: Data? {
        guard let address = WalletManager.shared.currentWallet?.publicAddress else { return nil }
        return KachatNamesRegistry.keyOf(address)
    }

    var myAddress: String? { WalletManager.shared.currentWallet?.publicAddress.lowercased() }

    // MARK: - Following a sent transaction (node only)

    /// Where a sent name transaction is: sent, waiting in a node's mempool, in a block, shown (the
    /// registry has it), or dropped (no node has it).
    enum TxStage: Equatable { case sent, inMempool, accepted, shown, dropped }

    /// The stage of every transaction sent from this app this session, by txid.
    @Published private(set) var txStages: [String: TxStage] = [:]

    /// Follows `txId` (a profile save, a plain self-transfer) until it is in a block, then
    /// refreshes the registry so the change shows. Only the mempool, then the REST API, can tell.
    func follow(txId: String) {
        txStages[txId] = .sent
        Task { @MainActor in
            let started = Date()
            while Date().timeIntervalSince(started) < 300 {
                if await NodePoolService.shared.getMempoolEntry(txId: txId) != nil {
                    if txStages[txId] == .sent { txStages[txId] = .inMempool }
                } else {
                    // Out of the mempool: in a block, or dropped. The REST API settles it.
                    if await KachatNamesRegistry.isAccepted(txId: txId) {
                        txStages[txId] = .accepted
                        await registry.refreshUntilIncludes(txId: txId, daa: await NodePoolService.shared.currentVirtualDaaScore())
                        txStages[txId] = .shown
                        return
                    }
                    if Date().timeIntervalSince(started) > 60 {
                        txStages[txId] = .dropped
                        return
                    }
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            txStages[txId] = .dropped
        }
    }

    // MARK: - Profile record

    /// Writes the address profile (`kchat:1:profile:`): a self-transfer, network fee only.
    @discardableResult
    /// What saving `profile` will cost: the profile record is a self-transfer from the chatting
    /// address, so the network fee is all it spends. Built (and signed) the same way the save
    /// builds it, never sent.
    func profileFee(_ profile: KachatNames.Profile) async throws -> UInt64 {
        let s = try profileSigner()
        let json = try profile.sanitized().recordJSON()
        let utxos = try await NodePoolService.shared.getUtxosByAddresses([s.address])
        let tx = try service.buildProfileRecord(address: s.address, privateKey: s.privateKey, utxos: utxos, json: json)
        let spent = tx.inputs.reduce(UInt64(0)) { total, input in
            total + (utxos.first {
                $0.outpoint.transactionId == input.previousOutpoint.transactionId && $0.outpoint.index == input.previousOutpoint.index
            }?.amount ?? 0)
        }
        let back = tx.outputs.reduce(UInt64(0)) { $0 + $1.value }
        return spent > back ? spent - back : 0
    }

    func saveProfile(_ profile: KachatNames.Profile) async throws -> String {
        let s = try profileSigner()
        let clean = profile.sanitized()
        let json = try clean.recordJSON()
        let utxos = try await NodePoolService.shared.getUtxosByAddresses([s.address])
        let txId = try await service.submitProfileRecord(address: s.address, privateKey: s.privateKey, utxos: utxos, json: json)
        registry.noteOwnProfile(clean, address: s.address, txId: txId)
        registry.refreshAfter(txId: txId)
        return txId
    }
}
