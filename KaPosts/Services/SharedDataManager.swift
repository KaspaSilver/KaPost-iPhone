import Foundation
import WidgetKit

/// Manages shared data between main app and notification extension via App Group
/// Both targets must have the same App Group entitlement configured
final class SharedDataManager {

    // MARK: - Constants

    static let appGroupIdentifier = "group.com.kachat.kaposts"

    private static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupIdentifier)
    }

    private static var sharedContainerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    }

    static func sharedDefaultsValue(forKey key: String) -> Any? {
        sharedDefaults?.object(forKey: key)
    }

    // MARK: - Keys

    private enum Keys {
        static let contacts = "shared_contacts"
        /// Contacts with calls enabled, for the Intents extension (`KaChatIntents`) to resolve
        /// "call X on KaChat" against - by KaChat address or name. Plain JSON
        /// `[{address, name}]`; the extension does not link the app's model types.
        static let callContacts = "call_contacts"
        /// The wallet `contacts` was written for. The blob itself is a single key holding
        /// whichever account synced last, so without a stamp the extension has no way to tell
        /// that the list in front of it belongs to a different account than the one now signed
        /// in - and would name a push using an alias from the wrong account.
        static let contactsWallet = "shared_contacts_wallet"
        static let groups = "shared_groups"
        static let sharedSecrets = "shared_secrets"
        static let pendingMessages = "pending_messages"
        static let storedMessages = "stored_messages"
        static let outboundShares = "outbound_shares"
        static let recentConversations = "kachat_recent_conversations"
        static let privateKeyAvailable = "private_key_available"
        static let walletAddress = "wallet_address"
        static let unreadCount = "shared_unread_count"
        static let incomingNotificationSoundEnabled = "incoming_notification_sound_enabled"
        static let incomingNotificationVibrationEnabled = "incoming_notification_vibration_enabled"
        /// Mirror of `AppSettings.verboseAPILogging` for the Notification Service Extension,
        /// which cannot read standard UserDefaults. Gates the NSE's push-payload debug residue
        /// (`storeLastPushDebug` + the payload-prefix os_log line). Absent key = off.
        static let verboseAPILogging = "shared_verbose_api_logging"
        static let groupMentionsOnlyNotifications = "shared_group_mentions_only"
        static let groupSilentNotifications = "shared_group_silent"
        static let kaPostsNotificationKinds = "shared_kaposts_notify_kinds"
        /// Mirror of `AppSettings.kaspaRestAPIURL` for the Notification Service Extension. A
        /// push for anything over 3.5KB carries no encrypted payload (see PUSH_NOTIFICATIONS.md),
        /// so the extension reads the message off chain itself to say what it is - and it needs
        /// to know which explorer API to ask, including on testnet or a custom host.
        static let kaspaRestAPIURL = "shared_kaspa_rest_api_url"
        static let groupOwnTxIds = "shared_group_own_txids"
        static let ownPrimaryKNSDomain = "shared_own_kns_domain"
        // Message Requests (NO_HANDSHAKE_MESSAGING.md), for the notification extension.
        static let chatRequestAddresses = "chat_request_addresses"
        static let chatBlockedAddresses = "chat_blocked_addresses"
        static let chatRequestsWallet = "chat_requests_wallet"
    }

    // KaPost has one target and no extensions. The contact, call-contact, chat-request,
    // recent-conversation, group and KNS-domain copies KaChat's extensions read were never read
    // here, so they are no longer written; `clearAllSharedData` still clears what an older
    // version left behind.

    /// Sync notification defaults used by the notification service extension.
    /// Deliberately nonisolated: UserDefaults is thread-safe and AppSettings.save is
    /// documented as callable from any context.
    /// Callers that just saved should pass the settings they saved - `AppSettings.load()` at
    /// that moment can still return the pre-save cached copy (the cache only invalidates on the
    /// `.settingsDidChange` post, which happens after this runs in the save paths).
    static func syncNotificationSettingsForExtension(_ settings: AppSettings = AppSettings.load()) {
        // The KaPosts switches ride with every settings save (and the launch sync), so the
        // extension's copy can never lag the app's - it used to be written only by the groups
        // sync, which runs on backgrounding and on the switches themselves.
        sharedDefaults?.set([
            "likes": settings.kaPostsNotifyLikes,
            "dislikes": settings.kaPostsNotifyDislikes,
            "comments": settings.kaPostsNotifyComments,
            "reposts": settings.kaPostsNotifyReposts,
            "follows": settings.kaPostsNotifyFollows,
            "mentions": settings.kaPostsNotifyMentions,
        ], forKey: Keys.kaPostsNotificationKinds)
        sharedDefaults?.set(settings.incomingNotificationSoundEnabled, forKey: Keys.incomingNotificationSoundEnabled)
        sharedDefaults?.set(settings.incomingNotificationVibrationEnabled, forKey: Keys.incomingNotificationVibrationEnabled)
        sharedDefaults?.set(settings.verboseAPILogging, forKey: Keys.verboseAPILogging)
        sharedDefaults?.set(settings.kaspaRestAPIURL, forKey: Keys.kaspaRestAPIURL)
        if !settings.verboseAPILogging {
            // Turning verbose logging off also clears the last captured push payload, so no
            // encrypted-payload residue outlives the diagnostics session that recorded it.
            sharedDefaults?.removeObject(forKey: "last_push_payload")
        }
    }

    /// Sync wallet address for notification extension (used to suppress outgoing pushes)
    @MainActor
    static func syncWalletAddressForExtension() {
        let address = WalletManager.shared.currentWallet?.publicAddress
        sharedDefaults?.set(address, forKey: Keys.walletAddress)
    }

    // MARK: - Shared Secrets

    // MARK: - Stored Messages (legacy: decrypted text an older extension kept; read once, removed)


    // MARK: - Outbound Shares (Share Extension -> Main App)

    // MARK: - Private Key Availability

    /// Check if private key is available (set by main app)
    static func setPrivateKeyAvailable(_ available: Bool) {
        sharedDefaults?.set(available, forKey: Keys.privateKeyAvailable)
    }

    // MARK: - Cleanup

    /// Clear all shared data (call on wallet delete)
    static func clearAllSharedData() {
        sharedDefaults?.removeObject(forKey: Keys.contacts)
        sharedDefaults?.removeObject(forKey: Keys.contactsWallet)
        // These outlived a deleted wallet: the Intents extension kept offering "call with
        // KaChat" for its contacts, and its groups and KNS name stayed readable.
        sharedDefaults?.removeObject(forKey: Keys.callContacts)
        sharedDefaults?.removeObject(forKey: Keys.groups)
        sharedDefaults?.removeObject(forKey: Keys.groupOwnTxIds)
        sharedDefaults?.removeObject(forKey: Keys.ownPrimaryKNSDomain)
        sharedDefaults?.removeObject(forKey: Keys.walletAddress)
        sharedDefaults?.removeObject(forKey: Keys.sharedSecrets)
        sharedDefaults?.removeObject(forKey: Keys.pendingMessages)
        sharedDefaults?.removeObject(forKey: Keys.storedMessages)
        sharedDefaults?.removeObject(forKey: Keys.privateKeyAvailable)
        sharedDefaults?.removeObject(forKey: Keys.outboundShares)
        sharedDefaults?.removeObject(forKey: Keys.recentConversations)
        sharedDefaults?.removeObject(forKey: Keys.unreadCount)
        sharedDefaults?.removeObject(forKey: Keys.incomingNotificationSoundEnabled)
        sharedDefaults?.removeObject(forKey: Keys.incomingNotificationVibrationEnabled)
        // Per-wallet data the extensions and the widget keep (IOS-053): message requests, push
        // bookkeeping and debug, group notification modes, and the portfolio widget's snapshot,
        // which kept showing a deleted wallet's holdings on the Home Screen.
        for key in [Keys.chatRequestAddresses, Keys.chatBlockedAddresses, Keys.chatRequestsWallet,
                    "chat_request_notified", "chat_request_notified_v2",
                    "chat_push_handled_txids", "group_push_handled_txids",
                    "last_push_payload", "last_push_sender", "last_push_tx_id", "last_push_type",
                    "last_push_decrypt_status",
                    Keys.groupSilentNotifications, Keys.groupMentionsOnlyNotifications, Keys.kaPostsNotificationKinds,
                    "kachat_portfolio_widget_store"] {
            sharedDefaults?.removeObject(forKey: key)
        }
        WidgetCenter.shared.reloadAllTimelines()
        if let sharedContainerURL {
            let outboundShareDirectory = sharedContainerURL
                .appendingPathComponent(SharedOutboundShare.ImageAttachment.rootDirectoryName, isDirectory: true)
            try? FileManager.default.removeItem(at: outboundShareDirectory)
        }
        AppLog.log("[SharedData] Cleared all shared data")
    }

    // MARK: - Unread Count (Badge)

    static func getUnreadCount() -> Int {
        return sharedDefaults?.integer(forKey: Keys.unreadCount) ?? 0
    }

    static func setUnreadCount(_ count: Int) {
        sharedDefaults?.set(max(0, count), forKey: Keys.unreadCount)
    }

}

// MARK: - Shared Models
