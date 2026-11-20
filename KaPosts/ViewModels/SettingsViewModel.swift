import Foundation
import Combine

/// Thread-safe cache for `AppSettings.load()`. Load used to do a UserDefaults read + a fresh
/// JSONDecoder + a full ~25-field decode on EVERY call - and it's called from hot paths (per
/// Kaspa block in the group/public chat scanners at ~10 blocks/sec, per day-separator render, per
/// API request). Invalidated whenever settings change (`.settingsDidChange` is posted by every
/// write path: `AppSettings.save` and `SettingsViewModel.saveSettings`).
/// The Testnet toggle's choice, waiting for the next launch. The wallet address, the node pool and
/// every service are set up for one network at launch, so switching `networkType` live left the
/// app half on each: indexer, push and .kachat moved at once while the wallet and node stayed,
/// and incoming messages were dropped as "the other network" (IOS-002). The toggle only records
/// the choice here; `applyAtLaunch()` switches everything together when the app next starts.
enum PendingNetworkSwitch {
    private static let key = "kachat_pending_network_type"

    static var target: NetworkType? {
        get { UserDefaults.standard.string(forKey: key).flatMap(NetworkType.init(rawValue:)) }
        set {
            if let newValue { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }

    /// Call first thing at app launch, before anything reads the settings.
    static func applyAtLaunch() {
        guard let target else { return }
        self.target = nil
        var settings = AppSettings.load()
        guard target != settings.networkType else { return }
        settings.switchNetwork(to: target)
        AppSettings.save(settings)
    }
}

private final class AppSettingsCache: @unchecked Sendable {
    static let shared = AppSettingsCache()
    private let lock = NSLock()
    private var cached: AppSettings?
    private var observer: NSObjectProtocol?
    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: .settingsDidChange, object: nil, queue: nil
        ) { [weak self] _ in
            self?.invalidate()
        }
    }
    func get() -> AppSettings? { lock.lock(); defer { lock.unlock() }; return cached }
    func set(_ settings: AppSettings) { lock.lock(); defer { lock.unlock() }; cached = settings }
    func invalidate() { lock.lock(); defer { lock.unlock() }; cached = nil }

    /// True while the stored settings couldn't be decoded this run: what is stored is left as it
    /// is (its copy is under `AppSettings.backupStorageKey`) until a save carries a real change.
    private var storedCopyUndecodable = false
    var holdsUndecodableCopy: Bool {
        get { lock.lock(); defer { lock.unlock() }; return storedCopyUndecodable }
        set { lock.lock(); defer { lock.unlock() }; storedCopyUndecodable = newValue }
    }
}

/// Extension to load settings from any context (not MainActor-isolated)
extension AppSettings {
    /// Biometrics for Account Login went from on to off by default (owner's call, 2026-11-05) and
    /// saved settings hold the old `true`. Switched off once per install, so turning it back on
    /// sticks. It runs ahead of the first read, and every in-memory copy of the settings starts
    /// from `load()`, so nothing can save the old value back over it. A `static let` so one thread
    /// does this while any others wait, which is also why it posts no change notification: an
    /// observer calling `load()` from inside this would never return.
    private static let accountLoginBiometricsOffMigration: Void = {
        let defaults = UserDefaults.standard
        let doneKey = "kachat_account_login_biometrics_off_migrated"
        guard !defaults.bool(forKey: doneKey) else { return }
        if let data = defaults.data(forKey: storageKey),
           var settings = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings.biometricAccountLoginEnabled = false
            if let updated = try? JSONEncoder().encode(settings) {
                defaults.set(updated, forKey: storageKey)
            }
        }
        defaults.set(true, forKey: doneKey)
    }()

    static let storageKey = "kachat_app_settings"
    /// A copy of stored settings that couldn't be decoded, kept before anything can overwrite them.
    static let backupStorageKey = "kachat_app_settings_backup"

    /// Load settings from UserDefaults (can be called from any context). Cached - see
    /// `AppSettingsCache`. Each field decodes on its own (`decodeLossy`), so one bad value resets
    /// only that field.
    static func load() -> AppSettings {
        _ = accountLoginBiometricsOffMigration
        if let cached = AppSettingsCache.shared.get() { return cached }
        let userDefaults = UserDefaults.standard
        guard let data = userDefaults.data(forKey: storageKey) else {
            AppSettingsCache.shared.set(.default)
            return .default
        }
        let decoded: AppSettings
        do {
            decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        } catch {
            // Fields decode one by one (`decodeLossy`), so this is a blob that isn't settings at
            // all. Run on the defaults, but keep the stored copy: back it up, and `store` leaves it
            // in place until a setting is actually changed.
            AppLog.log("[Settings] Saved settings could not be read (%@); using defaults, stored copy kept", String(describing: error))
            if userDefaults.data(forKey: backupStorageKey) != data {
                userDefaults.set(data, forKey: backupStorageKey)
            }
            AppSettingsCache.shared.holdsUndecodableCopy = true
            AppSettingsCache.shared.set(.default)
            return .default
        }
        var settings = decoded
        // One-time migration for anyone still pointed at a superseded default indexer - the
        // offline kasia.fyi, or the previous community default kasia.wtf now replaced by KaChat's
        // own indexer (indexer.kachat.app). Users who set a custom indexer keep it; only the old
        // shipped defaults are moved.
        if settings.indexerURL == legacyDefaultIndexerURL || settings.indexerURL == legacyDefaultIndexerURLKasiaWtf {
            settings.indexerURL = defaultIndexerURL
            save(settings)
        }
        // One-time migration for anyone still pointed at the public K social indexer
        // (mainnet.kaspatalk.net) - KaPosts now runs on KaChat's own indexer. Users who set a
        // custom KaPost indexer URL keep it; only the old shipped default is moved.
        if settings.kaPostIndexerURL == legacyDefaultKaPostIndexerURL {
            settings.kaPostIndexerURL = defaultKaPostIndexerURL
            save(settings)
        }
        AppSettingsCache.shared.set(settings)
        return settings
    }

    /// Symmetric write path for services that don't hold a `SettingsViewModel` reference (e.g.
    /// SwapService persisting the swap disclaimer flag) - same storage key/notification as
    /// `SettingsViewModel.saveSettings()`, just callable without an instance.
    static func save(_ settings: AppSettings) {
        guard store(settings) else { return }
        // Keep the app-group mirror current on this path too - the Diagnostics page's Verbose
        // API Logging toggle saves through here, and the NSE reads that flag from the mirror.
        SharedDataManager.syncNotificationSettingsForExtension(settings)
        NotificationCenter.default.post(name: .settingsDidChange, object: settings)
    }

    /// Writes `settings` to storage, the one place both save paths go through. While the stored
    /// copy couldn't be decoded, saving the untouched defaults is skipped, so automatic saves never
    /// replace the stored settings with defaults; the first save with a real change writes.
    /// Returns false only when encoding fails.
    @discardableResult
    static func store(_ settings: AppSettings) -> Bool {
        guard let data = try? JSONEncoder().encode(settings) else { return false }
        if AppSettingsCache.shared.holdsUndecodableCopy {
            let sorted = JSONEncoder()
            sorted.outputFormatting = .sortedKeys
            if let candidate = try? sorted.encode(settings),
               let defaults = try? sorted.encode(AppSettings.default),
               candidate == defaults {
                return true
            }
            AppSettingsCache.shared.holdsUndecodableCopy = false
        }
        UserDefaults.standard.set(data, forKey: storageKey)
        return true
    }
}

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var settings: AppSettings

    /// The network the app started on. The node pool, the wallet address and every service are
    /// set up for it at launch, so a switch in Connection Settings takes effect on the next
    /// launch - this is what tells the Testnet tab to say so.
    let launchNetworkType: NetworkType

    init() {
        let loaded = AppSettings.load()
        self.settings = loaded
        self.launchNetworkType = loaded.networkType
        // Account switches post .settingsDidChange with a nil object (see WalletManager): the
        // settings are read again. Saves post WITH the settings object - skipped here, this
        // instance already holds those values.
        NotificationCenter.default.addObserver(
            forName: .settingsDidChange, object: nil, queue: .main
        ) { [weak self] notification in
            guard notification.object == nil else { return }
            Task { @MainActor [weak self] in
                self?.settings = AppSettings.load()
            }
        }
    }

    /// Load settings (MainActor convenience)
    static func loadSettings() -> AppSettings {
        return AppSettings.load()
    }

    func saveSettings() {
        guard AppSettings.store(settings) else { return }
        SharedDataManager.syncNotificationSettingsForExtension(settings)

        // Notify other services of settings changes
        NotificationCenter.default.post(name: .settingsDidChange, object: settings)
    }

    /// Settings > Connection > Testnet. Only records the choice: the switch, with each network's
    /// own connection settings (`AppSettings.switchNetwork(to:)`), happens at the next launch
    /// (`PendingNetworkSwitch`). Choosing the network the app runs on cancels a pending switch.
    func switchNetwork(to network: NetworkType) {
        objectWillChange.send()
        PendingNetworkSwitch.target = network == launchNetworkType ? nil : network
    }

    /// The network the Testnet toggle shows: the pending choice, else the one running.
    var selectedNetworkType: NetworkType { PendingNetworkSwitch.target ?? settings.networkType }

    // MARK: - Convenience Methods
    var kaspaExplorer: KaspaExplorer {
        get { settings.kaspaExplorer }
        set {
            settings.kaspaExplorer = newValue
            saveSettings()
        }
    }

    /// Validates and applies a new trusted-node address (empty = automatic discovery instead of a
    /// pinned node). Returns a user-facing error message and leaves `settings` untouched if
    /// `value` is non-empty but not a valid endpoint; returns `nil` on success. Shared by
    /// `ConnectionSettingsView` and the Welcome Guide's node-connection step so both stay in sync
    /// with `NodePoolService`, not just `AppSettings`.
    @discardableResult
    func applyTrustedNode(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty || Endpoint(url: trimmed) != nil else {
            return "Enter as host:port or grpcs://host"
        }
        guard trimmed != settings.trustedNodeAddress else { return nil }
        settings.trustedNodeAddress = trimmed
        saveSettings()
        Task {
            await NodePoolService.shared.setTrustedNodeAddress(trimmed)
        }
        return nil
    }

    /// Sets or clears the standard `AppleLanguages` preferred-language override. The main app
    /// itself doesn't need this (it picks up a language change immediately via
    /// `.environment(\.locale, ...)` in `KaPostsApp.swift`, no restart) - this is for the pieces
    /// that run as their own separate OS process and can't observe that in-memory environment
    /// override at all: the Notification Service Extension, Share Extension, and the OS's own
    /// Bundle-driven resolution on the next cold launch of any of them. Shared by the Settings >
    /// Language picker and the Welcome Guide's language step.
    func applyLanguagePreference(_ language: AppLanguage) {
        if let code = language.appleLanguageCode {
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
    }
}

extension Notification.Name {
    static let settingsDidChange = Notification.Name("settingsDidChange")
}
