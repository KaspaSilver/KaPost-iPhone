import SwiftUI

/// The KaPosts dock: Feed, Public Chats, Profile, Notifications, Settings - always these five,
/// in this order. KaPosts is one address doing one thing, so there is no Customize Dock. The
/// Wallet is a button on your Profile.
struct KaPostsTabView: View {
    enum Tab: Int, CaseIterable, Identifiable {
        case feed, publicChats, profile, notifications, settings

        var id: Int { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .feed: return "Feed"
            case .publicChats: return "Public Chats"
            case .profile: return "Profile"
            case .notifications: return "Notifications"
            case .settings: return "Settings"
            }
        }

        var icon: String {
            switch self {
            case .feed: return "square.text.square"
            case .publicChats: return "bubble.left.and.text.bubble.right"
            case .profile: return "person.crop.circle"
            case .notifications: return "bell"
            case .settings: return "gearshape"
            }
        }
    }

    /// Shared with the dock copy on full-screen screens (`KaPostsDockCopy`), which selects tabs
    /// too.
    @ObservedObject private var dock = KaPostsDockRouter.shared
    /// The address profile editor (name, picture, banner, bio) - the profile KaPosts shows.
    @State private var showProfileEditor = false
    /// The Welcome Guide after a create or import (`WelcomeGuideView`), and after a kill that cut
    /// one short.
    @State private var showWelcomeGuide = false
    /// A tapped "Received kUSDT" notification (`TokenRoute`): that token's Manage screen, as a
    /// sheet over whatever tab is showing (the Wallet is two screens deep under Profile).
    @State private var openToken: WalletToken?
    @EnvironmentObject private var walletManager: WalletManager
    @ObservedObject private var kaPostsNotifCenter = KaPostsNotificationCenter.shared
    @ObservedObject private var publicChatBadge = PublicChatUnreadBadge.shared

    var body: some View {
        // Through `select`, which also hears a tap on the tab already showing - that is how
        // Feed gets back to its top.
        TabView(selection: Binding(get: { dock.selectedTab }, set: { dock.select($0) })) {
            KaPostsPageView()
                .tabItem { Label(Tab.feed.title, systemImage: Tab.feed.icon) }
                .tag(Tab.feed)

            NavigationStack {
                PublicChatListView()
            }
            .tabItem { Label(Tab.publicChats.title, systemImage: Tab.publicChats.icon) }
            // unread messages across the rooms
            .badge(publicChatBadge.count > 0 ? Text(verbatim: publicChatBadge.badgeText) : nil)
            .tag(Tab.publicChats)

            KaPostsView(rootMode: .myProfile)
                .tabItem { Label(Tab.profile.title, systemImage: Tab.profile.icon) }
                .tag(Tab.profile)

            KaPostsNotificationsView()
                // Opening the tab IS seeing them - cleared on appear rather than on leaving, so
                // the badge does not sit there while you read.
                .onAppear { kaPostsNotifCenter.markAllSeen() }
                .tabItem { Label(Tab.notifications.title, systemImage: Tab.notifications.icon) }
                .badge(kaPostsNotifCenter.unseenCount > 0 ? Text(verbatim: kaPostsNotifCenter.badgeText) : nil)
                .tag(Tab.notifications)

            SettingsView()
                .tabItem { Label(Tab.settings.title, systemImage: Tab.settings.icon) }
                .tag(Tab.settings)
        }
        .tint(.accentColor)
        .onReceive(NotificationCenter.default.publisher(for: .openKaPost)) { _ in
            // A tapped KaPosts notification push lands on the Notifications tab; a post link
            // or a post opened from a notification row, on the Feed.
            if KaPostsDeepLink.pendingOpenNotifications {
                KaPostsDeepLink.pendingOpenNotifications = false
                dock.selectedTab = .notifications
            } else {
                dock.selectedTab = .feed
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openKaPostsProfile)) { _ in
            dock.selectedTab = .feed
        }
        .onReceive(NotificationCenter.default.publisher(for: .openPublicChat)) { _ in
            // A tapped room push or room link: a thread or profile open over the tabs would sit
            // on top of the room, so they close first, as for a tap on the dock copy.
            NotificationCenter.default.post(name: .kaPostsCloseCovers, object: nil)
            dock.selectedTab = .publicChats
        }
        // Posted by the profile's Edit Profile button.
        .onReceive(NotificationCenter.default.publisher(for: .openKNSProfileEditor)) { _ in
            showProfileEditor = true
        }
        .sheet(isPresented: $showProfileEditor) {
            KaChatProfileEditorSheet()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openToken)) { _ in takeTokenRoute() }
        .sheet(item: $openToken) { token in
            NavigationStack {
                TokenManageView(token: token)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button("Close") { openToken = nil }
                        }
                    }
            }
        }
        .fullScreenCover(isPresented: $showWelcomeGuide) {
            WelcomeGuideView(onFinished: { showWelcomeGuide = false }, isOnboardingRun: true)
        }
        // A payment request link tapped anywhere: Send Kaspa with it filled in.
        .modifier(PaymentRequestSheetPresenter())
        .onAppear {
            // A new or imported account gets the Welcome Guide once. Marked before presenting, so
            // an app killed mid-guide shows it again on the next launch.
            if walletManager.justCreatedNewWallet {
                walletManager.justCreatedNewWallet = false
                WelcomeGuideView.markOnboardingRunPending()
                showWelcomeGuide = true
            } else if WelcomeGuideView.isOnboardingRunPending {
                showWelcomeGuide = true
            }
            // The dock lifts the hold create/import put on syncing (KaPost's sync is light, so the
            // guide doesn't wait for it). Then the address's node subscription (balance, coins for
            // sending) starts - ChatService's 1:1 chat sync stays off in KaPosts.
            let chatService = ChatService.shared
            if chatService.onboardingSyncHeld {
                chatService.releaseSyncForOnboarding()
            } else {
                chatService.startPolling()
            }
            // The rooms' stored messages, so the Public Chats badge counts before the list opens.
            PublicChatService.shared.primeChannelSummaries()
            // the app icon follows KaPost's notifications and the rooms, never the hidden 1:1 chats
            AppIconBadge.shared.start()
            // kUSDT is checked while the app is open, so one that arrives is announced
            TokenWallet.shared.startPolling()
            takeTokenRoute()
            if KaPostsDeepLink.pendingOpenNotifications {
                KaPostsDeepLink.pendingOpenNotifications = false
                dock.selectedTab = .notifications
            } else if KaPostsDeepLink.pendingPostTxId != nil || KaPostsDeepLink.pendingComposeText != nil {
                dock.selectedTab = .feed
            } else if PublicChatService.shared.pendingPublicChatNavigation != nil {
                dock.selectedTab = .publicChats
            }
        }
    }

    /// Opens the token a notification named, once the tabs are on screen (a sheet asked for
    /// before then came up blank). Full-screen covers close first, as for a room push.
    private func takeTokenRoute() {
        guard TokenRoute.pending != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard let id = TokenRoute.pending else { return }
            TokenRoute.pending = nil
            NotificationCenter.default.post(name: .kaPostsCloseCovers, object: nil)
            openToken = TokenWallet.shared.tokens.first(where: { $0.id == id }) ?? .kusdt
        }
    }
}
