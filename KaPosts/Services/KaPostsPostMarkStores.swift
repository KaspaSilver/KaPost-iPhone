import Foundation
import Combine

/// A per-account, persisted list of post ids (txids) this account has marked: the base of
/// `KaPostsBookmarkStore` and `KaPostsRepostStore`.
///
/// One instance for the whole app, so the Feed and Profile tabs (each its own KaPostsView) read
/// and write the same marks. Kept per account like `KaPostsWatchStore`: each account is its own
/// KaPost identity. Follows the open account by itself (`WalletManager.$currentWallet`), and
/// every read checks it too, so one account's marks are never read or written as another's.
@MainActor
class KaPostsPostMarkStore: ObservableObject {
    /// One mark set or cleared: views holding copies of posts bring their flags in step.
    struct Change {
        let postId: String
        let isOn: Bool
    }
    let changes = PassthroughSubject<Change, Never>()

    private let keyPrefix: String
    /// Oldest marks fall off past this, so the list can't grow without bound.
    private let capacity: Int
    /// The account `order` was read for (lowercased), nil when logged out.
    private var loadedWallet: String?
    /// Oldest first.
    private var order: [String] = []
    private var marked: Set<String> = []
    private var walletCancellable: AnyCancellable?

    init(keyPrefix: String, capacity: Int) {
        self.keyPrefix = keyPrefix
        self.capacity = capacity
        load(Self.normalized(WalletManager.shared.currentWallet?.publicAddress))
        // `@Published` fires before the value is stored, so the new address comes from the sink.
        walletCancellable = WalletManager.shared.$currentWallet
            .map { Self.normalized($0?.publicAddress) }
            .removeDuplicates()
            .sink { [weak self] wallet in
                guard let self, wallet != self.loadedWallet else { return }
                self.objectWillChange.send()
                self.load(wallet)
            }
    }

    nonisolated private static func normalized(_ address: String?) -> String? {
        let value = address?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return value.isEmpty ? nil : value
    }

    private func key(_ wallet: String) -> String { "\(keyPrefix)_\(wallet)" }

    private func load(_ wallet: String?) {
        loadedWallet = wallet
        order = wallet.flatMap { UserDefaults.standard.stringArray(forKey: key($0)) } ?? []
        marked = Set(order)
    }

    /// Reloads quietly when the open account isn't the one loaded (the sink runs first in
    /// practice; this covers a read that comes before it). No publish: it can run in a body.
    private func syncToCurrentWallet() {
        let current = Self.normalized(WalletManager.shared.currentWallet?.publicAddress)
        if current != loadedWallet { load(current) }
    }

    func contains(_ postId: String?) -> Bool {
        guard let postId, !postId.isEmpty else { return false }
        syncToCurrentWallet()
        return marked.contains(postId)
    }

    /// Every marked id, newest mark first.
    var ids: [String] {
        syncToCurrentWallet()
        return order.reversed()
    }

    func set(_ postId: String, _ isOn: Bool) {
        guard !postId.isEmpty else { return }
        syncToCurrentWallet()
        guard let wallet = loadedWallet, marked.contains(postId) != isOn else { return }
        objectWillChange.send()
        if isOn {
            marked.insert(postId)
            order.append(postId)
            if order.count > capacity {
                let dropped = order.removeFirst()
                marked.remove(dropped)
            }
        } else {
            marked.remove(postId)
            order.removeAll { $0 == postId }
        }
        UserDefaults.standard.set(order, forKey: key(wallet))
        changes.send(Change(postId: postId, isOn: isOn))
    }

    /// Delete Account: one wallet's marks, from this device.
    func removeAllData(forWalletAddress walletAddress: String) {
        guard let wallet = Self.normalized(walletAddress) else { return }
        UserDefaults.standard.removeObject(forKey: key(wallet))
        if loadedWallet == wallet {
            objectWillChange.send()
            order = []
            marked = []
        }
    }
}

/// Bookmarked posts and replies, per account: the bookmark on every card and the Bookmarks
/// screen. Private to this phone; nothing goes on chain.
@MainActor
final class KaPostsBookmarkStore: KaPostsPostMarkStore {
    static let shared = KaPostsBookmarkStore()
    private init() { super.init(keyPrefix: "kachat_kaposts_bookmarks", capacity: 1000) }
}

/// Posts this account has reposted (a plain repost or a quote) from this phone, per account.
///
/// The indexer's post objects say whether you liked or disliked a post but not whether you
/// reposted it, so after a refresh Repost was offered again and a second tap paid for a second
/// repost. Recorded when a repost goes out (or may have), cleared when Remove repost does,
/// and merged into every post as it is mapped.
@MainActor
final class KaPostsRepostStore: KaPostsPostMarkStore {
    static let shared = KaPostsRepostStore()
    private init() { super.init(keyPrefix: "kachat_kaposts_reposted", capacity: 5000) }
}
