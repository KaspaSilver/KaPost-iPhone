import Foundation

/// The words of a post that isn't on chain yet: held behind the 5-second Undo, going out, or
/// failed. Those cards live only in memory, so this keeps their text until the post lands.
/// While the app runs the card is the way back (Undo, Retry), so nothing shows anywhere; what a
/// kill leaves behind comes back as an ordinary draft on the next launch (`recover`).
@MainActor
final class KaPostsHeldPostStore {
    static let shared = KaPostsHeldPostStore()

    private struct Entry: Codable {
        let id: UUID
        var text: String
        var threadSegments: [String]
        var quotedRemoteId: String?
        var replyRemoteId: String?
    }

    /// The posts this run is looking after, with the account each was written as: its entry
    /// stays under that account even after a switch.
    private var active: [UUID: String] = [:]

    private init() {}

    private static func key(_ address: String) -> String {
        "kachat_kaposts_held_" + address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var currentKey: String? {
        guard let address = WalletManager.shared.currentWallet?.publicAddress, !address.isEmpty else { return nil }
        return Self.key(address)
    }

    private func load(_ key: String) -> [Entry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return entries
    }

    private func store(_ entries: [Entry], _ key: String) {
        if entries.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Starts keeping a post's text, or replaces what's kept (a thread as it goes out).
    func hold(_ id: UUID, text: String, threadSegments: [String] = [], quotedRemoteId: String? = nil, replyRemoteId: String? = nil) {
        guard let key = active[id] ?? currentKey else { return }
        active[id] = key
        var entries = load(key)
        entries.removeAll { $0.id == id }
        entries.append(Entry(id: id, text: text, threadSegments: threadSegments, quotedRemoteId: quotedRemoteId, replyRemoteId: replyRemoteId))
        store(entries, key)
    }

    /// A thread's unposted segments, held the way the composer holds them: the last one is the
    /// text, the others are stacked above it.
    func holdThread(_ id: UUID, segments: [String], replyRemoteId: String? = nil) {
        guard let last = segments.last else { return }
        hold(id, text: last, threadSegments: Array(segments.dropLast()), replyRemoteId: replyRemoteId)
    }

    /// The post landed, or was taken back: nothing left to keep.
    func release(_ id: UUID) {
        guard let key = active.removeValue(forKey: id) else { return }
        store(load(key).filter { $0.id != id }, key)
    }

    /// Hands one kept post to the Drafts screen now. Stays kept if its account isn't the open one.
    func saveAsDraft(_ id: UUID) {
        guard let key = active[id], key == currentKey, let entry = load(key).first(where: { $0.id == id }) else { return }
        saveDraft(entry)
        release(id)
    }

    /// What an earlier run left behind becomes drafts. Posts this run still has on screen stay.
    func recover() {
        guard let key = currentKey else { return }
        let entries = load(key)
        let leftovers = entries.filter { active[$0.id] == nil }
        guard !leftovers.isEmpty else { return }
        KaPostsDraftStore.shared.reloadForCurrentWallet()
        for entry in leftovers { saveDraft(entry) }
        store(entries.filter { active[$0.id] != nil }, key)
    }

    private func saveDraft(_ entry: Entry) {
        KaPostsDraftStore.shared.save(
            id: entry.id, text: entry.text, threadSegments: entry.threadSegments,
            quotedRemoteId: entry.quotedRemoteId, replyRemoteId: entry.replyRemoteId
        )
    }

    /// Delete Account: one wallet's kept posts, from this device.
    static func removeAllData(forWalletAddress walletAddress: String) {
        UserDefaults.standard.removeObject(forKey: key(walletAddress))
    }
}
