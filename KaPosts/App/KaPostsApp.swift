import SwiftUI
import AVFoundation
import UserNotifications
import UIKit

@main
struct KaPostsApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var walletManager = WalletManager.shared
    @StateObject private var contactsManager = ContactsManager.shared
    @StateObject private var chatService = ChatService.shared
    @StateObject private var settingsViewModel = SettingsViewModel()
    @StateObject private var pushManager = PushNotificationManager.shared
    @StateObject private var publicChatService = PublicChatService.shared
    /// The blur over the app in the App Switcher and behind system prompts: the balance and the
    /// seed screen would otherwise sit in iOS's snapshot of the app in plain view.
    @State private var showPrivacyCover = false
    @State private var lastActiveResyncAt: Date?
    @State private var hasCompletedFirstActiveTransition = false
    @Environment(\.scenePhase) private var scenePhase

    /// Below this, becoming active again skips the node pool's reconnect sweep: glancing at the
    /// App Switcher for a second shouldn't re-run it.
    private let activeResyncDebounce: TimeInterval = 15

    init() {
        // A Testnet/Mainnet switch chosen in Settings takes effect here, before any service
        // reads the settings, so the whole app starts on one network.
        PendingNetworkSwitch.applyAtLaunch()
        // Warm up audio session and crypto on a background thread to avoid first-interaction lag.
        Task.detached(priority: .utility) {
            await Self.warmUp()
        }
        // People shown as their address are asked again for a .kachat name, once a minute.
        KachatNamesRegistry.shared.startUnnamedIdentitySweep()
        // The KAS price for the amount fields, from the first frame.
        _ = KaspaPriceService.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(walletManager)
                .environmentObject(contactsManager)
                .environmentObject(chatService)
                .environmentObject(settingsViewModel)
                .environmentObject(pushManager)
                .environmentObject(publicChatService)
                .overlay {
                    if showPrivacyCover {
                        PrivacyCoverView()
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.15), value: showPrivacyCover)
                .onAppear {
                    ChatService.shared.settingsViewModel = settingsViewModel
                    applyWindowAppearanceOverride()
                }
                .onOpenURL { url in
                    handleIncomingURL(url)
                }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    // Universal links (https://kachat.app/post/<txid>, rooms, profiles).
                    if let url = activity.webpageURL {
                        handleIncomingURL(url)
                    }
                }
                .preferredColorScheme(settingsViewModel.settings.appearance.colorScheme)
                .onChange(of: settingsViewModel.settings.appearance) { _ in
                    applyWindowAppearanceOverride()
                }
                .environment(\.locale, settingsViewModel.settings.language.locale ?? .autoupdatingCurrent)
        }
        .onChange(of: scenePhase) { newPhase in
            handleScenePhaseChange(to: newPhase)
        }
    }

    /// `.preferredColorScheme` only themes SwiftUI content; the UIKit layer underneath (sheet
    /// edges, the keyboard, share sheets) follows the device. Overriding the windows' interface
    /// style makes the whole window chrome match.
    private func applyWindowAppearanceOverride() {
        let style: UIUserInterfaceStyle
        switch settingsViewModel.settings.appearance {
        case .system: style = .unspecified
        case .light: style = .light
        case .dark: style = .dark
        }
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.overrideUserInterfaceStyle = style
                // The tab bar keeps the old theme's colours after a switch until relaunch unless
                // its appearance is re-applied.
                Self.refreshTabBars(in: window.rootViewController)
            }
        }
    }

    private static func refreshTabBars(in root: UIViewController?) {
        guard let root else { return }
        var queue: [UIViewController] = [root]
        while let controller = queue.popLast() {
            if let tabs = controller as? UITabBarController {
                let appearance = UITabBarAppearance()
                appearance.configureWithDefaultBackground()
                tabs.tabBar.standardAppearance = appearance
                tabs.tabBar.scrollEdgeAppearance = appearance
                tabs.tabBar.setNeedsLayout()
                tabs.tabBar.layoutIfNeeded()
            }
            queue.append(contentsOf: controller.children)
            if let presented = controller.presentedViewController { queue.append(presented) }
        }
    }

    private func handleScenePhaseChange(to newPhase: ScenePhase) {
        // Covered the moment the app stops being the thing in front, uncovered when it is again.
        showPrivacyCover = newPhase != .active
        switch newPhase {
        case .background:
            KaPostsNotificationService.shared.stop()
        case .active:
            LaunchTrace.mark("scene active")
            // KaPosts activity (likes, replies, quotes on your posts) - the in-app poller, which
            // runs only while the app is active.
            KaPostsNotificationService.shared.start()
            // .kachat registrations in flight resume after a relaunch.
            KachatNamesActions.shared.resume()
            Task { @MainActor in await KachatNamesRegistry.shared.refreshIfStale() }

            let isFirstActiveTransition = !hasCompletedFirstActiveTransition
            hasCompletedFirstActiveTransition = true
            // Let the first render settle before the reconnect sweep competes with it for the
            // main thread.
            let coldStartGraceNanos: UInt64 = isFirstActiveTransition ? 2_000_000_000 : 0
            let shouldRunHeavyResync = lastActiveResyncAt.map {
                Date().timeIntervalSince($0) > activeResyncDebounce
            } ?? true
            if shouldRunHeavyResync {
                lastActiveResyncAt = Date()
                // gRPC connections can die silently while backgrounded: reconnect the dead ones
                // now rather than on the next request.
                Task {
                    if coldStartGraceNanos > 0 {
                        try? await Task.sleep(nanoseconds: coldStartGraceNanos)
                    }
                    await NodePoolService.shared.reconnectStaleConnections()
                }
            }
            if settingsViewModel.settings.notificationMode == .remotePush {
                pushManager.refreshRegistrationIfNeeded()
            }
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    private func handleIncomingURL(_ url: URL) {
        // Every in-app target link - posts, rooms, profiles, payment requests, in their
        // `kachat://` and `https://kachat.app/...` forms - is parsed in one place and routed in
        // one place, shared with the in-app preview cards.
        if let link = KaChatInternalLink.parse(url) {
            KaChatLinkRouter.open(link)
        }
    }

    /// Pre-initialize heavy components to avoid lag on first user interaction.
    private static func warmUp() async {
        // Voice notes in public rooms record through this session.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
        // Warm up the crypto library with a dummy operation.
        let dummyKey = Data(repeating: 0x01, count: 32)
        _ = try? KasiaCipher.encrypt("warmup", recipientPublicKey: dummyKey)
    }
}

// MARK: - App Delegate for notifications

class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Which KaPosts pushes the reader still wants shown, by the Settings switches.
    ///
    /// `kaposts_kind` is the field the server should send; failing that the body is matched
    /// against the exact English phrases PUSH_EXTENSIONS.md §3 specifies - server-generated and
    /// unlocalized, so a fixed set. An unrecognised push is shown rather than swallowed.
    static func kaPostsPushAllowed(userInfo: [AnyHashable: Any], body: String, settings: AppSettings) -> Bool {
        let key: String
        if let explicit = userInfo["kaposts_kind"] as? String {
            switch explicit {
            case "vote_up": key = "likes"
            case "vote_down": key = "dislikes"
            case "reply": key = "comments"
            case "quote", "repost": key = "reposts"
            case "follow": key = "follows"
            case "mention": key = "mentions"
            default: return true
            }
        } else {
            let lowered = body.lowercased()
            if lowered.contains("disliked your") { key = "dislikes" }
            else if lowered.contains("liked your") { key = "likes" }
            else if lowered.contains("replied to your") { key = "comments" }
            else if lowered.contains("quoted your") || lowered.contains("reposted your") { key = "reposts" }
            else if lowered.contains("followed you") { key = "follows" }
            else if lowered.contains("mentioned you") { key = "mentions" }
            else { return true }
        }
        switch key {
        case "likes": return settings.kaPostsNotifyLikes
        case "dislikes": return settings.kaPostsNotifyDislikes
        case "comments": return settings.kaPostsNotifyComments
        case "reposts": return settings.kaPostsNotifyReposts
        case "follows": return settings.kaPostsNotifyFollows
        case "mentions": return settings.kaPostsNotifyMentions
        default: return true
        }
    }

    /// iPhone is locked to portrait; iPad may rotate.
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .pad ? .all : .portrait
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        Task.detached(priority: .utility) { CacheManager.sweepStaleTempFiles() }
        UNUserNotificationCenter.current().delegate = self
        // Warm up the keyboard to avoid the first-tap delay (after the scene exists).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            Self.warmUpKeyboard()
        }
        return true
    }

    // MARK: APNs token

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in
            PushNotificationManager.shared.didRegisterForRemoteNotifications(deviceToken: deviceToken)
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in
            PushNotificationManager.shared.didFailToRegisterForRemoteNotifications(error: error)
        }
    }

    private static func warmUpKeyboard() {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first else { return }
        let textField = UITextField()
        textField.autocorrectionType = .no
        textField.inputAssistantItem.leadingBarButtonGroups = []
        textField.inputAssistantItem.trailingBarButtonGroups = []
        textField.frame = CGRect(x: -100, y: -100, width: 10, height: 10)
        window.addSubview(textField)
        textField.becomeFirstResponder()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            textField.resignFirstResponder()
            textField.removeFromSuperview()
        }
    }

    // MARK: Foreground presentation

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo
        let threadId = notification.request.content.threadIdentifier
        let body = notification.request.content.body
        Task { @MainActor in
            let settings = AppSettings.load()
            var options: UNNotificationPresentationOptions = [.banner, .badge]
            if settings.incomingNotificationSoundEnabled {
                options.insert(.sound)
            }
            if threadId == "kaposts" {
                // The per-kind switches; and no banner while the Notifications screen is open.
                if !Self.kaPostsPushAllowed(userInfo: userInfo, body: body, settings: settings)
                    || (UIApplication.shared.applicationState == .active
                        && KaPostsNotificationService.shared.isNotificationsScreenVisible) {
                    completionHandler([])
                    return
                }
            } else if threadId.hasPrefix("broadcast:") {
                // No banner for the room you are reading.
                let channel = String(threadId.dropFirst("broadcast:".count))
                if UIApplication.shared.applicationState == .active,
                   PublicChatService.shared.isViewing(channel: channel) {
                    completionHandler([])
                    return
                }
            }
            if !options.contains(.sound), settings.incomingNotificationVibrationEnabled {
                Haptics.impact(.light)
            }
            completionHandler(options)
        }
    }

    // MARK: Notification tap

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let threadIdentifier = response.notification.request.content.threadIdentifier
        let userInfo = response.notification.request.content.userInfo

        // The scheduled-post reminder (local fallback): into KaPosts, which sends what is due
        // and shows the Scheduled screen.
        if threadIdentifier == "kaposts-scheduled" {
            KaPostsDeepLink.pendingOpenScheduled = true
            NotificationCenter.default.post(name: .openKaPost, object: nil, userInfo: [:])
            completionHandler()
            return
        }

        // KaPosts push (thread-id "kaposts"): straight to the post when the payload names one,
        // else the Notifications screen.
        if threadIdentifier == "kaposts" {
            // A tapped push leaves Notification Center, so the poller can no longer see it:
            // record its action id so the next poll doesn't banner it again.
            if response.notification.request.trigger is UNPushNotificationTrigger {
                let actionId = response.notification.request.identifier
                Task { @MainActor in
                    KaPostsNotificationService.shared.recordDisplayed(actionId: actionId)
                }
            }
            if let postId = userInfo["postId"] as? String, !postId.isEmpty {
                KaPostsDeepLink.pendingPostTxId = postId
            } else {
                KaPostsDeepLink.pendingOpenNotifications = true
            }
            NotificationCenter.default.post(name: .openKaPost, object: nil, userInfo: [:])
            completionHandler()
            return
        }

        if threadIdentifier.hasPrefix("broadcast:") {
            let channel = String(threadIdentifier.dropFirst("broadcast:".count))
            if !channel.isEmpty {
                // Pending for a cold start, and the room's newest rows asked for right away: the
                // announced message is not in the store yet.
                Task { @MainActor in
                    PublicChatService.shared.pendingPublicChatNavigation = channel
                    await PublicChatService.shared.refreshFromIndexerNow(channel: channel)
                }
                NotificationCenter.default.post(name: .openPublicChat, object: nil, userInfo: ["channel": channel])
            }
        }
        completionHandler()
    }
}

/// Cold-start handoff for KaPosts links and notification taps - the notification alone is lost
/// if KaPostsView isn't mounted yet.
enum KaPostsDeepLink {
    static var pendingPostTxId: String?
    /// KaPosts push tapped without a specific post - open the Notifications screen on mount.
    static var pendingOpenNotifications = false
    /// The scheduled-post reminder tapped - open the Scheduled screen on mount.
    static var pendingOpenScheduled = false
    /// Someone's KaPosts profile, asked for from another tab (a Public Chats member, a link).
    static var pendingProfileAddress: String?
}

/// The single place an already-validated `KaChatInternalLink` becomes navigation. Used by the
/// system URL router (links tapped outside the app) AND by the in-app preview cards, so a link
/// opens the same screen whichever way the user reached it.
enum KaChatLinkRouter {
    /// Any URL a user taps inside the app: a KaChat link (kachat.app or the kachat:// scheme)
    /// goes straight to its post or room; everything else leaves the app as usual.
    @MainActor
    static func openAnywhere(_ url: URL) {
        if let link = KaChatInternalLink.parse(url) {
            open(link)
            return
        }
        guard isSafeExternalLink(url) else {
            AppLog.log("[Links] refused to open a %@ link from content", url.scheme ?? "schemeless")
            return
        }
        UIApplication.shared.open(url)
    }

    /// Links that other people's content (posts, messages, profiles) may open outside the app:
    /// the web and email. Anything else - `shortcuts://run-shortcut`, another app's deep link,
    /// `tel:` - stays inert, since the text detectors link every scheme and one tap would run it.
    static func isSafeExternalLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https" || scheme == "mailto"
    }

    @MainActor
    static func open(_ link: KaChatInternalLink) {
        switch link {
        case .kaPost(let txId):
            guard !txId.isEmpty else { return }
            KaPostsDeepLink.pendingPostTxId = txId
            NotificationCenter.default.post(name: .openKaPost, object: nil, userInfo: ["txId": txId])
        case .publicChatRoom(let channel):
            openPublicChatRoom(channel: channel)
        case .profile(let address):
            let normalized = address.lowercased()
            guard KaspaAddress.isValid(normalized) else { return }
            KaPostsDeepLink.pendingProfileAddress = normalized
            NotificationCenter.default.post(name: .openKaPostsProfile, object: nil)
        case .paymentRequest(let request):
            // Send Kaspa with it filled in (`PaymentRequestSheetPresenter`, on the dock).
            PaymentRequestRouter.shared.pending = request
        }
    }

    @MainActor
    private static func openPublicChatRoom(channel: String) {
        // Re-validated here, the last gate before a name from a pasted link can create a row.
        guard let normalized = KaChatInternalLink.normalizeAndValidateChannel(channel) else { return }
        // Curated rooms always exist; anything else joins the user's own list first, as if
        // typed into "Join or Create a Channel".
        if !PublicChatService.curatedChannels.contains(normalized) {
            PublicChatService.shared.joinChannel(normalized)
        }
        PublicChatService.shared.pendingPublicChatNavigation = normalized
        NotificationCenter.default.post(name: .openPublicChat, object: nil, userInfo: ["channel": normalized])
    }
}

extension Notification.Name {
    static let openChat = Notification.Name("openChat")
    /// Opens the address profile editor (the profile's Edit Profile button).
    static let openKNSProfileEditor = Notification.Name("openKNSProfileEditor")
    static let openKaPost = Notification.Name("openKaPost")
    static let openKaPostsProfile = Notification.Name("openKaPostsProfile")
    /// A `.kachat` name notification was tapped: the name is in `KachatDeepLink.pendingName`.
    static let openKachatName = Notification.Name("openKachatName")
    static let openPublicChat = Notification.Name("openBroadcast")
}

/// What the App Switcher and a system prompt see instead of the app's contents: the app's own
/// logo (the icon's art), shaped like its home-screen icon.
private struct PrivacyCoverView: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Image("KaPostsLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 3)
        }
        .ignoresSafeArea()
    }
}
