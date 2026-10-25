import SwiftUI

/// The KaPosts dock: Feed, Public Chats, Profile, Wallet, Settings - always these five, in this
/// order. KaPosts is one address doing one thing, so there is no Customize Dock.
struct KaPostsTabView: View {
    enum Tab: Int {
        case feed, publicChats, profile, wallet, settings
    }

    @State private var selectedTab: Tab = .feed
    /// The address profile editor (name, picture, banner, bio) - the profile KaPosts shows.
    @State private var showProfileEditor = false
    @ObservedObject private var kaPostsNotifCenter = KaPostsNotificationCenter.shared
    @ObservedObject private var walletManager = WalletManager.shared

    var body: some View {
        TabView(selection: $selectedTab) {
            KaPostsPageView()
                .tabItem { Label("Feed", systemImage: "square.text.square") }
                .badge(kaPostsNotifCenter.unseenCount > 0 ? Text(verbatim: kaPostsNotifCenter.badgeText) : nil)
                .tag(Tab.feed)

            NavigationStack {
                PublicChatListView()
            }
            .tabItem { Label("Public Chats", systemImage: "bubble.left.and.text.bubble.right") }
            .tag(Tab.publicChats)

            KaPostsView(rootMode: .myProfile)
                .tabItem { Label("Profile", systemImage: "person.crop.circle") }
                .tag(Tab.profile)

            NavigationStack {
                if let address = walletManager.currentWallet?.publicAddress {
                    ChattingAddressManageView(address: address, title: "Wallet")
                }
            }
            .tabItem { Label("Wallet", systemImage: "wallet.bifold") }
            .tag(Tab.wallet)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .tint(.accentColor)
        .onReceive(NotificationCenter.default.publisher(for: .openKaPost)) { _ in
            selectedTab = .feed
        }
        .onReceive(NotificationCenter.default.publisher(for: .openPublicChat)) { _ in
            selectedTab = .publicChats
        }
        // Posted by the profile's Edit Profile button.
        .onReceive(NotificationCenter.default.publisher(for: .openKNSProfileEditor)) { _ in
            showProfileEditor = true
        }
        .sheet(isPresented: $showProfileEditor) {
            KaChatProfileEditorSheet()
        }
        .onAppear {
            if KaPostsDeepLink.pendingPostTxId != nil || KaPostsDeepLink.pendingOpenNotifications {
                selectedTab = .feed
            } else if PublicChatService.shared.pendingPublicChatNavigation != nil {
                selectedTab = .publicChats
            }
        }
    }
}
