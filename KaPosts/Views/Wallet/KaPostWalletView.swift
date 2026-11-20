import SwiftUI
import UIKit

/// Profile > Wallet, KaChat's and KaPay's Wallet tab in KaPost: the balance card up top (Kaspa's
/// total, split into the chatting and spending addresses, swiping to a page per token, kUSDT), then
/// Send, Receive and Request, then the sections from KaPay's Wallet tab (`WalletAccountSections`).
/// An address's own actions (Compound UTXOs, its keys) are in Manage Addresses.
/// Pushed, so the dock stays under it.
struct KaPostWalletView: View {
    @EnvironmentObject private var walletManager: WalletManager
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
    /// The balance card's Kaspa page, tapped: Manage Addresses, pushed.
    @State private var showManageAddresses = false
    /// A token's page of the balance card, tapped: Manage kUSDT (`TokenManageView`), pushed.
    @State private var openToken: WalletToken?
    /// The balance card's page: 0 is Kaspa, then one per token (`TokenWallet.tokens`).
    @State private var balancePage = 0
    /// The tallest page, so the swipeable card is as tall as its content.
    @State private var balanceCardHeight: CGFloat = 196

    /// What the screen last showed for an account, so coming back to it (a fresh view each push)
    /// shows it at once, and asks the network again only once it's 30 s old.
    private struct Snapshot {
        var spendingTotalSompi: UInt64?
        var loadedAt: Date
    }
    @MainActor private static var snapshots: [String: Snapshot] = [:]

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
        .refreshable { await pullToRefresh() }
        .kaPostsFixedTitle("Wallet")
        .background(Color(UIColor.systemBackground).ignoresSafeArea())
        .navigationTitle("Wallet")
        .navigationBarTitleDisplayMode(.inline)
        .kaPostsStatusChrome()
        .toast(message: toastMessage)
        .navigationDestination(isPresented: $showManageAddresses) {
            ManageAddressesView()
        }
        .navigationDestination(isPresented: Binding(get: { openToken != nil }, set: { if !$0 { openToken = nil } })) {
            if let openToken { TokenManageView(token: openToken) }
        }
        .sheet(item: $action) { action in
            switch action {
            case .send:
                // "What are you sending?" first: Kaspa or a token, as in KaPay
                SendAssetChooser(spendingSompi: spendingTotalSompi) {
                    scheduleRefresh()
                }
            case .receive:
                // A fresh regular address, never used before, as in KaPay (the shared receive
                // screen draws its own "Receive Kaspa" title).
                NavigationStack {
                    ReceiveKaspaQRView()
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .navigationBarLeading) {
                                Button("Close") { self.action = nil }
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
        .onAppear {
            // The network part at most every 30 s: going in and out of this screen would start
            // these requests each time. Arriving funds still refresh at once, below.
            if appearRefreshedAt == nil, let address = walletManager.currentWallet?.publicAddress,
               let snapshot = Self.snapshots[address] {
                spendingTotalSompi = snapshot.spendingTotalSompi
                appearRefreshedAt = snapshot.loadedAt
            }
            if let at = appearRefreshedAt, Date().timeIntervalSince(at) < 30 { return }
            appearRefreshedAt = Date()
            Task { await refresh(force: false) }
            // Receive's address decided ahead of the tap, so the QR opens without a wait.
            Task {
                let account = walletManager.currentWallet?.publicAddress
                guard let address = await walletManager.freshReceiveAddress() else { return }
                ReceiveAddressWarmCache.store(address, for: account)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ownAddressUtxoActivity)) { _ in
            scheduleRefresh()
        }
        .onChange(of: walletManager.currentWallet?.publicAddress) { _ in
            // The total belongs to the account it was read for: a dash until the new one's lands.
            spendingTotalSompi = nil
            scheduleRefresh()
        }
    }

    private func content(_ wallet: Wallet) -> some View {
        VStack(spacing: 16) {
            balancePager(wallet)
            actionsRow
            if backupStatus.isHygieneDue(wallet.publicAddress) {
                BackupHygieneCard { showBackupHygiene = true }
            }
            // KaPay's Wallet tab: the Chatting Address and Your Domains rows.
            WalletAccountSections(wallet: wallet, onMessage: showToast)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 24)
    }

    // MARK: - Balance

    /// Total Balance, then a page per token (kUSDT), swiped between, with the "Kaspa"/"kUSDT" pills
    /// under it (KaPay's design, 2026-11-19). Each card says "Tap to Manage": Total Balance opens
    /// Manage Addresses, a token's page opens its screen. Plain taps, not NavigationLinks: those
    /// hold the touch a moment before a swipe can have it.
    private func balancePager(_ wallet: Wallet) -> some View {
        let tokens = TokenWallet.shared.tokens
        return VStack(spacing: 10) {
            SlidingCardPager(pages: [
                AnyView(
                    balanceCard(wallet)
                        .fixedSize(horizontal: false, vertical: true)
                        .background(BalanceCardHeightReader())
                        .onTapGesture {
                            Haptics.impact(.light)
                            showManageAddresses = true
                        }
                )
            ] + tokens.map { token in
                AnyView(
                    TokenBalanceCard(token: token)
                        .fixedSize(horizontal: false, vertical: true)
                        .background(BalanceCardHeightReader())
                        .onTapGesture {
                            Haptics.impact(.light)
                            openToken = token
                        }
                )
            }, page: $balancePage)
            .frame(height: balanceCardHeight)
            .onPreferenceChange(BalanceCardHeightKey.self) { height in
                if height > 0 { balanceCardHeight = height }
            }
            BalancePagePills(titles: [AppLocalization.string("Kaspa")] + tokens.map(\.symbol), selected: $balancePage)
        }
    }

    private func balanceCard(_ wallet: Wallet) -> some View {
        let chatting = wallet.balanceSompi
        // Both parts or a dash: a total missing one of them would read as the whole balance.
        let total: UInt64? = {
            guard let chatting, let spendingTotalSompi else { return nil }
            return chatting + spendingTotalSompi
        }()
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Total Balance")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer(minLength: 0)
                    TapToManageLabel()
                }
                // the whole card opens Manage Addresses (no copy-the-balance tap, as in KaPay)
                Text(verbatim: total.map(KaspaUnit.groupedAmount) ?? "--")
                    .font(.largeTitle.weight(.bold))
                    .foregroundColor(.primary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
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
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func balancePart(title: LocalizedStringKey, sompi: UInt64?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(verbatim: sompi.map(KaspaUnit.groupedAmount) ?? "--")
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
        await loadSpendingTotal()
        guard let address = walletManager.currentWallet?.publicAddress else { return }
        Self.snapshots[address] = Snapshot(spendingTotalSompi: spendingTotalSompi, loadedAt: Date())
    }

    /// Pull to refresh always scans every address for balances (owner's call, 2026-11-20): the
    /// known balances first, so the card updates at once, then the full sweeps Discover runs in
    /// Manage Addresses (Kaspa, from address 1, revealing any it finds past the list) and in Manage
    /// kUSDT (the Chatting Address and every spending address to 20 past the last), one after the
    /// other, since both may reveal addresses. Then the totals once more, with what they found.
    private func pullToRefresh() async {
        await refresh(force: true)
        await walletManager.discoverSpendingAddresses()
        _ = await TokenWallet.shared.discoverHoldings(of: .kusdt) { _, _ in }
        await refresh(force: true)
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

/// The balance card pages' heights: the swipeable card takes the tallest.
private struct BalanceCardHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct BalanceCardHeightReader: View {
    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(key: BalanceCardHeightKey.self, value: proxy.size.height)
        }
    }
}
