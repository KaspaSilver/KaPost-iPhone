import Foundation

/// Unseen-KaPosts-activity count: what the notifications tab's badge shows.
///
/// A COUNT, not a feed. The rows are already served by the KaPosts notifications screen straight
/// from the indexer, so storing them a second time would only be a cache that could disagree with
/// it. What cannot be derived from the indexer is how many the user has not looked at yet, which
/// is what this persists.
@MainActor
final class KaPostsNotificationCenter: ObservableObject {
    static let shared = KaPostsNotificationCenter()

    /// How many notifications have arrived since the user last opened the KaPosts bell.
    @Published private(set) var unseenCount: Int = 0

    private init() { reload() }

    private var walletAddress: String { WalletManager.shared.currentWallet?.publicAddress ?? "" }
    private var unseenKey: String { "kapostsNotifCenter.unseen.\(walletAddress)" }

    /// Delete Account: one wallet's count, from this device.
    static func removeAllData(forWalletAddress walletAddress: String) {
        UserDefaults.standard.removeObject(forKey: "kapostsNotifCenter.unseen.\(walletAddress)")
    }

    /// Call on account switch (and at init) to load the active wallet's count.
    func reload() {
        unseenCount = max(0, UserDefaults.standard.integer(forKey: unseenKey))
    }

    /// Adds newly-arrived activity to the count. `KaPostsNotificationService.pollOnce` calls it
    /// with the wallet's own actions and hidden people already taken out.
    func recordArrivals(_ count: Int) {
        guard count > 0 else { return }
        unseenCount += count
        lastArrivalAt = Date()
        persist()
    }

    /// When activity last arrived (this run): the notifications screen reloads when it is newer
    /// than its own last load.
    private(set) var lastArrivalAt: Date?

    /// The user has opened the KaPosts notifications screen; nothing is unseen any more.
    func markAllSeen() {
        guard unseenCount != 0 else { return }
        unseenCount = 0
        persist()
    }

    /// Capped in the label rather than in the stored value, so the real number survives a
    /// long absence and only its rendering is abbreviated.
    var badgeText: String { unseenCount > 99 ? "99+" : "\(unseenCount)" }

    private func persist() {
        UserDefaults.standard.set(unseenCount, forKey: unseenKey)
    }
}
