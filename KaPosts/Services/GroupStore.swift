import Foundation

/// Plain snapshot of a room reaction row (`CDPublicChatReaction`), safe to pass across
/// contexts/actors. It began as KaChat's group store's reaction snapshot; KaPost has no groups,
/// so only the shape is left (`PublicChatStore.fetchReactions`, `PublicChatService.reactionsByChannel`).
struct PublicChatReactionSnapshot: Identifiable, Equatable {
    var id: String { "\(targetTxId)-\(reactorAddress)" }
    let targetTxId: String
    let reactorAddress: String
    let emoji: String
    /// Send state of the local user's own reaction (`.sent` for everyone else's / delivered).
    /// `.failed` drives the error icon on the pill and the Retry under the message.
    var deliveryStatus: ChatMessage.DeliveryStatus = .sent
    /// When `.failed`, whether the failed change was an "add" or "remove" — so Retry re-attempts
    /// the correct action.
    var failedAction: String? = nil
    /// Reaction creation time (ms since epoch). Used to drop the green "sent" checkmark after a
    /// short window (the checkmark is a recent-confirmation, not a permanent badge).
    var blockTime: Int64 = 0
}

/// The old name, still used by the room views (`GroupStore.ReactionSnapshot`). KaChat's group
/// store itself is gone from KaPost: nothing opened it.
enum GroupStore {
    typealias ReactionSnapshot = PublicChatReactionSnapshot
}
