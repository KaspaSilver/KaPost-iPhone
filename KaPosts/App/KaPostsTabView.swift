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
            dock.selectedTab = .publicChats
        }
        // Posted by the profile's Edit Profile button.
        .onReceive(NotificationCenter.default.publisher(for: .openKNSProfileEditor)) { _ in
            showProfileEditor = true
        }
        .sheet(isPresented: $showProfileEditor) {
            KaChatProfileEditorSheet()
        }
        // A payment request link tapped anywhere: Send Kaspa with it filled in.
        .modifier(PaymentRequestSheetPresenter())
        .onAppear {
            // KaChat's welcome guide used to lift the hold create/import put on syncing; KaPosts
            // has no guide, so the dock lifts it. Then the address's node subscription (balance,
            // coins for sending) starts - ChatService's 1:1 chat sync stays off in KaPosts.
            let chatService = ChatService.shared
            if chatService.onboardingSyncHeld {
                chatService.releaseSyncForOnboarding()
            } else {
                chatService.startPolling()
            }
            // The rooms' stored messages, so the Public Chats badge counts before the list opens.
            PublicChatService.shared.primeChannelSummaries()
            if KaPostsDeepLink.pendingOpenNotifications {
                KaPostsDeepLink.pendingOpenNotifications = false
                dock.selectedTab = .notifications
            } else if KaPostsDeepLink.pendingPostTxId != nil {
                dock.selectedTab = .feed
            } else if PublicChatService.shared.pendingPublicChatNavigation != nil {
                dock.selectedTab = .publicChats
            }
        }
    }
}
