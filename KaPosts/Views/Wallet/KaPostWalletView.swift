import SwiftUI
import UIKit

/// Profile > Wallet, KaChat's and KaPay's Wallet tab in KaPost: the total up top, split into the
/// chatting and spending addresses, then Send, Receive and Request, then the chatting address's
/// history. KaPost only uses the chatting address: Send leaves from it and Receive and Request are
/// paid to it. Other addresses count in the total and are managed in KaChat and KaPay. Pushed, so
/// the dock stays under it.
struct KaPostWalletView: View {
    @EnvironmentObject private var walletManager: WalletManager
    @EnvironmentObject private var chatService: ChatService
    @EnvironmentObject private var settingsViewModel: SettingsViewModel
    @ObservedObject private var backupStatus = AccountBackupStatus.shared
    @ObservedObject private var priceService = KaspaPriceService.shared

    /// Every revealed spending address together. Nil until it's known, which shows as a dash.
    @State private var spendingTotalSompi: UInt64?
    /// The pending coalesced refresh - see `scheduleRefresh`.
    @State private var refreshTask: Task<Void, Never>?
    @State private var appearRefreshedAt: Date?
    @State private var action: WalletAction?
    @State private var showBackupHygiene = false
    @State private var toastMessage: String?
    @State private var toastToken = UUID()
    /// The chatting address's history, newest first, under the buttons.
    @State private var transactions: [KaspaFullTransactionResponse] = []
    @State private var isLoadingHistory = false
    /// The last fetch gave up partway: a failed read isn't an empty history.
    @State private var historyIncomplete = false
    @State private var transactionActionTarget: KaspaFullTransactionResponse?

    private enum WalletAction: String, Identifiable {
        case send, receive, request
        var id: String { rawValue }
    }

    var body: some View {
        ScrollView {
            if let wallet = walletManager.currentWallet {
                content(wallet)
            }
        }
        .refreshable { await refresh(force: true) }
        .kaPostsFixedTitle("Wallet")
        .background(Color(UIColor.systemBackground).ignoresSafeArea())
        .navigationTitle("Wallet")
        .navigationBarTitleDisplayMode(.inline)
        .kaPostsStatusChrome()
        .toast(message: toastMessage)
        .sheet(item: $action) { action in
            switch action {
            case .send:
                if let wallet = walletManager.currentWallet {
                    WithdrawKaspaView(fromAddress: wallet.publicAddress, availableBalanceSompi: wallet.balanceSompi) {
                        scheduleRefresh()
                    }
                }
            case .receive:
                if let wallet = walletManager.currentWallet {
                    NavigationStack {
                        ChattingAddressQRView(address: wallet.publicAddress, balanceSompi: wallet.balanceSompi)
                            .toolbar {
                                ToolbarItem(placement: .navigationBarLeading) {
                                    Button("Close") { self.action = nil }
                                }
                            }
                    }
                }
            case .request:
                CreatePaymentRequestView()
            }
        }
        .sheet(isPresented: $showBackupHygiene) {
            BackupHygieneView()
        }
        .sheet(item: $transactionActionTarget) { tx in
            TransactionActionsSheet(transaction: tx, onOpenExplorer: { openInExplorer(tx) })
        }
        .onAppear {
            // The network part at most every 30 s: going in and out of this screen would start
            // these requests each time. Arriving funds still refresh at once, below.
            if let at = appearRefreshedAt, Date().timeIntervalSince(at) < 30 { return }
            appearRefreshedAt = Date()
            Task { await refresh(force: false) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ownAddressUtxoActivity)) { _ in
            scheduleRefresh()
        }
        .onChange(of: walletManager.currentWallet?.publicAddress) { _ in
            // The total belongs to the account it was read for: a dash until the new one's lands.
            spendingTotalSompi = nil
            transactions = []
            scheduleRefresh()
        }
    }

    private func content(_ wallet: Wallet) -> some View {
        VStack(spacing: 20) {
            balanceCard(wallet)
            actionsRow
            if backupStatus.isHygieneDue(wallet.publicAddress) {
                BackupHygieneCard { showBackupHygiene = true }
            }
            history(for: wallet.publicAddress)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 24)
    }

    // MARK: - Balance

    private func balanceCard(_ wallet: Wallet) -> some View {
        let chatting = wallet.balanceSompi
        // Both parts or a dash: a total missing one of them would read as the whole balance.
        let total: UInt64? = {
            guard let chatting, let spendingTotalSompi else { return nil }
            return chatting + spendingTotalSompi
        }()
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Total Balance")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Button {
                    guard let total else { return }
                    UIPasteboard.general.string = KaspaUnit.plain(total)
                    Haptics.success()
                    showToast(AppLocalization.string("Balance copied to clipboard."))
                } label: {
                    Text(verbatim: total.map(KaspaUnit.amount) ?? "--")
                        .font(.largeTitle.weight(.bold))
                        .foregroundColor(.primary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                .buttonStyle(.plain)
                if let fiat = fiatText(total) {
                    Text(verbatim: fiat)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }

            Divider()

            HStack(alignment: .top, spacing: 16) {
                balancePart(title: "Chatting", sompi: chatting)
                balancePart(title: "Spending", sompi: spendingTotalSompi)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color.accentColor.opacity(0.32), Color.accentColor.opacity(0.08)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.accentColor.opacity(0.35), lineWidth: 0.8)
                )
        )
    }

    private func balancePart(title: LocalizedStringKey, sompi: UInt64?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(verbatim: sompi.map(KaspaUnit.amount) ?? "--")
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What the total is worth in your currency. Testnet coins aren't worth anything.
    private func fiatText(_ sompi: UInt64?) -> String? {
        guard let sompi, AppSettings.load().networkType == .mainnet,
              let price = priceService.currentPriceUsd, price > 0 else { return nil }
        return formatFiatAmount(Double(sompi) / 100_000_000.0 * price, currency: priceService.currentCurrency)
    }

    // MARK: - Actions

    private var actionsRow: some View {
        HStack(alignment: .top, spacing: 12) {
            actionButton(title: "Send", icon: "arrow.up") { action = .send }
            actionButton(title: "Receive", icon: "arrow.down") { action = .receive }
            actionButton(title: "Request", icon: "doc.text") { action = .request }
        }
    }

    private func actionButton(title: LocalizedStringKey, icon: String, perform: @escaping () -> Void) -> some View {
        Button {
            Haptics.impact(.light)
            perform()
        } label: {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.scaled(size: 22, weight: .semibold))
                    .foregroundColor(.black)
                    .frame(width: 60, height: 60)
                    .background(Circle().fill(Color.accentColor))
                Text(title)
                    .font(.subheadline)
                    .foregroundColor(.primary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - History

    private func history(for address: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Transaction History")
                .font(.headline)
            if isLoadingHistory && transactions.isEmpty {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .padding(.vertical, 18)
            } else if transactions.isEmpty && historyIncomplete {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Could not load transactions.")
                        .foregroundColor(.secondary)
                    Button("Try Again") {
                        Task { await loadHistory() }
                    }
                    .font(.subheadline.weight(.semibold))
                }
            } else if transactions.isEmpty {
                Text("No transactions yet.")
                    .foregroundColor(.secondary)
            } else {
                if historyIncomplete {
                    Text("Some transactions could not be loaded. Pull to refresh to try again.")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                VStack(spacing: 0) {
                    ForEach(transactions, id: \.transactionId) { tx in
                        Button {
                            Haptics.impact(.light)
                            transactionActionTarget = tx
                        } label: {
                            AddressTransactionRow(transaction: tx, address: address)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if tx.transactionId != transactions.last?.transactionId {
                            Divider().padding(.leading, 14)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func loadHistory() async {
        guard let address = walletManager.currentWallet?.publicAddress else { return }
        isLoadingHistory = true
        let result = await chatService.fetchFullTransactionsResult(for: address, pageSize: 200, maxTransactions: 200)
        // A read that finishes after an account switch belongs to the old account: dropped.
        guard walletManager.currentWallet?.publicAddress == address else { return }
        // block rewards the chain never accepted paid nothing: not history
        transactions = result.transactions.filter(\.belongsInHistory)
        historyIncomplete = !result.complete
        isLoadingHistory = false
    }

    private func openInExplorer(_ tx: KaspaFullTransactionResponse) {
        guard let url = settingsViewModel.settings.kaspaExplorer.txURL(for: tx.transactionId) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - Loading

    /// Coalesces the bursts `.ownAddressUtxoActivity` arrives in.
    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await refresh(force: true)
        }
    }

    private func refresh(force: Bool) async {
        _ = try? await walletManager.refreshBalance(force: force)
        async let spending: Void = loadSpendingTotal()
        async let history: Void = loadHistory()
        _ = await (spending, history)
    }

    private func loadSpendingTotal() async {
        // A read that finishes after an account switch belongs to the old account: dropped.
        let account = walletManager.currentWallet?.publicAddress
        // The whole set, in ONE call - a per-address loop would be dozens of requests on a wallet
        // that has been used, and the node takes the list.
        let all = walletManager.allSpendingAddresses()
        // None revealed yet: nothing has been sent there.
        guard !all.isEmpty else {
            spendingTotalSompi = 0
            return
        }
        // A failure leaves the previous total in place: a few seconds stale reads better than a
        // figure that vanishes because one request timed out.
        if let utxos = try? await NodePoolService.shared.getUtxosByAddresses(all),
           walletManager.currentWallet?.publicAddress == account {
            spendingTotalSompi = utxos.reduce(UInt64(0)) { $0 + $1.amount }
        }
    }

    private func showToast(_ message: String) {
        let token = UUID()
        toastToken = token
        withAnimation(.easeOut(duration: 0.2)) {
            toastMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if toastToken == token {
                withAnimation(.easeIn(duration: 0.2)) {
                    toastMessage = nil
                }
            }
        }
    }
}
