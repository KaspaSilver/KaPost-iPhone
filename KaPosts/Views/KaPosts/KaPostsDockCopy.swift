import SwiftUI
import Combine

/// Which dock tab is selected, shared by the real dock (`KaPostsTabView`) and the copy drawn
/// over full-screen KaPosts screens (`KaPostsDockCopy`).
final class KaPostsDockRouter: ObservableObject {
    static let shared = KaPostsDockRouter()
    @Published var selectedTab: KaPostsTabView.Tab = .feed
}

extension Notification.Name {
    /// A tap on the dock copy: every KaPosts full-screen screen closes at once, without the
    /// slide, so the tab underneath is what shows.
    static let kaPostsCloseCovers = Notification.Name("kaPostsCloseCovers")
}

/// The dock, drawn again on top of KaPosts' full-screen screens (threads, profiles, the menu's
/// screens, Post Activity). Those are full-screen covers, which iOS draws over the real dock;
/// this copy keeps the dock in reach on every screen.
///
/// It is not part of the screen: the slide driver (`KaPostsSlideDriverView`) puts it in the
/// cover's presentation container, above the sliding screen, so it stays still while screens
/// slide in and out under it, the way the real dock does. Tapping a tab closes every cover and
/// selects that tab (the one you are on just closes them, like tapping the current tab).
/// Hidden while the keyboard is up.
struct KaPostsDockCopy: View {
    @ObservedObject private var router = KaPostsDockRouter.shared
    @ObservedObject private var notifCenter = KaPostsNotificationCenter.shared
    @ObservedObject private var publicChatBadge = PublicChatUnreadBadge.shared

    /// The capsule's height, matching the system dock.
    static let height: CGFloat = 62

    var body: some View {
        HStack(spacing: 0) {
            ForEach(KaPostsTabView.Tab.allCases) { tab in
                item(tab)
            }
        }
        .padding(4)
        .frame(height: Self.height)
        .background(dockBackground)
    }

    @ViewBuilder
    private var dockBackground: some View {
        if #available(iOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: Capsule())
        } else {
            Capsule()
                .fill(.regularMaterial)
                .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 0.6))
                .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 4)
        }
    }

    private func item(_ tab: KaPostsTabView.Tab) -> some View {
        let selected = router.selectedTab == tab
        let badgeText = badgeText(for: tab)
        return Button {
            Haptics.selection()
            NotificationCenter.default.post(name: .kaPostsCloseCovers, object: nil)
            router.selectedTab = tab
        } label: {
            VStack(spacing: 3) {
                Image(systemName: tab.icon)
                    .symbolVariant(.fill)
                    .font(.system(size: 20, weight: .medium))
                    .frame(height: 24)
                    .overlay(alignment: .topTrailing) {
                        if let badgeText {
                            Text(badgeText)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 5)
                                .frame(minWidth: 18, minHeight: 18)
                                .background(Capsule().fill(Color.red))
                                .offset(x: 10, y: -6)
                        }
                    }
                Text(tab.title)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundColor(selected ? .accentColor : .primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                if selected {
                    Capsule().fill(Color.primary.opacity(0.1))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(tab.title))
        .accessibilityValue(accessibilityBadge(for: tab))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// Notifications: unseen activity. Public Chats: unread messages across the rooms.
    private func badgeText(for tab: KaPostsTabView.Tab) -> String? {
        switch tab {
        case .notifications: return notifCenter.unseenCount > 0 ? notifCenter.badgeText : nil
        case .publicChats: return publicChatBadge.count > 0 ? publicChatBadge.badgeText : nil
        default: return nil
        }
    }

    private func accessibilityBadge(for tab: KaPostsTabView.Tab) -> Text {
        switch tab {
        case .notifications where notifCenter.unseenCount > 0: return Text("\(notifCenter.unseenCount) unseen")
        case .publicChats where publicChatBadge.count > 0: return Text("\(publicChatBadge.count) unread")
        default: return Text("")
        }
    }
}
