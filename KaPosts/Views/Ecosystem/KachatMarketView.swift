import SwiftUI

// MARK: - An address's .kachat names

/// A wallet's Domains tab: the `.kachat` names the address holds, to look at only. Names are
/// registered, renewed, sold and transferred in KaPay (owner's call, 2026-11-18); the tab links to
/// the account's own list, Wallet > Your Domains > .kachat, which is display only too. `.kachat`
/// is the only name service KaPosts reads - no .kas, .k or .kaspa.
struct AddressDomainsTab: View {
    let address: String

    /// The bare names, nil while loading. Shown through `KachatNameLabel` when drawn.
    @State private var names: [String]?
    /// Redraws the list when Show .kachat Endings flips.
    @AppStorage(KachatNameLabel.showEndingsKey) private var showsEndings = true

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                manageNote
                if let names {
                    if names.isEmpty {
                        Text("No .kachat names on this address.")
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    } else {
                        ForEach(names, id: \.self) { name in
                            DomainNameCardView(title: KachatNameLabel.display(name))
                        }
                    }
                } else {
                    ProgressView()
                        .padding(.vertical, 24)
                }
            }
            .padding()
        }
        .refreshable { await load() }
        .task(id: address) { await load() }
    }

    /// The account's own .kachat list (the Chatting Address's, which holds the names and offers on
    /// every address of this wallet): the same screen as Wallet > Your Domains > .kachat.
    private var accountAddress: String? {
        WalletManager.shared.currentWallet?.publicAddress
    }

    private var manageNote: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Manage your domains", systemImage: "at")
                .font(.headline)
            Text("This tab shows the .kachat names on this address. Register, renew, sell or transfer them in KaPay.")
                .font(.subheadline)
                .foregroundColor(.secondary)
            if KachatNamesService.isEnabled, let accountAddress {
                NavigationLink {
                    KachatLiveDomainsTab(walletAddress: accountAddress)
                        .navigationTitle(Text(verbatim: NameServiceTLD.kachat.suffix))
                        .navigationBarTitleDisplayMode(.inline)
                } label: {
                    Text("Open Your Domains")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.accentColor))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
    }

    private func load() async {
        let normalized = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let held = await NameServicesClient.shared.kachatNames(of: [normalized])
        names = (held[normalized] ?? []).map(\.name)
    }
}
