import Foundation
import Combine

/// A post saved for later: the whole composer state, not just its text.
///
/// Stored per wallet and never sent anywhere - a draft is a private note to yourself until you
/// deliberately post it, so it has no on-chain footprint at all.
struct KaPostSavedDraft: Codable, Identifiable, Equatable {
    let id: UUID
    /// The in-progress text, i.e. what was in the editor when it was saved.
    var text: String
    /// Earlier segments of a thread, in order. Empty for a single post.
    var threadSegments: [String]
    /// The post being quoted, if the draft was written as a quote. Only the remote id is kept -
    /// the quoted post itself is re-fetched on open, so a draft never carries a stale copy.
    var quotedRemoteId: String?
    /// The post being REPLIED to, if the draft was written as a reply. Kept separate from
    /// `quotedRemoteId` rather than as one id plus a kind, so drafts saved before replies had a
    /// composer of their own still decode as the quotes they were - and a missing key decodes to
    /// nil, so nothing stored earlier is disturbed.
    var replyRemoteId: String?
    var savedAt: Date

    /// One line for the drafts list: the first segment that has anything in it.
    var preview: String {
        let first = ([text] + threadSegments).first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return (first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Everything this draft would post, for the "3 posts" count on its row.
    var segmentCount: Int {
        ([text] + threadSegments).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
    }
}

/// Local, per-wallet storage for saved post drafts.
///
/// Deliberately local-only and unsynced. A draft is unfinished writing; putting it on chain or in
/// a backup would publish something the author never chose to publish.
@MainActor
final class KaPostsDraftStore: ObservableObject {
    static let shared = KaPostsDraftStore()

    @Published private(set) var drafts: [KaPostSavedDraft] = []

    private let baseKey = "kachat_kaposts_drafts"
    /// The account `drafts` was read for. Every write goes under THIS account's key, and a write
    /// first reloads if the open account has changed, so one account's drafts never land under
    /// another's key.
    private var loadedWallet: String?
    private var walletCancellable: AnyCancellable?

    private init() {
        reload(for: Self.currentAddress)
        // Log Out, sign-in, import and switches all change `currentWallet`. `@Published` fires
        // before the value is stored, so the new address comes from the sink.
        walletCancellable = WalletManager.shared.$currentWallet
            .map { $0?.publicAddress ?? "" }
            .removeDuplicates()
            .sink { [weak self] address in
                guard let self else { return }
                let next: String? = address.isEmpty ? nil : address
                guard next != self.loadedWallet else { return }
                self.reload(for: next)
            }
    }

    private static var currentAddress: String? {
        guard let address = WalletManager.shared.currentWallet?.publicAddress, !address.isEmpty else { return nil }
        return address
    }

    private func key(for address: String) -> String {
        "\(baseKey)_\(address.replacingOccurrences(of: ":", with: "_"))"
    }

    /// A deleted wallet's drafts go with it.
    func deleteDrafts(forWalletAddress address: String) {
        UserDefaults.standard.removeObject(forKey: key(for: address))
        if loadedWallet == address {
            drafts = []
            loadedWallet = nil
        }
    }

    /// Re-reads for whichever wallet is active now. Cheap and idempotent, so callers can just
    /// call it when a drafts surface appears rather than tracking wallet changes themselves.
    func reloadForCurrentWallet() {
        let address = Self.currentAddress
        if address != nil, loadedWallet == address, !drafts.isEmpty { return }
        reload(for: address)
    }

    private func reload(for address: String?) {
        loadedWallet = address
        guard let address,
              let data = UserDefaults.standard.data(forKey: key(for: address)),
              let decoded = try? JSONDecoder().decode([KaPostSavedDraft].self, from: data) else {
            drafts = []
            return
        }
        drafts = decoded.sorted { $0.savedAt > $1.savedAt }
    }

    /// Makes sure `drafts` belongs to the open account before it is changed and written.
    /// Returns false when no account is open (nothing may be written then).
    private func syncToCurrentWallet() -> Bool {
        let address = Self.currentAddress
        if address != loadedWallet { reload(for: address) }
        return address != nil
    }

    /// Saves a new draft, or updates `id` when re-saving one that was opened for editing.
    @discardableResult
    func save(
        id: UUID? = nil,
        text: String,
        threadSegments: [String],
        quotedRemoteId: String?,
        replyRemoteId: String? = nil
    ) -> KaPostSavedDraft? {
        let hasContent = !([text] + threadSegments)
            .allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard hasContent, syncToCurrentWallet() else { return nil }

        let draft = KaPostSavedDraft(
            id: id ?? UUID(),
            text: text,
            threadSegments: threadSegments,
            quotedRemoteId: quotedRemoteId,
            replyRemoteId: replyRemoteId,
            savedAt: Date()
        )
        drafts.removeAll { $0.id == draft.id }
        drafts.insert(draft, at: 0)
        persist()
        return draft
    }

    func delete(_ id: UUID) {
        guard syncToCurrentWallet(), drafts.contains(where: { $0.id == id }) else { return }
        drafts.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        // Written under the account the list was read for, never whatever is current now.
        guard let address = loadedWallet, address == Self.currentAddress,
              let data = try? JSONEncoder().encode(drafts) else { return }
        UserDefaults.standard.set(data, forKey: key(for: address))
    }
}
