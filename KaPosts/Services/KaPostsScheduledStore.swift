import Foundation
import UIKit
import UserNotifications

/// A post scheduled for later (KAPOSTS_INDEXER.md §5.10): built and signed when the author
/// chose the time, submitted by the indexer at that time - or by this phone, if the indexer
/// could not be reached, the next time the app runs after it.
struct KaPostScheduledEntry: Codable, Identifiable, Equatable {
    enum Status: String, Codable { case scheduled, submitted, failed, cancelled }

    /// The transaction id the post will have - fixed the moment it was signed.
    let id: String
    var text: String
    var notBefore: Date
    var createdAt: Date
    /// "txid:index" of every coin the transaction spends - kept out of every other spend
    /// until the post is on chain, or the transaction would be invalid when its time comes.
    var spentOutpoints: [String]
    /// The signed transaction, for the local fallback submission.
    var transaction: TransactionSnapshot
    /// Whether the indexer accepted it for submission; false = this phone must submit it.
    var onServer: Bool
    var status: Status
    var error: String?
    var submittedAt: Date?

    /// `KaspaRpcTransaction` is not Codable; this is the same bytes, hex for the data fields.
    struct TransactionSnapshot: Codable, Equatable {
        struct Input: Codable, Equatable { let txId: String; let index: UInt32; let signatureScript: String; let sequence: UInt64; let sigOpCount: UInt8 }
        struct Output: Codable, Equatable { let value: UInt64; let scriptVersion: UInt16; let script: String }
        let version: UInt16
        let inputs: [Input]
        let outputs: [Output]
        let lockTime: UInt64
        let subnetworkId: String
        let gas: UInt64
        let payload: String

        init(_ tx: KaspaRpcTransaction) {
            version = tx.version
            inputs = tx.inputs.map { Input(txId: $0.previousOutpoint.transactionId, index: $0.previousOutpoint.index, signatureScript: $0.signatureScript.hexString, sequence: $0.sequence, sigOpCount: $0.sigOpCount) }
            outputs = tx.outputs.map { Output(value: $0.value, scriptVersion: $0.scriptPublicKey.version, script: $0.scriptPublicKey.script.hexString) }
            lockTime = tx.lockTime
            subnetworkId = tx.subnetworkId.hexString
            gas = tx.gas
            payload = tx.payload.hexString
        }

        var transaction: KaspaRpcTransaction {
            KaspaRpcTransaction(
                version: version,
                inputs: inputs.map { KaspaRpcTransactionInput(previousOutpoint: UTXO.Outpoint(transactionId: $0.txId, index: $0.index), signatureScript: Data(hexString: $0.signatureScript) ?? Data(), sequence: $0.sequence, sigOpCount: $0.sigOpCount) },
                outputs: outputs.map { KaspaRpcTransactionOutput(value: $0.value, scriptPublicKey: KaspaScriptPublicKey(version: $0.scriptVersion, script: Data(hexString: $0.script) ?? Data())) },
                lockTime: lockTime,
                subnetworkId: Data(hexString: subnetworkId) ?? Data(),
                gas: gas,
                payload: Data(hexString: payload) ?? Data()
            )
        }
    }
}

/// Local, per-wallet record of scheduled posts, and the keeper of the coins they will spend.
///
/// Every transaction builder in the app asks `filterReserved` before choosing inputs (the chat
/// builders, KaPosts, and `.kachat` through `KachatNamesService.fundingUtxos`), so a coin a
/// scheduled post depends on is never spent underneath it. The reservation lives as long as the
/// entry is `scheduled`; it's loaded for each wallet as the wallet loads
/// (`ContactsManager.setActiveWalletAddress`).
@MainActor
final class KaPostsScheduledStore: ObservableObject {
    static let shared = KaPostsScheduledStore()

    @Published private(set) var entries: [KaPostScheduledEntry] = []

    private let baseKey = "kachat_kaposts_scheduled"
    private var loadedWallet: String?
    /// Posts being handed to the indexer, submitted or cancelled right now. Whichever started
    /// first decides, so a cancel can't race a submit and a second pass can't submit again.
    private var inFlight: Set<String> = []
    /// How long past its time a post is left to the indexer (it ticks once a minute, §5.10)
    /// before this phone sends it.
    private static let indexerGrace: TimeInterval = 150
    /// The reserved outpoints, readable from any thread (the transaction builders are not
    /// on the main actor).
    nonisolated private static let reservedLock = NSLock()
    nonisolated(unsafe) private static var reservedSnapshot: Set<String> = []

    private init() {
        reloadForCurrentWallet()
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.sendDueLocally() }
        }
    }

    private var scopedKey: String? {
        guard let address = WalletManager.shared.currentWallet?.publicAddress, !address.isEmpty else { return nil }
        return "\(baseKey)_\(address.replacingOccurrences(of: ":", with: "_"))"
    }

    func reloadForCurrentWallet() {
        let address = WalletManager.shared.currentWallet?.publicAddress
        guard let key = scopedKey else {
            entries = []
            loadedWallet = nil
            publishReserved()
            return
        }
        if loadedWallet == address, !entries.isEmpty { return }
        loadedWallet = address
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([KaPostScheduledEntry].self, from: data) {
            entries = decoded.sorted { $0.notBefore < $1.notBefore }
        } else {
            entries = []
        }
        publishReserved()
    }

    private func persist() {
        guard let key = scopedKey else { return }
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: key)
        }
        publishReserved()
    }

    private func publishReserved() {
        let reserved = Set(entries.filter { $0.status == .scheduled }.flatMap(\.spentOutpoints))
        Self.reservedLock.lock()
        Self.reservedSnapshot = reserved
        Self.reservedLock.unlock()
    }

    // MARK: - Reservations

    /// The coins no other transaction may spend right now.
    nonisolated static func filterReserved(_ utxos: [UTXO]) -> [UTXO] {
        reservedLock.lock()
        let reserved = reservedSnapshot
        reservedLock.unlock()
        guard !reserved.isEmpty else { return utxos }
        return utxos.filter { !reserved.contains("\($0.outpoint.transactionId):\($0.outpoint.index)") }
    }

    func excludingReserved(_ utxos: [UTXO]) -> [UTXO] { Self.filterReserved(utxos) }

    // MARK: - Scheduling

    /// Records a signed post for `notBefore`, hands it to the indexer, and - when the indexer
    /// cannot be reached - keeps it for this phone to submit later, with a reminder.
    func add(_ scheduled: KaPostsAPIClient.ScheduledTransaction, text: String, notBefore: Date) async -> KaPostScheduledEntry {
        var entry = KaPostScheduledEntry(
            id: scheduled.txId, text: text, notBefore: notBefore, createdAt: Date(),
            spentOutpoints: scheduled.spentOutpoints, transaction: .init(scheduled.transaction),
            onServer: false, status: .scheduled, error: nil, submittedAt: nil
        )
        entries.removeAll { $0.id == entry.id }
        entries.append(entry)
        entries.sort { $0.notBefore < $1.notBefore }
        persist()
        inFlight.insert(entry.id)
        defer { inFlight.remove(entry.id) }
        do {
            try await KaPostsAPIClient.shared.scheduleOnServer(scheduled, notBefore: notBefore)
            entry.onServer = true
            update(entry)
        } catch {
            AppLog.log("[KaPosts] Scheduling on the indexer failed, keeping it local: %@", error.localizedDescription)
            scheduleReminder(for: entry)
        }
        return entry
    }

    /// Only for an entry still here: one that left while this was away stays gone.
    private func update(_ entry: KaPostScheduledEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index] = entry
        entries.sort { $0.notBefore < $1.notBefore }
        persist()
    }

    /// Cancels a post that has not gone out: told to the indexer if it holds it, then dropped
    /// here and its coins released. Returns what to tell the person when it couldn't be, with
    /// the post still scheduled: an indexer that didn't answer will still send it.
    func cancel(_ entry: KaPostScheduledEntry) async -> String? {
        guard !inFlight.contains(entry.id) else {
            return AppLocalization.string("This post is on its way right now, so it can't be cancelled.")
        }
        inFlight.insert(entry.id)
        defer { inFlight.remove(entry.id) }
        let current = entries.first { $0.id == entry.id } ?? entry
        if current.onServer, current.status == .scheduled {
            do {
                try await KaPostsAPIClient.shared.cancelScheduledOnServer(txId: entry.id)
            } catch {
                AppLog.log("[KaPosts] Cancelling a scheduled post failed: %@", error.localizedDescription)
                return AppLocalization.string("Couldn't reach the server, so this post is still scheduled. Try again in a moment.")
            }
        }
        entries.removeAll { $0.id == entry.id }
        persist()
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.reminderId(entry.id)])
        return nil
    }

    func remove(_ entry: KaPostScheduledEntry) {
        entries.removeAll { $0.id == entry.id }
        persist()
    }

    /// Submits, from this phone, every post whose time has come and that the indexer isn't going
    /// to send, and retries handing still-local future ones to the indexer.
    func sendDueLocally() async {
        // What the indexer did with posts past their time comes first; with no answer from it,
        // the phone sends them.
        let now = Date()
        if entries.contains(where: { $0.onServer && $0.status == .scheduled && $0.notBefore <= now }) {
            await pullServerOutcomes()
        }
        await submitDue()
    }

    private func submitDue() async {
        let now = Date()
        for id in entries.map(\.id) {
            // Read afresh: an earlier turn of this loop may have waited on the network.
            guard let entry = entries.first(where: { $0.id == id }), entry.status == .scheduled,
                  !inFlight.contains(id) else { continue }
            // The indexer's to send until it has had its tick. After that an indexer that's
            // down would strand the post, so the phone sends the same signed transaction.
            if entry.onServer, entry.notBefore.addingTimeInterval(Self.indexerGrace) > now { continue }
            inFlight.insert(id)
            defer { inFlight.remove(id) }
            if entry.notBefore <= now {
                var updated = entry
                do {
                    let txId = try await KaPostsAPIClient.shared.submitScheduledLocally(entry.transaction.transaction)
                    updated.status = .submitted
                    updated.submittedAt = Date()
                    AppLog.log("[KaPosts] Scheduled post submitted from the phone: %@", String(txId.prefix(12)))
                } catch let rejection as NodePoolService.NodeRejectedTransactionError {
                    updated.status = .failed
                    updated.error = rejection.localizedDescription
                    AppLog.log("[KaPosts] Scheduled post rejected: %@", rejection.localizedDescription)
                } catch {
                    // Offline, still connecting, or no answer: it stays scheduled, its coins
                    // held, and goes again next time. The same signed transaction can't pay twice.
                    AppLog.log("[KaPosts] Scheduled post not sent yet: %@", error.localizedDescription)
                    continue
                }
                update(updated)
                UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.reminderId(entry.id)])
            } else {
                // Still in the future and still only here: try the indexer again.
                let scheduled = KaPostsAPIClient.ScheduledTransaction(
                    txId: entry.id, payload: "", spentOutpoints: entry.spentOutpoints,
                    restJSON: KaPostsAPIClient.restJSON(for: entry.transaction.transaction),
                    transaction: entry.transaction.transaction
                )
                if (try? await KaPostsAPIClient.shared.scheduleOnServer(scheduled, notBefore: entry.notBefore)) != nil {
                    var updated = entry
                    updated.onServer = true
                    update(updated)
                    UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.reminderId(entry.id)])
                }
            }
        }
    }

    /// The indexer's view of this wallet's scheduled posts, then whatever is left for the phone.
    func refreshFromServer() async {
        await pullServerOutcomes()
        await submitDue()
    }

    /// Submitted and failed outcomes land here. A post past its time that the indexer no longer
    /// knows turns local, so `submitDue` settles it: on chain, or rejected and its coins freed.
    private func pullServerOutcomes() async {
        // Only posts the server holds have anything to learn from it.
        guard entries.contains(where: { $0.onServer }) else { return }
        guard let remote = try? await KaPostsAPIClient.shared.fetchScheduledPosts() else { return }
        let byId = Dictionary(remote.map { ($0.txId, $0) }, uniquingKeysWith: { a, _ in a })
        let now = Date()
        var changed = false
        for index in entries.indices where entries[index].onServer && !inFlight.contains(entries[index].id) {
            guard let server = byId[entries[index].id] else {
                if entries[index].status == .scheduled, entries[index].notBefore <= now {
                    entries[index].onServer = false
                    changed = true
                }
                continue
            }
            let status = KaPostScheduledEntry.Status(rawValue: server.status) ?? entries[index].status
            if status != entries[index].status || server.error != entries[index].error {
                entries[index].status = status
                entries[index].error = server.error
                entries[index].submittedAt = server.submittedAt.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
                changed = true
            }
        }
        if changed { persist() }
    }

    // MARK: - Reminder (local fallback only)

    private static func reminderId(_ txId: String) -> String { "kaposts-scheduled-\(txId)" }

    /// A local notification at the scheduled time for a post only this phone holds: opening
    /// the app is what sends it.
    private func scheduleReminder(for entry: KaPostScheduledEntry) {
        let content = UNMutableNotificationContent()
        content.title = "Scheduled post"
        content.body = "Your post is ready to go out. Open KaPost to send it."
        content.sound = .default
        content.threadIdentifier = "kaposts-scheduled"
        let seconds = max(1, entry.notBefore.timeIntervalSinceNow)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)
        let request = UNNotificationRequest(identifier: Self.reminderId(entry.id), content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { AppLog.log("[KaPosts] Scheduled-post reminder failed: %@", error.localizedDescription) }
        }
    }
}
