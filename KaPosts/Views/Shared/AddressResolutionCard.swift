import SwiftUI

/// Who is behind the address a screen has resolved - the card the create-chat screen shows,
/// for every other place an address or a domain goes in (withdrawals, sends from an address,
/// the portfolio, a group invite). The SCREEN does the resolving (.kachat first, see
/// `NameServicesClient.resolveEverywhere`); this card takes the outcome and shows the face and
/// the name: the domain that was typed, else the address's own .kachat name once it is confirmed
/// on the chain the way a typed name is (`KachatNamesRegistry.verifyLabel`) - until then, only
/// the address. Nil address, no card - a half-typed address gets nothing rather than a card
/// flickering through wrong faces.
struct AddressResolutionCard: View {
    /// The address the input stands for: a valid typed address, or a domain's resolved owner.
    let address: String?
    /// The domain that resolved to it, when the user typed one (shown at once, before the
    /// profile fetch lands).
    var domain: String? = nil

    @State private var profile: KNSAddressProfileInfo?
    @State private var isLoadingProfile = false
    /// While the address's .kachat name is being confirmed on the chain.
    @State private var isVerifyingName = false
    /// Re-renders only when an identity or a confirmed label changes, not on every registry refresh.
    @ObservedObject private var identityChanges = KachatIdentityChanges.shared

    /// The name to show: the domain typed, else the address's .kachat name confirmed on the chain
    /// (never the indexer's word alone: this card sits on payment screens).
    private func displayName(for address: String) -> String? {
        if let domain { return domain }
        if let label = KachatNamesRegistry.shared.verifiedLabel(for: address) { return KachatNameLabel.display(label) }
        return profile?.domainName
    }

    private var isLooking: Bool { isLoadingProfile || isVerifyingName }

    var body: some View {
        if let address, !address.isEmpty {
            HStack(spacing: 12) {
                KNSAvatarView(
                    avatarURLString: profile?.avatarURL,
                    fallbackText: displayName(for: address) ?? address,
                    size: 44,
                    contactAddress: address
                )
                VStack(alignment: .leading, spacing: 2) {
                    let name = displayName(for: address)
                    Text(name ?? (isLooking ? "Looking up..." : "No domain"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(name == nil ? .secondary : .primary)
                        .lineLimit(1)
                    Text(address)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    // one of this wallet's own addresses: you are sending to yourself
                    if let own = WalletManager.shared.ownAddressLabel(for: address) {
                        Label(String(format: AppLocalization.string("Your own address: %@"), own),
                              systemImage: "person.crop.circle.badge.checkmark")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.accentColor)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if isLooking { ProgressView().controlSize(.small) }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .task(id: address) {
                async let name: Void = verifyName(for: address)
                await loadProfile(for: address)
                await name
            }
        }
    }

    /// Confirms the address's .kachat name on the chain (kept by the registry for ten minutes).
    /// Not needed when the screen passed the domain it resolved.
    private func verifyName(for address: String) async {
        isVerifyingName = false
        guard domain == nil, KaspaAddress.isValid(address) else { return }
        isVerifyingName = KachatNamesRegistry.shared.verifiedLabel(for: address) == nil
        defer { if address == self.address { isVerifyingName = false } }
        await KachatNamesRegistry.shared.verifyLabel(for: address)
    }

    /// Cached by KNSService, so an address already looked at costs nothing.
    /// A new address starts clean - never the previous one's avatar or name while it loads - and
    /// the spinner always stops, a cancelled lookup included (IOS-074).
    private func loadProfile(for address: String) async {
        profile = nil
        isLoadingProfile = false
        guard KaspaAddress.isValid(address) else { return }
        if let cached = KNSService.shared.profileCache[address] {
            profile = cached
            return
        }
        isLoadingProfile = true
        // a lookup for an address the card no longer shows leaves the newer one's spinner alone
        defer { if address == self.address { isLoadingProfile = false } }
        let fetched = await KNSService.shared.fetchProfile(for: address)
        guard !Task.isCancelled, address == self.address else { return }
        profile = fetched
    }
}
