import CryptoKit
import Foundation
import UIKit

// KaPost with the indexer down (owner's call, 2026-11-08, across the iOS apps). The indexer is
// what lists posts; the posts themselves are on chain. So while it doesn't answer: every read
// shows the page it last got (`KaPostsPageCache`), a person's posts come from Kaspa REST, new
// posts come off the node's block stream (`KaPostsLiveChainFeed`), and it all goes back to the
// indexer by itself when it answers again (`KaPostsIndexerHealth`). Writes never needed it.

extension Notification.Name {
    /// `KaPostsIndexerHealth.isDown` changed.
    static let kaPostsIndexerAvailabilityChanged = Notification.Name("kaPostsIndexerAvailabilityChanged")
}

/// Whether the KaPost indexer is answering. Every read and write reports here. One failed request
/// is a phone's bad moment, not an outage: it takes `failuresToGoDown` in a row inside
/// `failureWindow`, and any answer resets the count (the same rule as KaChat). Until then the
/// indexer stays the only source. While it's down one small request a minute looks for its return.
@MainActor
final class KaPostsIndexerHealth: ObservableObject {
    static let shared = KaPostsIndexerHealth()

    @Published private(set) var isDown = false
    private var probeTask: Task<Void, Never>?
    private var failuresInARow = 0
    private var lastFailureAt = Date.distantPast
    private static let probeIntervalNanos: UInt64 = 60 * 1_000_000_000
    private static let failuresToGoDown = 3
    /// Failures further apart than this aren't a run.
    private static let failureWindow: TimeInterval = 120
    /// A network handoff fails every request in flight at once: that's one failure, not three.
    private static let minFailureSpacing: TimeInterval = 5

    private init() {}

    /// A request that failed: counts against the indexer only if it says so (`meansDown`).
    func note(_ error: Error) {
        if Self.meansDown(error) { noteFailure() }
    }

    func noteFailure() {
        let now = Date()
        guard now.timeIntervalSince(lastFailureAt) >= Self.minFailureSpacing else { return }
        if now.timeIntervalSince(lastFailureAt) > Self.failureWindow { failuresInARow = 0 }
        lastFailureAt = now
        failuresInARow += 1
        if failuresInARow >= Self.failuresToGoDown { markDown() }
    }

    /// A body that wouldn't decode: the indexer did answer, so no outage, and no failure run.
    func noteUnreadableAnswer() {
        failuresInARow = 0
    }

    /// The indexer gave an answer of its own, even an error about the request.
    func noteAnswered() {
        failuresInARow = 0
        guard isDown else { return }
        isDown = false
        probeTask?.cancel()
        probeTask = nil
        AppLog.log("[KaPosts] The indexer is answering again")
        KaPostsLiveChainFeed.shared.setActive(false)
        NotificationCenter.default.post(name: .kaPostsIndexerAvailabilityChanged, object: nil)
    }

    private func markDown() {
        guard !isDown else { return }
        isDown = true
        AppLog.log("[KaPosts] The indexer isn't answering: saved pages and the chain from here")
        KaPostsLiveChainFeed.shared.setActive(true)
        NotificationCenter.default.post(name: .kaPostsIndexerAvailabilityChanged, object: nil)
        probeTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.probeIntervalNanos)
                guard !Task.isCancelled else { return }
                guard UIApplication.shared.applicationState == .active else { continue }
                if await KaPostsAPIClient.shared.probeIndexer() { self?.noteAnswered() }
            }
        }
    }

    /// A phone that's offline says nothing about the indexer, and neither does a cancelled request.
    nonisolated static func meansDown(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .cancelled, .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff: return false
        default: return true
        }
    }

    nonisolated static func meansDown(statusCode: Int) -> Bool {
        statusCode == 429 || statusCode >= 500
    }

    /// The phone has no connection: nothing could answer, so a saved page takes nothing away from
    /// the indexer.
    nonisolated static func meansOffline(_ error: Error) -> Bool {
        guard let code = (error as? URLError)?.code else { return false }
        return code == .notConnectedToInternet || code == .dataNotAllowed || code == .internationalRoamingOff
    }
}

/// The last first page of each read, on disk, for when the indexer can't answer. Keyed by the
/// whole request, so each account has its own (its key is in the query). Only reads that show
/// content: a saved list of scheduled posts could offer to cancel one that already went out.
enum KaPostsPageCache {
    private static let cachedPaths: Set<String> = [
        "get-posts-watching", "get-contents-following", "get-posts", "get-replies",
        "get-post", "get-thread", "get-notifications", "get-user-details",
    ]
    private static let limit = 200
    private static let queue = DispatchQueue(label: "com.kachat.kaposts.pagecache", qos: .utility)

    private static var directory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("KaPostsPages", isDirectory: true)
    }

    /// Nil for what isn't kept: a later page (its cursor is only good with the indexer) or a
    /// read not in the list.
    static func key(base: URL, path: String, query: [String: String]) -> String? {
        guard cachedPaths.contains(path), query["before"] == nil else { return nil }
        let canonical = base.absoluteString + "|" + path + "|"
            + query.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func save(_ data: Data, key: String) {
        guard let directory else { return }
        queue.async {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: directory.appendingPathComponent(key), options: .atomic)
            prune(directory)
        }
    }

    static func load(key: String) async -> Data? {
        guard let directory else { return nil }
        return await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: try? Data(contentsOf: directory.appendingPathComponent(key))) }
        }
    }

    /// Delete Account: nothing an account read stays behind.
    static func removeAll() {
        guard let directory else { return }
        queue.async { try? FileManager.default.removeItem(at: directory) }
    }

    private static func prune(_ directory: URL) {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys),
              files.count > limit else { return }
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast) }
        for (file, _) in dated.sorted(by: { $0.1 < $1.1 }).prefix(files.count - limit) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

/// Posts read straight from chain data. A payload can name anyone as its author, so one counts
/// only if its signature verifies against the key it names, the same check the indexer makes.
enum KaPostsChainPosts {
    private static let pagesPerPerson = 2
    private static let pageSize = 100

    /// The lowercased x-only part of a 02/03 key. Addresses only give x, and a real post carries
    /// true parity, so keys are compared on this.
    static func xOnly(_ pubkey: String) -> String {
        String(pubkey.suffix(64)).lowercased()
    }

    /// A verified post and the signature that proved it: a signed payload can be put on chain
    /// again by anyone, as a new transaction with a new id, so repeats are found by this.
    struct VerifiedPost {
        let post: KaPostsAPIClient.KPost
        let signature: String
        /// Pubkey and signature: the same for every copy of one signed payload.
        var repeatKey: String { xOnly(post.userPublicKey) + ":" + signature.lowercased() }
    }

    /// A post, reply or quote from a decoded payload, or nil for anything else: another action,
    /// another app's post (no KaChat marker), a repost with no text, or a bad signature.
    static func verifiedPost(payload: String, txId: String, timestampMs: Int64) -> VerifiedPost? {
        guard payload.hasPrefix(KaPostsProtocol.prefix) else { return nil }
        let fields = payload.dropFirst(KaPostsProtocol.prefix.count).components(separatedBy: ":")
        guard fields.count >= 5 else { return nil }
        let action = fields[0], pubkey = fields[1], signature = fields[2]
        let b64: String, signingString: String
        var parent: String?
        var mentionsJSON = "[]"
        switch action {
        case "post":
            b64 = fields[3]
            mentionsJSON = fields[4]
            signingString = KaPostsProtocol.postSigningString(b64Message: b64, mentionsJSON: mentionsJSON)
        case "reply":
            guard fields.count >= 6 else { return nil }
            b64 = fields[4]
            parent = fields[3]
            mentionsJSON = fields[5]
            guard decodedMentions(mentionsJSON) != nil else { return nil }
            signingString = KaPostsProtocol.replySigningString(postId: fields[3], b64Message: b64, mentionsJSON: mentionsJSON)
        case "quote":
            guard fields.count >= 6, fields[5].range(of: "^[0-9a-fA-F]{66}$", options: .regularExpression) != nil else { return nil }
            b64 = fields[4]
            signingString = KaPostsProtocol.quoteSigningString(contentId: fields[3], b64Message: b64, quotedAuthorPubkey: fields[5])
        default:
            return nil
        }
        guard let bytes = Data(base64Encoded: b64), let text = String(data: bytes, encoding: .utf8),
              KaPostsAPIClient.isKaChatContent(text),
              !KaPostsAPIClient.stripMarker(text).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              signatureIsValid(signature, signingString: signingString, pubkey: pubkey) else { return nil }
        let post = KaPostsAPIClient.KPost(
            id: txId, userPublicKey: pubkey, postContent: b64, timestamp: timestampMs,
            repliesCount: nil, quotesCount: nil, upVotesCount: nil, downVotesCount: nil, tipsCount: nil,
            parentPostId: parent, mentionedPubkeys: decodedMentions(mentionsJSON) ?? [], isUpvoted: nil, isDownvoted: nil, blockedUser: nil,
            contentType: action, isQuote: action == "quote", quote: nil, editedAt: nil, poll: nil
        )
        return VerifiedPost(post: post, signature: signature)
    }

    private static func decodedMentions(_ json: String) -> [String]? {
        try? JSONDecoder().decode([String].self, from: Data(json.utf8))
    }

    /// A verified `delete:` or `edit:` record, by the key `pubkey` only: the indexer applies these
    /// the same way, and without them a deleted post comes back for as long as it's down.
    private enum Amendment {
        case delete(postId: String)
        case edit(postId: String, b64: String, mentions: [String], timestampMs: Int64)
    }

    private static func verifiedAmendment(payload: String, timestampMs: Int64, ofPubkey pubkey: String) -> Amendment? {
        guard payload.hasPrefix(KaPostsProtocol.prefix) else { return nil }
        let fields = payload.dropFirst(KaPostsProtocol.prefix.count).components(separatedBy: ":")
        guard fields.count >= 4, xOnly(fields[1]) == xOnly(pubkey) else { return nil }
        switch fields[0] {
        case "delete":
            guard signatureIsValid(fields[2], signingString: KaPostsProtocol.deleteSigningString(postId: fields[3]), pubkey: fields[1]) else { return nil }
            return .delete(postId: fields[3])
        case "edit":
            guard fields.count >= 6, let mentions = decodedMentions(fields[5]),
                  let bytes = Data(base64Encoded: fields[4]), let text = String(data: bytes, encoding: .utf8),
                  KaPostsAPIClient.isKaChatContent(text),
                  !KaPostsAPIClient.stripMarker(text).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  signatureIsValid(fields[2], signingString: KaPostsProtocol.editSigningString(postId: fields[3], b64Message: fields[4], mentionsJSON: fields[5]), pubkey: fields[1]) else { return nil }
            return .edit(postId: fields[3], b64: fields[4], mentions: mentions, timestampMs: timestampMs)
        default:
            return nil
        }
    }

    /// `post` as a later edit left it.
    private static func edited(_ post: KaPostsAPIClient.KPost, b64: String, mentions: [String], atMs: Int64) -> KaPostsAPIClient.KPost {
        KaPostsAPIClient.KPost(
            id: post.id, userPublicKey: post.userPublicKey, postContent: b64, timestamp: post.timestamp,
            repliesCount: post.repliesCount, quotesCount: post.quotesCount, upVotesCount: post.upVotesCount,
            downVotesCount: post.downVotesCount, tipsCount: post.tipsCount,
            parentPostId: post.parentPostId, mentionedPubkeys: mentions, isUpvoted: post.isUpvoted, isDownvoted: post.isDownvoted,
            blockedUser: post.blockedUser, contentType: post.contentType, isQuote: post.isQuote, quote: post.quote, editedAt: atMs, poll: post.poll
        )
    }

    private static func signatureIsValid(_ signature: String, signingString: String, pubkey: String) -> Bool {
        guard pubkey.count == 66, let key = Data(hexString: String(pubkey.dropFirst(2))), key.count == 32,
              let signatureBytes = Data(hexString: signature), signatureBytes.count == 64 else { return false }
        let digest = Blake2b.hash(Data(signingString.utf8), digestLength: 32, key: "PersonalMessageSigningHash")
        return GroupCipher.verify(signatureBytes, message: digest, xOnlyPublicKey: key)
    }

    /// One person's posts and replies from Kaspa REST, newest first (a node keeps no history by
    /// address). Nil when REST didn't answer.
    static func posts(ofPubkey pubkey: String) async -> [KaPostsAPIClient.KPost]? {
        guard let address = await KaPostsAPIClient.kaspaAddress(fromPubkey: pubkey) else { return nil }
        let base = AppSettings.load().kaspaRestAPIURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let root = base.hasSuffix("/") ? String(base.dropLast()) : base
        var found: [VerifiedPost] = []
        var deleted = Set<String>()
        var latestEdits: [String: (b64: String, mentions: [String], timestampMs: Int64)] = [:]
        for page in 0..<pagesPerPerson {
            guard let url = URL(string: "\(root)/addresses/\(address)/full-transactions?limit=\(pageSize)&offset=\(page * pageSize)&resolve_previous_outpoints=no&fields=transaction_id,is_accepted,payload,block_time") else { return nil }
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let list = try? JSONDecoder().decode([RestTransaction].self, from: data) else {
                return page == 0 ? nil : applying(deleted, latestEdits, to: found)
            }
            for tx in list where tx.isAccepted != false {
                guard let hex = tx.payload, let bytes = CryptoUtils.hexToData(hex),
                      let payload = String(data: bytes, encoding: .utf8) else { continue }
                let timestampMs = tx.blockTime ?? 0
                switch verifiedAmendment(payload: payload, timestampMs: timestampMs, ofPubkey: pubkey) {
                case .delete(let postId):
                    deleted.insert(postId)
                case .edit(let postId, let b64, let mentions, let editedAtMs):
                    if editedAtMs >= (latestEdits[postId]?.timestampMs ?? .min) {
                        latestEdits[postId] = (b64: b64, mentions: mentions, timestampMs: editedAtMs)
                    }
                case nil:
                    guard let verified = verifiedPost(payload: payload, txId: tx.transactionId, timestampMs: timestampMs),
                          xOnly(verified.post.userPublicKey) == xOnly(pubkey) else { continue }
                    found.append(verified)
                }
            }
            if list.count < pageSize { break }
        }
        return applying(deleted, latestEdits, to: found)
    }

    /// What's left of a person's posts: the first copy of each signed payload, deleted ones gone,
    /// edits made within the indexer's window in place. Newest first.
    private static func applying(
        _ deleted: Set<String>,
        _ latestEdits: [String: (b64: String, mentions: [String], timestampMs: Int64)],
        to found: [VerifiedPost]
    ) -> [KaPostsAPIClient.KPost] {
        var seen = Set<String>()
        let editWindowMs = Int64(KaPostsAPIClient.editWindow * 1000)
        return found.sorted { $0.post.timestamp < $1.post.timestamp }
            .filter { seen.insert($0.repeatKey).inserted && !deleted.contains($0.post.id) }
            .map { verified -> KaPostsAPIClient.KPost in
                let post = verified.post
                guard let edit = latestEdits[post.id], edit.timestampMs >= post.timestamp,
                      edit.timestampMs - post.timestamp <= editWindowMs else { return post }
                return edited(post, b64: edit.b64, mentions: edit.mentions, atMs: edit.timestampMs)
            }
            .sorted { $0.timestamp > $1.timestamp }
    }

    private struct RestTransaction: Decodable {
        let transactionId: String
        let isAccepted: Bool?
        let payload: String?
        let blockTime: Int64?

        enum CodingKeys: String, CodingKey {
            case transactionId = "transaction_id"
            case isAccepted = "is_accepted"
            case payload
            case blockTime = "block_time"
        }
    }
}

/// New posts off the node's block stream while the indexer is down: what the feed can still get
/// live. Only while it's down, since streaming every block costs data the indexer otherwise saves.
@MainActor
final class KaPostsLiveChainFeed: ObservableObject {
    static let shared = KaPostsLiveChainFeed()

    /// Newest first.
    @Published private(set) var posts: [KaPostsAPIClient.KPost] = []
    private var handlerId: UUID?
    private var active = false
    /// Every copy of a signed payload after the first is a replay (`VerifiedPost.repeatKey`).
    private var seenPayloads = Set<String>()
    private static let keep = 300
    private static let client = "kaposts-chain-feed"
    private nonisolated static let scanQueue = DispatchQueue(label: "com.kachat.kaposts.chainfeed", qos: .utility)
    private nonisolated static let prefixes: [String] = ["post:", "reply:", "quote:"].map { action in
        (KaPostsProtocol.prefix + action).utf8.map { String(format: "%02x", $0) }.joined()
    }

    private init() {}

    func setActive(_ isActive: Bool) {
        guard isActive != active else { return }
        active = isActive
        if isActive {
            if handlerId == nil {
                handlerId = NodePoolService.shared.addBlockHandler { [weak self] block in
                    Self.scanQueue.async {
                        let found = Self.extract(block)
                        guard !found.isEmpty else { return }
                        Task { @MainActor in self?.add(found) }
                    }
                }
            }
            Task { await NodePoolService.shared.subscribeBlockAdded(client: Self.client) }
        } else {
            // The indexer has these now. The handler stays, as for rooms: `add` ignores it.
            posts = []
            seenPayloads = []
            Task { await NodePoolService.shared.unsubscribeBlockAdded(client: Self.client) }
        }
    }

    private nonisolated static func extract(_ block: ScannedBlock) -> [KaPostsChainPosts.VerifiedPost] {
        block.transactions.compactMap { tx in
            guard prefixes.contains(where: tx.payloadHex.hasPrefix),
                  let bytes = CryptoUtils.hexToData(tx.payloadHex),
                  let payload = String(data: bytes, encoding: .utf8) else { return nil }
            return KaPostsChainPosts.verifiedPost(payload: payload, txId: tx.txId, timestampMs: tx.blockTime)
        }
    }

    private func add(_ found: [KaPostsChainPosts.VerifiedPost]) {
        guard active else { return }
        let known = Set(posts.map(\.id))
        let fresh = found.filter { !known.contains($0.post.id) && seenPayloads.insert($0.repeatKey).inserted }.map(\.post)
        guard !fresh.isEmpty else { return }
        posts = Array((fresh + posts).sorted { $0.timestamp > $1.timestamp }.prefix(Self.keep))
    }
}
