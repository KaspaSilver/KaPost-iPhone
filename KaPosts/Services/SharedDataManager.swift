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

    static func getWalletAddress() -> String? {
        return sharedDefaults?.string(forKey: Keys.walletAddress)
    }

    // MARK: - Shared Secrets

    /// Store a shared secret for a contact address (call when handshake is processed)
    static func storeSharedSecret(_ secret: Data, for address: String) {
        var secrets = getSharedSecrets()
        secrets[address] = secret.base64EncodedString()

        guard let data = try? JSONEncoder().encode(secrets) else {
            AppLog.log("[SharedData] Failed to encode shared secrets")
            return
        }

        sharedDefaults?.set(data, forKey: Keys.sharedSecrets)
        AppLog.log("[SharedData] Stored shared secret for %@", String(address.suffix(8)))
    }

    /// Get shared secret for a contact address
    static func getSharedSecret(for address: String) -> Data? {
        let secrets = getSharedSecrets()
        guard let base64 = secrets[address],
              let data = Data(base64Encoded: base64) else {
            return nil
        }
        return data
    }

    /// Get all shared secrets
    private static func getSharedSecrets() -> [String: String] {
        guard let data = sharedDefaults?.data(forKey: Keys.sharedSecrets),
              let secrets = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return secrets
    }

    /// Remove shared secret for an address (call when contact is deleted)
    static func removeSharedSecret(for address: String) {
        var secrets = getSharedSecrets()
        secrets.removeValue(forKey: address)

        if let data = try? JSONEncoder().encode(secrets) {
            sharedDefaults?.set(data, forKey: Keys.sharedSecrets)
        }
    }

    /// Clear all shared secrets (call on wallet delete)
    static func clearSharedSecrets() {
        sharedDefaults?.removeObject(forKey: Keys.sharedSecrets)
    }

    /// One-time hygiene at launch: `storeSharedSecret` has no callers anywhere in the app
    /// anymore (the NSE derives per-message secrets from the Keychain private key instead),
    /// but earlier releases DID write per-contact ECDH shared secrets into this plain-plist
    /// App Group key. Those bytes are message-decryption key material and have no business
    /// sitting in a UserDefaults plist, so wipe any legacy residue unconditionally.
    static func purgeLegacySharedSecretsIfPresent() {
        guard let defaults = sharedDefaults,
              defaults.object(forKey: Keys.sharedSecrets) != nil else { return }
        defaults.removeObject(forKey: Keys.sharedSecrets)
        AppLog.log("[SharedData] Purged legacy shared-secret blob from App Group defaults")
    }

    // MARK: - Pending Messages (txId only, need to fetch payload)

    /// Add a pending message that needs to be fetched when app opens
    static func addPendingMessage(txId: String, sender: String, type: String? = nil) {
        var pending = getPendingMessages()

        // Avoid duplicates
        guard !pending.contains(where: { $0.txId == txId }) else { return }

        pending.append(SharedPendingMessage(
            txId: txId,
            sender: sender,
            type: type,
            timestamp: Int64(Date().timeIntervalSince1970 * 1000)
        ))

        // Keep only last 100 pending messages
        if pending.count > 100 {
            pending = Array(pending.suffix(100))
        }

        if let data = try? JSONEncoder().encode(pending) {
            sharedDefaults?.set(data, forKey: Keys.pendingMessages)
        }
    }

    /// Get all pending messages
    static func getPendingMessages() -> [SharedPendingMessage] {
        guard let data = sharedDefaults?.data(forKey: Keys.pendingMessages) else {
            return []
        }

        // Try JSONDecoder first (app format)
        if let pending = try? JSONDecoder().decode([SharedPendingMessage].self, from: data) {
            return pending
        }

        // Fall back to JSONSerialization (extension format)
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        return array.compactMap { dict -> SharedPendingMessage? in
            guard let txId = dict["txId"] as? String,
                  let sender = dict["sender"] as? String else {
                return nil
            }
            let type = dict["type"] as? String
            let timestamp = (dict["timestamp"] as? Int64) ?? Int64(Date().timeIntervalSince1970 * 1000)
            return SharedPendingMessage(txId: txId, sender: sender, type: type, timestamp: timestamp)
        }
    }

    /// Clear all pending messages
    static func clearPendingMessages() {
        sharedDefaults?.removeObject(forKey: Keys.pendingMessages)
    }

    /// Replace pending messages list (used for retry persistence)
    static func setPendingMessages(_ pending: [SharedPendingMessage]) {
        if pending.isEmpty {
            clearPendingMessages()
            return
        }
        if let data = try? JSONEncoder().encode(pending) {
            sharedDefaults?.set(data, forKey: Keys.pendingMessages)
        }
    }

    /// Remove a specific pending message by txId
    static func removePendingMessage(txId: String) {
        let pending = getPendingMessages()
        let filtered = pending.filter { $0.txId != txId }
        setPendingMessages(filtered)
    }

    // MARK: - Stored Messages (legacy: decrypted text an older extension kept; read once, removed)

    /// Get all stored messages
    static func getStoredMessages() -> [[String: Any]] {
        return getStoredMessagesRaw()
    }

    private static func getStoredMessagesRaw() -> [[String: Any]] {
        guard let data = sharedDefaults?.data(forKey: Keys.storedMessages),
              let messages = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return messages
    }

    /// Removes only these entries: anything added meanwhile stays (IOS-052).
    static func removeStoredMessages(txIds: Set<String>) {
        guard !txIds.isEmpty else { return }
        let remaining = getStoredMessagesRaw().filter { !txIds.contains(($0["txId"] as? String) ?? "") }
        if remaining.isEmpty {
            sharedDefaults?.removeObject(forKey: Keys.storedMessages)
        } else if let data = try? JSONSerialization.data(withJSONObject: remaining) {
            sharedDefaults?.set(data, forKey: Keys.storedMessages)
        }
    }


    // MARK: - Outbound Shares (Share Extension -> Main App)

    static func enqueueOutboundShare(contactAddress: String, text: String, autoSend: Bool = true) -> SharedOutboundShare? {
        let cleanedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedText.isEmpty else { return nil }

        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        var shares = getOutboundShares()
            .filter { nowMs - $0.createdAtMs <= SharedOutboundShare.maxAgeMs }

        let share = SharedOutboundShare(
            id: UUID().uuidString,
            contactAddress: contactAddress,
            text: cleanedText,
            createdAtMs: nowMs,
            autoSend: autoSend
        )
        shares.append(share)

        if shares.count > SharedOutboundShare.maxStoredItems {
            shares = Array(shares.suffix(SharedOutboundShare.maxStoredItems))
        }

        guard let data = try? JSONEncoder().encode(shares) else {
            AppLog.log("[SharedData] Failed to encode outbound shares")
            return nil
        }

        sharedDefaults?.set(data, forKey: Keys.outboundShares)
        return share
    }

    static func outboundShareImageFileURL(for image: SharedOutboundShare.ImageAttachment) -> URL? {
        guard let sharedContainerURL else { return nil }
        return sharedContainerURL.appendingPathComponent(image.relativePath, isDirectory: false)
    }

    static func getOutboundShare(id: String) -> SharedOutboundShare? {
        getOutboundShares().first { $0.id == id }
    }

    static func getOutboundShares() -> [SharedOutboundShare] {
        guard let data = sharedDefaults?.data(forKey: Keys.outboundShares),
              let shares = try? JSONDecoder().decode([SharedOutboundShare].self, from: data) else {
            return []
        }
        return shares
    }

    static func removeOutboundShare(id: String) {
        let shares = getOutboundShares()
        if let share = shares.first(where: { $0.id == id }) {
            removeOutboundShareFiles(for: share)
        }
        let filtered = shares.filter { $0.id != id }
        if filtered.isEmpty {
            sharedDefaults?.removeObject(forKey: Keys.outboundShares)
            return
        }
        if let data = try? JSONEncoder().encode(filtered) {
            sharedDefaults?.set(data, forKey: Keys.outboundShares)
        }
    }

    static func pruneOutboundShares() {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let shares = getOutboundShares()
        let filtered = shares.filter { nowMs - $0.createdAtMs <= SharedOutboundShare.maxAgeMs }
        let expired = shares.filter { nowMs - $0.createdAtMs > SharedOutboundShare.maxAgeMs }
        expired.forEach(removeOutboundShareFiles)
        if filtered.isEmpty {
            sharedDefaults?.removeObject(forKey: Keys.outboundShares)
            return
        }
        if let data = try? JSONEncoder().encode(filtered) {
            sharedDefaults?.set(data, forKey: Keys.outboundShares)
        }
    }

    private static func removeOutboundShareFiles(for share: SharedOutboundShare) {
        guard share.image != nil,
              let sharedContainerURL else { return }
        let directory = sharedContainerURL
            .appendingPathComponent(SharedOutboundShare.ImageAttachment.rootDirectoryName, isDirectory: true)
            .appendingPathComponent(share.id, isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Private Key Availability

    /// Check if private key is available (set by main app)
    static func setPrivateKeyAvailable(_ available: Bool) {
        sharedDefaults?.set(available, forKey: Keys.privateKeyAvailable)
    }

    static func isPrivateKeyAvailable() -> Bool {
        return sharedDefaults?.bool(forKey: Keys.privateKeyAvailable) ?? false
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

    static func incrementUnreadCount() -> Int {
        let newValue = max(0, getUnreadCount() + 1)
        setUnreadCount(newValue)
        return newValue
    }

    static func resetUnreadCount() {
        setUnreadCount(0)
    }
}

// MARK: - Shared Models

struct SharedGroupMember: Codable {
    let address: String
    let xOnlyPubKeyHex: String
    /// Snapshot of whoever added this member's own contact alias for them at add-time (see
    /// `GroupMember.displayName`) - lets the notification extension show a real name for the
    /// sender of a group message instead of falling back to their raw address.
    let displayName: String?
}

/// Pending message that needs to be fetched
struct SharedPendingMessage: Codable {
    let txId: String
    let sender: String
    let type: String?
    let timestamp: Int64

    init(txId: String, sender: String, type: String? = nil, timestamp: Int64) {
        self.txId = txId
        self.sender = sender
        self.type = type
        self.timestamp = timestamp
    }

    // Handle both old format (without type) and new format (with type)
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        txId = try container.decode(String.self, forKey: .txId)
        sender = try container.decode(String.self, forKey: .sender)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        timestamp = try container.decode(Int64.self, forKey: .timestamp)
    }
}
