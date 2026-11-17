import Foundation
import Combine

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

    /// The account `unseenCount` was loaded for. The count is read and saved under this address,
    /// not whatever wallet is current at write time, so one account's number never lands under
    /// another's key.
    private var loadedAddress = ""
    private var walletCancellable: AnyCancellable?

    private init() {
        loadedAddress = WalletManager.shared.currentWallet?.publicAddress ?? ""
        reload()
        // Log Out, sign-in, import and account switches all change `currentWallet`; none of them
        // called `reload()`, so the last account's count stayed on the dock and the next poll
        // added to it and saved it under the new account. `@Published` fires before the value is
        // stored, so the new address comes from the sink, not from `WalletManager`.
        walletCancellable = WalletManager.shared.$currentWallet
            .map { $0?.publicAddress ?? "" }
            .removeDuplicates()
            .sink { [weak self] address in
                guard let self, address != self.loadedAddress else { return }
                self.loadedAddress = address
                self.reload()
            }
    }

    private var unseenKey: String { "kapostsNotifCenter.unseen.\(loadedAddress)" }

    /// Delete Account: one wallet's count, from this device.
    static func removeAllData(forWalletAddress walletAddress: String) {
        UserDefaults.standard.removeObject(forKey: "kapostsNotifCenter.unseen.\(walletAddress)")
    }

    /// Loads the active wallet's count (account switches reload by themselves, see `init`).
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
