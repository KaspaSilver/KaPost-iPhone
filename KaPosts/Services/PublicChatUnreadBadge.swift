import Foundation
import Combine

/// The Public Chats dock badge: the unread count across the rooms (`PublicChatService.totalUnreadCount`),
/// worked out again whenever the rooms change and published only when the number does - so the
/// dock (both the real one and `KaPostsDockCopy`) doesn't redraw for every message that arrives.
@MainActor
final class PublicChatUnreadBadge: ObservableObject {
    static let shared = PublicChatUnreadBadge()

    @Published private(set) var count = 0

    var badgeText: String { count > 99 ? "99+" : "\(count)" }

    private var cancellable: AnyCancellable?

    private init() {
        // objectWillChange fires before the change lands: the debounce counts after it.
        cancellable = PublicChatService.shared.objectWillChange
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.recount() }
        recount()
    }

    private func recount() {
        let total = PublicChatService.shared.totalUnreadCount
        if total != count { count = total }
    }
}
