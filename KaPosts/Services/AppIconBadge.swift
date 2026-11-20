import Foundation
import Combine
import UIKit
import UserNotifications

/// The app icon's badge: KaPost's unseen notifications (`KaPostsNotificationCenter`) plus the
/// rooms' unread messages (`PublicChatUnreadBadge`), the same two numbers the dock shows.
///
/// 1:1 conversations don't count: their screens are switched off in KaPost
/// (`ChatService.oneToOneChatsEnabled`), so an unread one (a plain payment filed in a chat) could
/// never be cleared here. This is the only place the app sets the badge; a push may set it while
/// the app is closed, and the next change or return to the front puts KaPost's own count back.
@MainActor
final class AppIconBadge {
    static let shared = AppIconBadge()

    private var cancellables = Set<AnyCancellable>()
    private var lastApplied: Int?

    private init() {}

    /// Starts following both counts. Called once the dock is up (`KaPostsTabView`); calling it
    /// again does nothing.
    func start() {
        guard cancellables.isEmpty else { return }
        Publishers.CombineLatest(
            KaPostsNotificationCenter.shared.$unseenCount,
            PublicChatUnreadBadge.shared.$count
        )
        .map { max(0, $0) + max(0, $1) }
        .removeDuplicates()
        .receive(on: RunLoop.main)
        .sink { [weak self] total in self?.apply(total) }
        .store(in: &cancellables)

        // a push may have changed the badge while KaPost was away
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.lastApplied = nil
                self?.apply(KaPostsNotificationCenter.shared.unseenCount + PublicChatUnreadBadge.shared.count)
            }
            .store(in: &cancellables)
    }

    private func apply(_ total: Int) {
        let total = max(0, total)
        guard total != lastApplied else { return }
        lastApplied = total
        SharedDataManager.setUnreadCount(total)
        if #available(iOS 16.0, *) {
            UNUserNotificationCenter.current().setBadgeCount(total)
        } else {
            UIApplication.shared.applicationIconBadgeNumber = total
        }
    }
}
