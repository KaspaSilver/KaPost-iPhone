import SwiftUI
import UIKit

// KaPost's `.kachat` screens: Wallet > Your Domains > .kachat (display only) and the address
// profile editor with its save sheet and receipt. Claiming, renewing, selling, transferring,
// buying and offers are KaPay's (owner's call, 2026-11-18). A profile save shows its fee first,
// then passes the device's own lock (`DeviceAuth`) before anything is signed.

// MARK: - Amounts

extension KaspaUnit {
    /// "35 TKAS", "0.2 TKAS", "1.99831 TKAS": exact, trailing zeros dropped.
    static func amount(_ sompi: UInt64) -> String {
        "\(plain(sompi)) \(symbol)"
    }

    static func plain(_ sompi: UInt64) -> String {
        let whole = sompi / 100_000_000
        let frac = sompi % 100_000_000
        guard frac > 0 else { return "\(whole)" }
        var f = String(format: "%08llu", frac)
        while f.hasSuffix("0") { f.removeLast() }
        return "\(whole).\(f)"
    }
}

// MARK: - Shared pieces

enum KachatLive {
    /// What the device lock prompt says before a .kachat profile save is signed.
    static var authReason: String { AppLocalization.string("Confirm this .kachat transaction") }

    static func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: TimeInterval(ms) / 1000) }

    /// A unix-ms day as a row value ("Oct 12, 2027"), in the in-app language, with the time when
    /// it is within two days (testnet's 24-hour periods).
    static func day(_ ms: Int64) -> String {
        let near = abs(ms - KachatNames.nowMs()) < 2 * 86_400_000
        return date(ms).formatted(Date.FormatStyle(date: .abbreviated, time: near ? .shortened : .omitted).locale(AppLocalization.locale))
    }

    /// Who an address is when you haven't named it yourself: its `.kachat` name ("alice.kachat", or "alice" with endings off),
    /// the same rule as `ContactsManager.displayName`. nil without one (mainnet, until names
    /// launch). Views that call this observe `KachatNamesRegistry` so the name lands on its own.
    @MainActor static func identityName(_ address: String) -> String? {
        guard !address.isEmpty else { return nil }
        return KachatNamesRegistry.shared.cachedIdentity(for: address)?.label.map(KachatNameLabel.display)
    }

    /// An address's `.kachat` profile banner and bio, each looked up from its social link on this
    /// device (every network: profiles aren't registry data). Callers observe
    /// `KachatNamesRegistry` and `KachatSocialImageResolver`.
    @MainActor static func profileBanner(_ address: String) -> String? {
        let link = KachatNamesRegistry.shared.cachedIdentity(for: address)?.profile?.banner
        return KachatSocialImageResolver.shared.profile(for: link)?.banner
    }

    @MainActor static func profileBio(_ address: String) -> String? {
        let link = KachatNamesRegistry.shared.cachedIdentity(for: address)?.profile?.bio
        return KachatSocialImageResolver.shared.profile(for: link)?.bio
    }
}

// MARK: - A finished transaction

/// A profile save that went out: its headline and transaction id, for the half sheet below.
struct KachatTxDone: Identifiable, Equatable {
    var id: String { txId }
    let txId: String
    /// Localization key of the headline ("Profile saved", ...).
    var title: String = "Transaction sent"
}

/// The receipt a profile save ends on, in the Send receipt's style: what it does, its
/// progress - sent, in a block, showing in KaPost - and the transaction id
/// as a link to the block explorer picked in Settings (the testnet-10 one on testnet), opened in
/// the in-app browser. Closing it early is fine: the change still lands.
struct KachatTxDoneSheet: View {
    let done: KachatTxDone
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var actions = KachatNamesActions.shared
    @State private var browserURL: URL?

    private var explorerURL: URL? { AppSettings.load().kaspaExplorer.txURL(for: done.txId) }
    private var stage: KachatNamesActions.TxStage { actions.txStages[done.txId] ?? .sent }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch stage {
                case .shown:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.scaled(size: 52))
                        .foregroundColor(.green)
                case .dropped:
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.scaled(size: 52))
                        .foregroundColor(.orange)
                default:
                    ProgressView()
                        .controlSize(.large)
                        .frame(height: 52)
                }
            }
            .padding(.top, 28)

            Text(LocalizedStringKey(done.title))
                .font(.title3.weight(.bold))
                .padding(.top, 12)

            Text(stageText)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
                .padding(.top, 4)

            KachatTxStageSteps(txId: done.txId)
                .padding(.horizontal, 20)
                .padding(.top, 18)

            Button {
                browserURL = explorerURL
            } label: {
                HStack(spacing: 6) {
                    Text(verbatim: done.txId)
                        .font(.system(.footnote, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "arrow.up.right.square")
                        .font(.footnote)
                }
                .foregroundColor(.accentColor)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(sendKaspaGlass(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .disabled(explorerURL == nil)
            .padding(.horizontal, 20)
            .padding(.top, 12)

            Text("Tap the transaction to open it in the explorer.")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.top, 6)

            Button {
                dismiss()
            } label: {
                Text("Done")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Capsule().fill(Color.accentColor))
                    .foregroundColor(.black)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.top, 18)

            Spacer(minLength: 0)
        }
        .presentationDetents([.height(520), .large])
        .presentationDragIndicator(.visible)
        .task {
            // a profile save: follow its transaction here
            if actions.txStages[done.txId] == nil { actions.follow(txId: done.txId) }
        }
        .fullScreenCover(isPresented: Binding(
            get: { browserURL != nil },
            set: { if !$0 { browserURL = nil } }
        )) {
            if let browserURL {
                InAppBrowserScreen(url: browserURL) { self.browserURL = nil }
            }
        }
    }

    private var stageText: LocalizedStringKey {
        switch stage {
        case .sent, .inMempool: return "Waiting for the network to put it in a block. Usually a few seconds; longer when it's busy."
        case .accepted: return "It's in a block. Updating KaPost..."
        case .shown: return "Done. It shows in KaPost now."
        case .dropped: return "The network hasn't taken it. Nothing was spent if it never lands - try again with a faster fee."
        }
    }

}

/// A name transaction's progress, followed on a node: sent, in a block, showing in KaPost. In the
/// receipt half sheet.
struct KachatTxStageSteps: View {
    let txId: String
    @ObservedObject private var actions = KachatNamesActions.shared

    private var stage: KachatNamesActions.TxStage { actions.txStages[txId] ?? .sent }
    private var inBlock: Bool { stage == .accepted || stage == .shown }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            step("Sent to the network", done: true)
            step("In a block", done: inBlock, active: !inBlock && stage != .dropped)
            step("Updated in KaPost", done: stage == .shown, active: stage == .accepted)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(sendKaspaGlass(cornerRadius: 16))
    }

    private func step(_ title: LocalizedStringKey, done: Bool, active: Bool = false) -> some View {
        HStack(spacing: 10) {
            Group {
                if done {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                } else if active {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "circle").foregroundColor(.secondary)
                }
            }
            .frame(width: 20)
            Text(title)
                .font(.subheadline)
                .foregroundColor(done || active ? .primary : .secondary)
        }
    }
}

private struct LabeledRow: View {
    let title: LocalizedStringKey
    let value: String
    var bold = false

    var body: some View {
        HStack {
            Text(title).fontWeight(bold ? .semibold : .regular)
            Spacer()
            Text(verbatim: value)
                .fontWeight(bold ? .semibold : .regular)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
        }
    }
}

// MARK: - Your Domains > .kachat

/// What .kachat names are, what they cost and how to claim one: the page on home.kachat.app that
/// "Get a .kachat name" (Edit Profile) and "Get a .kachat domain" (Your Domains) open, the same as
/// KaChat. Names are claimed in KaPay only, never in KaPost (owner's call, 2026-11-18).
enum KachatNamesInfo {
    static let pageURL = URL(string: "https://home.kachat.app/kachat/")!
}

struct KachatLiveDomainsTab: View {
    let walletAddress: String
    @ObservedObject private var registry = KachatNamesRegistry.shared
    @ObservedObject private var service = KachatNamesService.shared
    @State private var names: [KachatNames.NameInfo] = []
    /// the offers this wallet made, kept only in the saved copy (`KachatOwnedNamesCache`)
    @State private var myOffers: [KachatNames.OfferInfo] = []
    @State private var loaded = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                if !loaded {
                    ProgressView().padding(.vertical, 24)
                } else if service.registryUpgrading {
                    // the bundled manifest is for the previous registry: calm, no error
                    VStack(spacing: 10) {
                        Image(systemName: "hammer")
                            .font(.system(size: 40, weight: .semibold))
                            .foregroundColor(.accentColor)
                        Text("Setting up")
                            .font(.headline)
                        Text("The .kachat registry is being upgraded. Names open here again once the new registry is live.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                } else {
                    if names.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "at.circle")
                                .font(.system(size: 44, weight: .semibold))
                                .foregroundColor(.accentColor)
                            Text("No .kachat names yet")
                                .font(.headline)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    } else {
                        // Display only, like KaChat: renewing, selling, transferring and offers
                        // are KaPay's (owner's call, 2026-11-18).
                        ForEach(names) { n in
                            DomainNameCardView(title: n.display, badge: Self.badge(for: n, graceMs: registry.graceMs),
                                               footnote: Self.expiryLine(for: n, graceMs: registry.graceMs))
                        }
                    }
                }
            }
            .padding()
        }
        .refreshable { await registry.refresh() }
        .task(id: registry.revision) {
            showCachedIfNeeded()
            await load()
            // a name that lapses while this is open leaves right then
            await registry.dropLapsed(from: names) { names = $0 }
        }
        .safeAreaInset(edge: .bottom) {
            if loaded && !service.registryUpgrading {
                getDomainButton
            }
        }
    }

    /// The same as KaChat's: opens the .kachat names page (`KachatNamesInfo.pageURL`). Names are
    /// claimed in KaPay, not here.
    private var getDomainButton: some View {
        Button {
            Haptics.impact(.light)
            UIApplication.shared.open(KachatNamesInfo.pageURL)
        } label: {
            Text("Get a .kachat domain")
                .font(.headline)
                .foregroundColor(.black)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(Capsule().fill(Color.accentColor))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    /// The card's bottom-right corner: when the name expires - or, once it has, when its grace
    /// period ends (renew before then to keep it, in KaPay).
    static func expiryLine(for n: KachatNames.NameInfo, graceMs: Int64) -> String? {
        switch n.status(graceMs: graceMs) {
        case .active: return String(format: AppLocalization.string("Expires %@"), KachatLive.day(n.expiresAt))
        case .grace: return String(format: AppLocalization.string("Grace ends %@"), KachatLive.day(KachatNames.clampedSum(n.expiresAt, graceMs)))
        case .lapsed: return nil
        }
    }

    /// The card badge for a name: Listed, or Expired (in grace). Lapsed names aren't listed
    /// (`heldNames`).
    static func badge(for n: KachatNames.NameInfo, graceMs: Int64) -> String? {
        switch n.status(graceMs: graceMs) {
        case .active: return n.isListed ? AppLocalization.string("Listed") : nil
        case .grace: return AppLocalization.string("Expired")
        case .lapsed: return AppLocalization.string("Available")
        }
    }

    /// The names this wallet had last time, straight away - they rarely change. `load()` then
    /// checks the registry and replaces them when it answers (`KachatOwnedNamesCache`).
    private func showCachedIfNeeded() {
        guard !loaded, let cached = KachatOwnedNamesCache.load(walletAddress) else { return }
        let grace = registry.graceMs
        names = cached.names.filter { $0.status(graceMs: grace) != .lapsed }
        myOffers = cached.offers
        loaded = true
    }

    private func load() async {
        guard let key = KachatNamesRegistry.keyOf(walletAddress) else { loaded = true; return }
        if registry.refreshedAt == nil { await registry.refresh() }
        // A lapsed name is no longer yours and leaves the list. Expired names in grace stay (they
        // are renewed in KaPay). Your own list (the chatting address's) holds the names on every
        // address of this wallet, on any device restored from the seed. Display only: offers are
        // read for the saved copy but never acted on here - KaPay returns or withdraws them.
        // Only an answer replaces what is shown (and the saved copy); a failed read keeps it.
        if walletAddress.lowercased() == KachatNamesActions.shared.myAddress {
            if let own = try? await KachatNamesActions.shared.ownNamesAndOffers(heldOnly: true) {
                names = own.names
                myOffers = own.offers
                KachatOwnedNamesCache.save(names: names, offers: myOffers, for: walletAddress)
            }
        } else if let held = try? await registry.heldNames(owner: key) {
            names = held
            myOffers = (try? await registry.myOffers(buyer: key)) ?? myOffers
            KachatOwnedNamesCache.save(names: names, offers: myOffers, for: walletAddress)
        }
        loaded = true
    }
}

// MARK: - Edit KaChat Profile

/// Where a social link's lookup stands - the editor saves only a field whose lookup found what
/// that field shows, so what gets saved is what was reviewed.
enum KachatSocialLookup: Equatable {
    case none, looking, found, empty, unreachable
}

/// One profile field's source (avatar, banner or bio) looked up on this device, showing exactly
/// the piece other people will see.
struct KachatSocialPreview: View {
    let link: String
    let kind: KachatNames.SocialSource.Kind
    @Binding var lookup: KachatSocialLookup

    @ObservedObject private var resolver = KachatSocialImageResolver.shared
    @State private var resolved: KachatNames.SocialProfile?
    @State private var attempt = 0
    /// The lookup whose answer may land: a newer one (edited link, Retry) supersedes it.
    @State private var activeKey = ""

    private var source: KachatNames.SocialSource? { KachatNames.SocialSource(link: link, for: kind) }

    private func piece(_ p: KachatNames.SocialProfile?) -> String? {
        switch kind {
        case .avatar: return p?.avatar
        case .banner: return p?.banner
        case .bio: return p?.bio
        }
    }

    var body: some View {
        // A VStack, not a Group: a Group hands its modifiers to each child, so `.task` below
        // would belong to whichever child shows - and switching from the spinner to the result
        // would cancel it and start the lookup again, endlessly. The VStack is one stable view.
        VStack(alignment: .leading, spacing: 0) {
            if let source {
                switch lookup {
                case .none, .looking:
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Looking up the profile...").font(.footnote).foregroundColor(.secondary)
                    }
                case .found:
                    found(source)
                case .empty:
                    note("person.crop.circle.badge.exclamationmark", missingText(source.platform))
                case .unreachable:
                    HStack(spacing: 10) {
                        Image(systemName: "wifi.exclamationmark").foregroundColor(.secondary)
                        Text(verbatim: String(format: AppLocalization.string("Couldn't reach %@."), source.platform.displayName))
                            .font(.footnote).foregroundColor(.secondary)
                        Spacer()
                        Button("Retry") { attempt += 1 }.font(.footnote.weight(.semibold))
                    }
                }
            }
        }
        // Debounced: one lookup once typing pauses. `attempt` reruns it for Retry. Whatever
        // happens - cancelled, restarted, failed - the state always lands somewhere final.
        .task(id: "\(source?.link ?? "")#\(attempt)") {
            let myKey = "\(source?.link ?? "")#\(attempt)"
            activeKey = myKey
            guard let source else { resolved = nil; lookup = .none; return }
            // The row scrolled back into view (a Form rebuilds its rows): the answer this
            // screen already got shows at once - no debounce, no "Looking up" flash, no
            // refetch. Retry (attempt > 0) still runs the full lookup.
            if attempt == 0, let cached = resolver.cachedProfile(source) {
                resolved = cached
                lookup = piece(cached) == nil ? .empty : .found
                // Still re-checked quietly (the resolver's own 5-minute freshness): a profile
                // changed on the platform lands here without the flash.
                let result = await resolver.resolve(source)
                guard activeKey == myKey, case .answered(let fresh) = result, fresh != cached else { return }
                resolved = fresh
                lookup = piece(fresh) == nil ? .empty : .found
                return
            }
            lookup = .looking
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard activeKey == myKey else { return }
            let result = await resolver.resolve(source)
            guard activeKey == myKey else { return }
            resolved = result.profile
            switch result {
            case .answered(let p):
                lookup = piece(p) == nil ? .empty : .found
            case .unreachable(let cached):
                lookup = piece(cached) == nil ? .unreachable : .found
            }
        }
    }

    @ViewBuilder
    private func found(_ source: KachatNames.SocialSource) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            switch kind {
            case .avatar:
                KNSAvatarView(avatarURLString: resolved?.avatar, fallbackText: "", size: 64)
            case .banner:
                KNSBannerImageView(bannerURLString: resolved?.banner, height: 90, cornerRadius: 8, fitsWidth: true)
            case .bio:
                Text(verbatim: resolved?.bio ?? "").font(.subheadline)
            }
            Text(verbatim: String(format: AppLocalization.string("From %@"), source.platform.displayName))
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func missingText(_ platform: KachatNames.SocialSource.Platform) -> String {
        let key: String
        switch kind {
        case .avatar: key = "No avatar on this %@ profile."
        case .banner: key = "No banner on this %@ profile."
        case .bio: key = "No bio on this %@ profile."
        }
        return String(format: AppLocalization.string(key), platform.displayName)
    }

    private func note(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundColor(.secondary)
            Text(verbatim: text).font(.footnote).foregroundColor(.secondary)
        }
    }
}

/// One profile field's source as the editor holds it: the platform picked and the handle typed.
struct KachatSourceInput: Equatable {
    var platform: KachatNames.SocialSource.Platform = .x
    var handle = ""

    init(platform: KachatNames.SocialSource.Platform = .x, handle: String = "") {
        self.platform = platform
        self.handle = handle
    }

    /// From a stored profile link.
    init(stored link: String?, _ kind: KachatNames.SocialSource.Kind) {
        if let s = KachatNames.SocialSource(link: link ?? "", for: kind) {
            self.init(platform: s.platform, handle: s.displayHandle)
        } else {
            self.init()
        }
    }

    var isEmpty: Bool { handle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func source(_ kind: KachatNames.SocialSource.Kind) -> KachatNames.SocialSource? {
        KachatNames.SocialSource.from(platform: platform, handle: handle, for: kind)
    }

    func isBad(_ kind: KachatNames.SocialSource.Kind) -> Bool { !isEmpty && source(kind) == nil }

    /// The source when the handle field holds a whole pasted link (rather than a handle).
    func pastedSource(_ kind: KachatNames.SocialSource.Kind) -> KachatNames.SocialSource? {
        let t = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.lowercased().hasPrefix("http") || (t.contains(".") && t.contains("/")) else { return nil }
        return source(kind)
    }
}

/// The address profile (KACHAT_NAMES.md section 7): where the avatar, banner and bio come from
/// (a social profile link each - they can be different accounts), a Linktree link, and which of
/// your names labels you - written as a `kchat:1:profile:` self-transfer. No free text and no
/// uploads: what shows comes from a platform that moderates it.
struct KachatLiveProfileEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var registry = KachatNamesRegistry.shared

    /// Each piece's source: a platform from the picker plus the handle typed after its prefix.
    @State private var avatarIn = KachatSourceInput()
    @State private var bannerIn = KachatSourceInput()
    @State private var bioIn = KachatSourceInput()
    @State private var avatarLookup: KachatSocialLookup = .none
    @State private var bannerLookup: KachatSocialLookup = .none
    @State private var bioLookup: KachatSocialLookup = .none
    @State private var linktree = ""
    @State private var primary = ""
    @State private var activeNames: [String] = []
    @State private var loaded = false
    @State private var showSave = false
    @State private var showClear = false

    private typealias Kind = KachatNames.SocialSource.Kind

    private var profile: KachatNames.Profile {
        var p = KachatNames.Profile()
        p.avatar = avatarIn.source(.avatar)?.link
        p.banner = bannerIn.source(.banner)?.link
        p.bio = bioIn.source(.bio)?.link
        p.linktree = KachatNames.Profile.linktreeLink(username: linktree)
        p.primaryName = primary.isEmpty ? nil : primary
        return p.sanitized()
    }

    /// A filled-in field whose lookup hasn't found what it shows (still looking, unreachable, or
    /// nothing there). It doesn't block saving - a social site being slow or unreachable from
    /// this phone must never stop a profile (or a primary name) from saving; the link is saved
    /// as entered and every viewer's app looks it up itself. The editor just says so.
    private func notReviewed(_ input: KachatSourceInput, _ lookup: KachatSocialLookup) -> Bool {
        !input.isEmpty && lookup != .found
    }

    private var hasUncheckedLinks: Bool {
        notReviewed(avatarIn, avatarLookup) || notReviewed(bannerIn, bannerLookup) || notReviewed(bioIn, bioLookup)
    }

    /// Only a malformed handle or Linktree username stops a save.
    private var blocked: Bool {
        avatarIn.isBad(.avatar) || bannerIn.isBad(.banner) || bioIn.isBad(.bio) || badLinktree
    }

    /// The Linktree field holds just the username (`linktr.ee/` is shown in front of it).
    private var badLinktree: Bool {
        let t = linktree.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && KachatNames.Profile.linktreeLink(username: t) == nil
    }

    /// Once one field's account is found, the empty fields take the same account where its
    /// platform can fill them - one handle sets up the whole profile, and each stays editable.
    private func fillEmpty(from input: KachatSourceInput) {
        let fits = { (kind: Kind) in KachatNames.SocialSource.Platform.choices(for: kind).contains(input.platform) }
        if avatarIn.isEmpty, fits(.avatar) { avatarIn = input }
        if bannerIn.isEmpty, fits(.banner) { bannerIn = input }
        if bioIn.isEmpty, fits(.bio) { bioIn = input }
    }

    /// Platform picker, the handle after the platform's prefix, and the preview of what it shows.
    private func sourceField(_ input: Binding<KachatSourceInput>, _ kind: Kind, _ lookup: Binding<KachatSocialLookup>) -> some View {
        Group {
            Picker("Account on", selection: input.platform) {
                ForEach(KachatNames.SocialSource.Platform.choices(for: kind), id: \.self) { p in
                    Text(verbatim: p.displayName).tag(p)
                }
            }
            .pickerStyle(.menu)
            HStack(spacing: 0) {
                Text(verbatim: input.wrappedValue.platform.prefix).foregroundColor(.secondary)
                TextField(input.wrappedValue.platform == .discord ? LocalizedStringKey("invite") : LocalizedStringKey("handle"), text: input.handle)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onChange(of: input.wrappedValue.handle) { _ in
                        // A whole pasted link: switch the picker to its platform, keep the handle.
                        if let pasted = input.wrappedValue.pastedSource(kind) {
                            input.wrappedValue = KachatSourceInput(platform: pasted.platform, handle: pasted.displayHandle)
                        }
                    }
                // One tap empties the field; saving then writes the profile without it.
                if !input.wrappedValue.handle.isEmpty {
                    Button {
                        input.wrappedValue = KachatSourceInput()
                        lookup.wrappedValue = .none
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Clear"))
                }
            }
            // Only while the handle names an account: no empty row, and the lookup starts when it
            // appears.
            if let link = input.wrappedValue.source(kind)?.link {
                KachatSocialPreview(link: link, kind: kind, lookup: lookup)
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label {
                        Text("Your profile belongs to your address, not to a name: it stays the same when you buy, sell or let a name go.")
                            .font(.subheadline)
                    } icon: {
                        Image(systemName: "person.text.rectangle").foregroundColor(.accentColor)
                    }
                } footer: {
                    Text("Each piece comes from a social profile you link, exactly as that platform shows it, so its moderation applies here too. You can use one account for all three, or mix them.")
                }
                Section {
                    sourceField($avatarIn, .avatar, $avatarLookup)
                } header: { Text("Avatar") } footer: {
                    if avatarIn.isBad(.avatar) { invalidHandleNote }
                }
                Section {
                    sourceField($bannerIn, .banner, $bannerLookup)
                } header: { Text("Banner") } footer: {
                    if bannerIn.isBad(.banner) { invalidHandleNote }
                }
                Section {
                    sourceField($bioIn, .bio, $bioLookup)
                } header: { Text("Bio") } footer: {
                    if bioIn.isBad(.bio) { invalidHandleNote }
                }
                Section {
                    HStack(spacing: 0) {
                        Text(verbatim: "linktr.ee/").foregroundColor(.secondary)
                        TextField("username", text: $linktree)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        if !linktree.isEmpty {
                            Button {
                                linktree = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text("Clear"))
                        }
                    }
                } header: { Text("Links") } footer: {
                    if badLinktree {
                        Text("Enter your Linktree username: letters, numbers, dots, dashes or underscores.").foregroundColor(.red)
                    } else {
                        Text("Add your Linktree to point people to your other accounts and websites.")
                    }
                }
                Section {
                    // The primary name needs the registry: until it launches on this network
                    // (mainnet) there's no name to pick, so the profile saves without one.
                    if KachatNamesService.isLaunched {
                        Picker("Primary name", selection: $primary) {
                            Text("None").tag("")
                            ForEach(activeNames, id: \.self) { n in Text(verbatim: KachatNameLabel.display(n)).tag(n) }
                        }
                    } else {
                        HStack {
                            Text("Primary name")
                            Spacer()
                            Text("Coming soon").foregroundColor(.secondary)
                        }
                    }
                    Button {
                        UIApplication.shared.open(KachatNamesInfo.pageURL)
                    } label: {
                        Label("Get a .kachat name", systemImage: "at")
                    }
                } header: {
                    Text(".kachat Name")
                } footer: {
                    if KachatNamesService.isLaunched {
                        Text("KaChat shows you by your primary name while you own it and it's active; otherwise by your oldest active name, or your address.")
                    } else {
                        Text(".kachat names aren't on mainnet yet. Your avatar, banner, bio and links save now; you can pick a primary name once names launch.")
                    }
                }
                Section {
                    Button {
                        showSave = true
                    } label: {
                        HStack { Spacer(); Text("Save Profile").font(.headline); Spacer() }
                    }
                    // Saves on every network: a profile is a self-send, with no registry behind it.
                    .disabled(!loaded || blocked || !KachatNamesService.profilesEnabled)
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if hasUncheckedLinks {
                            Text("Some links couldn't be checked from this phone right now. They're saved as entered, and people's apps load them when they can.")
                        }
                        Text("Saving writes your profile to the chain from your address to itself, for a network fee. Profiles are public.")
                    }
                }
                Section {
                    Button(role: .destructive) {
                        showClear = true
                    } label: {
                        HStack { Spacer(); Text("Clear Profile").font(.headline); Spacer() }
                    }
                    // Same gate as saving: a clear IS a save, of the empty record.
                    .disabled(!loaded || !KachatNamesService.profilesEnabled)
                } footer: {
                    Text("Clearing writes an empty profile to the chain from your address to itself, for a network fee, so KaChat shows nothing for your address again.")
                }
            }
            .sheet(isPresented: $showSave) {
                KachatProfileSaveSheet(title: "Save Profile", confirmTitle: "Save Profile", doneTitle: "Profile saved",
                                       makeProfile: { profile }, onSaved: { dismiss() })
            }
            // The newest record is the whole profile, so the empty record IS "this address has
            // nothing": the indexer and every app show nothing for it from then on.
            .sheet(isPresented: $showClear) {
                KachatProfileSaveSheet(title: "Clear Profile", confirmTitle: "Clear Profile", doneTitle: "Profile cleared",
                                       makeProfile: { KachatNames.Profile() }, onSaved: { dismiss() })
            }
            .onChange(of: avatarLookup) { v in if v == .found { fillEmpty(from: avatarIn) } }
            .onChange(of: bannerLookup) { v in if v == .found { fillEmpty(from: bannerIn) } }
            .onChange(of: bioLookup) { v in if v == .found { fillEmpty(from: bioIn) } }
            .navigationTitle("Edit KaChat Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    private var invalidHandleNote: some View {
        Text("That doesn't look like a handle on this platform.").foregroundColor(.red)
    }

    private func load() async {
        guard let address = KachatNamesActions.shared.myAddress else { loaded = true; return }
        await registry.refreshIfStale()
        // start from the newest profile, wherever it was saved (another device included)
        await registry.syncOwnProfile(address: address)
        var p = registry.ownProfile(for: address)?.profile
        if p == nil { p = try? await registry.identity(address: address).profile }
        if let p {
            avatarIn = KachatSourceInput(stored: p.avatar, .avatar)
            bannerIn = KachatSourceInput(stored: p.banner, .banner)
            bioIn = KachatSourceInput(stored: p.bio, .bio)
            linktree = KachatNames.Profile.linktreeUsername(p.linktree)
        }
        if let key = KachatNamesRegistry.keyOf(address) {
            // a failed read isn't "no names": saving would drop the primary name
            if let held = try? await registry.names(owner: key, includeInactive: false) { activeNames = held.map(\.name) }
        }
        if let pn = p?.primaryName, activeNames.contains(pn) { primary = pn }
        loaded = true
    }

}

/// Review before a profile record goes out - what will be saved, the network fee, the main
/// address's balance before and after - the same confirmation every other name action shows.
/// Used by Edit KaChat Profile and by Set as Primary.
struct KachatProfileSaveSheet: View {
    let title: LocalizedStringKey
    let confirmTitle: LocalizedStringKey
    /// The finished-transaction half sheet's headline (a localization key).
    let doneTitle: String
    /// Builds the record to save when the sheet opens (Set as Primary reads your current profile).
    let makeProfile: () async -> KachatNames.Profile
    var onSaved: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var profile: KachatNames.Profile?
    @State private var fee: UInt64?
    @State private var quoteError: String?
    @State private var sending = false
    @State private var sendError: String?
    @State private var done: KachatTxDone?
    /// The "not enough funds" popup: the chatting address's QR to fund it. It opens by itself
    /// once per sheet; after that the Fund button under the message opens it (IOS-084).
    @State private var showFunding = false
    @State private var fundingShownOnce = false
    /// The last quote or save failed for lack of funds: the Fund button shows.
    @State private var shortOfFunds = false
    @AppStorage("kachat_profile_privacy_seen") private var privacySeen = false

    private static var notEnoughFundsMessage: String {
        KaspaUnit.label(AppLocalization.string("You don't have enough funds. Please send at least 1 KAS to your chatting address."))
    }

    /// The save can't be paid: the chatting address has no spendable coin, or too little for
    /// the fee - read from the error alone (an unreachable node is not "no funds").
    private func isShortOfFunds(_ error: Error) -> Bool {
        if case let KasiaError.networkError(message) = error, message.localizedCaseInsensitiveContains("insufficient") {
            return true
        }
        return false
    }

    /// Short of funds: the popup the first time, the Fund button after that.
    private func noteShortOfFunds() {
        shortOfFunds = true
        if !fundingShownOnce {
            fundingShownOnce = true
            showFunding = true
        }
    }

    private func source(_ link: String?, _ kind: KachatNames.SocialSource.Kind) -> String {
        guard let s = KachatNames.SocialSource(link: link ?? "", for: kind) else { return AppLocalization.string("None") }
        return "\(s.platform.displayName) · \(s.platform.prefix)\(s.displayHandle)"
    }

    var body: some View {
        NavigationStack {
            Form {
                if let profile {
                    Section {
                        LabeledRow(title: "Avatar", value: source(profile.avatar, .avatar))
                        LabeledRow(title: "Banner", value: source(profile.banner, .banner))
                        LabeledRow(title: "Bio", value: source(profile.bio, .bio))
                        LabeledRow(title: "Linktree", value: profile.linktree.map { $0.replacingOccurrences(of: "https://", with: "") } ?? AppLocalization.string("None"))
                        LabeledRow(title: "Primary name", value: profile.primaryName.map(KachatNameLabel.display) ?? AppLocalization.string("None"))
                    } header: {
                        Text("Your Profile")
                    }
                }
                Section {
                    if let fee {
                        LabeledRow(title: "Network fee", value: KaspaUnit.amount(fee))
                        if let balance = WalletManager.shared.currentWallet?.balanceSompi {
                            LabeledRow(title: "Chatting address balance", value: KaspaUnit.amount(balance))
                            LabeledRow(title: "Balance after", value: KaspaUnit.amount(balance > fee ? balance - fee : 0), bold: true)
                        }
                    } else if quoteError == nil {
                        HStack { Text("Network fee"); Spacer(); ProgressView() }
                    }
                } footer: {
                    if let quoteError {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(verbatim: quoteError).foregroundColor(.red)
                            if shortOfFunds {
                                Button {
                                    showFunding = true
                                } label: {
                                    Label("Fund", systemImage: "qrcode")
                                        .font(.subheadline.weight(.semibold))
                                }
                            }
                        }
                    } else if privacySeen {
                        Text("Saved on chain from your chatting address to itself.")
                    } else {
                        Text("Profiles are public and on chain: anyone can read them, and earlier versions stay readable after you change them.")
                    }
                }
                Section {
                    Button {
                        authorize()
                    } label: {
                        HStack { Spacer(); if sending { ProgressView() } else { Text(confirmTitle).font(.headline) }; Spacer() }
                    }
                    .disabled(fee == nil || profile == nil || sending || done != nil)
                } footer: {
                    if let sendError {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(verbatim: sendError).foregroundColor(.red)
                            if shortOfFunds {
                                Button {
                                    showFunding = true
                                } label: {
                                    Label("Fund", systemImage: "qrcode")
                                        .font(.subheadline.weight(.semibold))
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .task { await quote() }
            .sheet(item: $done, onDismiss: { dismiss(); onSaved() }) { KachatTxDoneSheet(done: $0) }
            // Closes by itself once 1 KAS has arrived; either way the fee is worked out again.
            .sheet(isPresented: $showFunding, onDismiss: {
                quoteError = nil
                sendError = nil
                fee = nil
                Task { await quote() }
            }) {
                // closes once any KAS arrives; the fee is then worked out again
                ZeroBalanceFundingSheetView(title: Self.notEnoughFundsMessage)
            }
        }
    }

    private func quote() async {
        let p = await makeProfile()
        profile = p
        do {
            fee = try await KachatNamesActions.shared.profileFee(p)
            shortOfFunds = false
        } catch {
            if isShortOfFunds(error) {
                quoteError = Self.notEnoughFundsMessage
                noteShortOfFunds()
            } else {
                quoteError = error.localizedDescription
            }
        }
    }

    private func authorize() {
        guard let profile else { return }
        DeviceAuth.authenticate(reason: KachatLive.authReason) {
            Task { @MainActor in
                sending = true
                sendError = nil
                do {
                    let tx = try await KachatNamesActions.shared.saveProfile(profile)
                    privacySeen = true
                    done = KachatTxDone(txId: tx, title: doneTitle)
                    Haptics.success()
                } catch {
                    if isShortOfFunds(error) {
                        sendError = Self.notEnoughFundsMessage
                        noteShortOfFunds()
                    } else {
                        sendError = error.localizedDescription
                    }
                }
                sending = false
            }
        }
    }
}
