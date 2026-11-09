import SwiftUI
import UIKit

struct KNSSetPrimaryMessage: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let isError: Bool
}


struct KNSDomainsListView: View {
    let walletAddress: String
    let domains: [KNSDomain]
    let primaryDomain: String?
    let settingPrimaryDomainId: String?
    /// Set only when a "Set as Primary" attempt FAILED, so the detail screen can say so in place.
    /// Success needs no message: the star moves to the new primary as soon as the write lands.
    @Binding var setPrimaryError: KNSSetPrimaryMessage?
    let onSetPrimary: (KNSDomain) -> Void
    let onInscribeComplete: (KNSDomainInscribeResult) -> Void
    let onTransferComplete: (KNSDomainTransferResult) -> Void
    let onRefresh: () async -> Void
    var onCustomizeProfile: ((KNSDomain) -> Void)? = nil

    @ObservedObject private var nameServices = NameServicesClient.shared
    @ObservedObject private var kachatRegistry = KachatNamesRegistry.shared
    /// How many .kachat names this wallet holds, counted the same way the .kachat screen lists
    /// them. nil until the first count lands (the card shows a dash, not a made-up 0).
    @State private var kachatCount: Int?

    var body: some View {
        // One square card per name ending, KaChat's own first: .kachat, KNS (.kas), dotk (.k),
        // Kaspa Names (.kaspa) - one square tile each. Each card pushes that
        // service's own screen (these used to be tabs on this screen).
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                ForEach(NameServiceTLD.allCases) { tld in
                    NavigationLink {
                        domainsScreen(tld)
                    } label: {
                        serviceCard(tld)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .task(id: walletAddress) {
            await nameServices.refresh(for: walletAddress)
        }
        // Counts again whenever the registry moves (a name inscribed, bought, transferred or
        // lapsed behind a card shows on this screen the moment you come back to it).
        .task(id: kachatRegistry.revision) {
            await refreshKachatCount()
        }
        .navigationTitle("Your Domains")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// How many names this wallet has with each service - every card says so, 0 included.
    /// nil while the answer is not in yet (first load, or the service unreachable).
    private func ownedCount(_ tld: NameServiceTLD) -> Int? {
        switch tld {
        case .kas:
            return domains.count
        case .k, .kaspa:
            return nameServices.owned[tld]?.count
        case .kachat:
            return kachatCount
        }
    }

    /// The same read KachatLiveDomainsTab's load() does, reduced to a count: the whole wallet's
    /// held names for the own chatting address, the one address's otherwise.
    private func refreshKachatCount() async {
        guard KachatNamesService.isEnabled, KachatNamesService.isLaunched else {
            kachatCount = 0
            return
        }
        // the saved list's count at once; the reads below correct it when they answer
        if kachatCount == nil, let cached = KachatOwnedNamesCache.load(walletAddress) {
            kachatCount = cached.names.count
        }
        if kachatRegistry.refreshedAt == nil { await kachatRegistry.refresh() }
        if walletAddress.lowercased() == KachatNamesActions.shared.myAddress,
           let own = try? await KachatNamesActions.shared.ownNamesAndOffers(heldOnly: true) {
            kachatCount = own.names.count
        } else if let key = KachatNamesRegistry.keyOf(walletAddress) {
            kachatCount = (try? await kachatRegistry.heldNames(owner: key))?.count
        } else {
            kachatCount = 0
        }
    }

    /// The screen behind a card: the same per-service list each tab used to show.
    @ViewBuilder
    private func domainsScreen(_ tld: NameServiceTLD) -> some View {
        Group {
            switch tld {
            case .kas:
                knsDomainList
            case .k, .kaspa:
                serviceNameList(tld)
            case .kachat:
                // Live on both networks (testnet-10, and mainnet since 2026-10-09).
                if KachatNamesService.isEnabled {
                    KachatLiveDomainsTab(walletAddress: walletAddress)
                } else {
                    kachatComingSoon
                }
            }
        }
        .navigationTitle(tld.suffix)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// A square tile: the name ending big in the brand style, who runs it under it.
    private func serviceCard(_ tld: NameServiceTLD) -> some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay {
                VStack(spacing: 8) {
                    Text(verbatim: tld.suffix)
                        .font(.system(.title2, design: .rounded).weight(.heavy))
                        .foregroundStyle(Color.accentColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(verbatim: tld.serviceName)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    // How many you have there, 0 included; a dash until the answer is in.
                    Text(verbatim: ownedCount(tld).map(String.init) ?? "\u{2013}")
                        .font(.caption.weight(.bold))
                        .foregroundColor(.accentColor)
                        .padding(.horizontal, 10)
                        .frame(minWidth: 28, minHeight: 22)
                        .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                        .padding(.top, 2)
                }
                .padding(.horizontal, 8)
            }
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.white.opacity(0.15), lineWidth: 0.8)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    /// "Get a .kas domain at knsdomains.org" - the pinned button under each outside service's
    /// tab, opening that service's own site. KaChat creates only its own `.kachat` names; the
    /// other services' names are registered with them. Same glass capsule with a teal outline
    /// the in-app Inscribe button had (not the accent fill: the cards above are accent-filled).
    @ViewBuilder
    private func getNameButton(_ tld: NameServiceTLD) -> some View {
        if let url = tld.websiteURL, let site = tld.websiteName {
            Link(destination: url) {
                Text("Get a \(tld.suffix) domain at \(site)")
                    .font(.subheadline)
                    .fontWeight(.bold)
                    .foregroundColor(.accentColor)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Capsule().fill(.regularMaterial))
                    .overlay(Capsule().stroke(Color.accentColor, lineWidth: 1.5))
            }
            .padding(.horizontal)
            .padding(.bottom, 16)
        }
    }

    // MARK: .kas (KNS)

    private var knsDomainList: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                if domains.isEmpty {
                    Text("No domains yet.")
                        .foregroundColor(.secondary)
                        .padding(16)
                } else {
                    ForEach(domains, id: \.inscriptionId) { domain in
                        let isPrimary = isPrimaryDomain(domain.fullName)
                        NavigationLink {
                            KNSDomainDetailView(
                                domain: domain,
                                isPrimary: isPrimary,
                                isSetPrimaryAllowed: isSetPrimaryAllowed(domain, isPrimary: isPrimary),
                                isTransferAllowed: isDomainTransferAllowed(domain),
                                settingPrimaryDomainId: settingPrimaryDomainId,
                                setPrimaryError: setPrimaryError?.isError == true ? setPrimaryError?.text : nil,
                                onSetPrimary: onSetPrimary,
                                onTransferComplete: onTransferComplete,
                                onCustomizeProfile: onCustomizeProfile
                            )
                        } label: {
                            KNSDomainCard(domain: domain, isPrimary: isPrimary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding()
        }
        .refreshable {
            await onRefresh()
        }
        .safeAreaInset(edge: .bottom) {
            getNameButton(.kas)
        }
    }

    // MARK: .k and .kaspa

    @ViewBuilder
    private func serviceNameList(_ tld: NameServiceTLD) -> some View {
        let names = nameServices.owned[tld] ?? []
        ScrollView {
            LazyVStack(spacing: 16) {
                if names.isEmpty {
                    VStack(spacing: 10) {
                        if nameServices.loading.contains(tld) && nameServices.owned[tld] == nil {
                            ProgressView()
                        } else if nameServices.failed.contains(tld) {
                            Text("Couldn't reach \(tld.serviceName). Pull down to try again.")
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        } else {
                            Text("No \(tld.suffix) names yet.")
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                } else {
                    ForEach(names) { owned in
                        DomainNameCardView(
                            title: owned.display,
                            badge: owned.isProvisional ? String(localized: "Settling") : nil
                        )
                    }
                }
            }
            .padding()
        }
        .refreshable {
            await nameServices.refresh(for: walletAddress)
        }
        .safeAreaInset(edge: .bottom) {
            getNameButton(tld)
        }
    }

    // MARK: .kachat

    private var kachatComingSoon: some View {
        ScrollView {
            VStack(spacing: 12) {
                Image(systemName: "at.circle")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundColor(.accentColor)
                Text(".kachat names are coming")
                    .font(.headline)
                Text("KaChat's own names will live here: claim one, make it your name, and share it as your profile link.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 40)
        }
    }

    private func isPrimaryDomain(_ domainName: String) -> Bool {
        let normalizedDomain = domainName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedPrimary = (primaryDomain ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedDomain == normalizedPrimary
    }

    private func isSetPrimaryAllowed(_ domain: KNSDomain, isPrimary: Bool) -> Bool {
        let hasAssetId = !domain.inscriptionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasAssetId && !isPrimary
    }

    private func isDomainTransferAllowed(_ domain: KNSDomain) -> Bool {
        let status = domain.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hasAssetId = !domain.inscriptionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasAssetId && status != "listed"
    }
}

/// Teal card matching the app's KNS domain branding - used both as the row style in
/// KNSDomainsListView and as the header of KNSDomainDetailView.
struct KNSDomainDetailView: View {
    let domain: KNSDomain
    let isPrimary: Bool
    let isSetPrimaryAllowed: Bool
    let isTransferAllowed: Bool
    let settingPrimaryDomainId: String?
    /// Why the last "Set as Primary" tap failed, shown inline under the row. Nil when it
    /// succeeded or has not been tried - a success shows itself, since the star moves.
    var setPrimaryError: String? = nil
    let onSetPrimary: (KNSDomain) -> Void
    let onTransferComplete: (KNSDomainTransferResult) -> Void
    /// Opens the full profile editor for this domain (avatar, banner, bio, links). KaChat does
    /// not SHOW .kas profiles anymore - .kachat profiles take priority - but a .kas domain's own
    /// profile can still be customized here. Nil where the host offers no editor.
    var onCustomizeProfile: ((KNSDomain) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var showSendSheet = false

    private var isListed: Bool {
        domain.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "listed"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                KNSDomainCard(domain: domain, isPrimary: isPrimary)
                    .padding(.top, 12)

                VStack(spacing: 0) {
                    HStack {
                        Text("Asset ID")
                            .foregroundColor(.primary)
                        Spacer()
                        Text(domain.inscriptionId)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(16)

                    if let onCustomizeProfile {
                        Divider().padding(.leading, 16)
                        Button {
                            onCustomizeProfile(domain)
                        } label: {
                            HStack {
                                Text("Customize Profile")
                                    .foregroundColor(.primary)
                                Spacer()
                                Image(systemName: "person.crop.circle")
                                    .foregroundColor(.accentColor)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(16)
                    }

                    if isPrimary {
                        Divider().padding(.leading, 16)
                        HStack {
                            Text("Primary Domain")
                                .foregroundColor(.primary)
                            Spacer()
                            Image(systemName: "star.fill")
                                .foregroundColor(.accentColor)
                        }
                        .padding(16)
                    } else if isSetPrimaryAllowed {
                        Divider().padding(.leading, 16)
                        Button {
                            onSetPrimary(domain)
                        } label: {
                            HStack {
                                Text("Set as Primary")
                                    .foregroundColor(.primary)
                                Spacer()
                                if settingPrimaryDomainId == domain.inscriptionId {
                                    ProgressView().scaleEffect(0.75)
                                } else {
                                    Image(systemName: "star")
                                        .foregroundColor(.accentColor)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(settingPrimaryDomainId != nil)
                        .padding(16)

                        if let setPrimaryError, settingPrimaryDomainId == nil {
                            // In place rather than as a popup. A failure has to be visible
                            // somewhere: the operation is owned by the Profile screen, and the
                            // toast it raises is drawn behind this sheet where nobody sees it.
                            Text(setPrimaryError)
                                .font(.caption)
                                .foregroundColor(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .padding(.bottom, 16)
                        }
                    }

                    if isListed {
                        Divider().padding(.leading, 16)
                        HStack {
                            Text("Status")
                                .foregroundColor(.primary)
                            Spacer()
                            Text("Listed")
                                .foregroundColor(.secondary)
                        }
                        .padding(16)
                    }
                }
                .background(glassBackground(cornerRadius: 18))
            }
            .padding()
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                showSendSheet = true
            } label: {
                Label("Send", systemImage: "arrow.up.circle.fill")
                    .font(.subheadline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .foregroundColor(.black)
                    .background(Capsule().fill(Color.accentColor))
            }
            .disabled(!isTransferAllowed)
            .opacity(isTransferAllowed ? 1 : 0.5)
            .padding(.horizontal)
            .padding(.bottom, 16)
        }
        .navigationTitle(domain.fullName)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showSendSheet) {
            KNSDomainSendView(domain: domain) { result in
                showSendSheet = false
                onTransferComplete(result)
                dismiss()
            }
        }
    }

    private func glassBackground(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.regularMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
            )
            .shadow(color: Color.black.opacity(0.12), radius: 10, x: 0, y: 5)
    }
}

/// Sends (transfers) a single KNS domain inscription to a recipient address or KNS domain -
/// same UX conventions as the app's KAS send flows (KNS-domain-aware recipient, editable
/// network fee) but with no amount field or coin control, since a domain transfer moves the
/// whole inscription rather than a chosen KAS amount. Not `private`: ManageAddressesView's
/// per-spending-address "KNS Domains" tab reuses this exact sheet, passing
/// `spendingAddressIndex` so the transfer is owned/funded/signed by that spending address's
/// derived key instead of the identity/chatting address.
struct KNSDomainSendView: View {
    let domain: KNSDomain
    /// When non-nil, the domain lives on this spending-chain address index and the transfer
    /// spends/signs from that address's own derivation (see KNSDomainTransferService).
    var spendingAddressIndex: Int? = nil
    let onComplete: (KNSDomainTransferResult) -> Void

    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var addressInput = ""
    @State private var isValidAddress = false
    @State private var showQRScanner = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var result: KNSDomainTransferResult?
    /// The transfer got no answer (`SendOutcomeUnknownError`): it may have gone through, so the
    /// screen offers only Done.
    @State private var outcomeUnknown = false
    /// Where the transfer has got to. A commit, a wait, then a reveal is most of a minute, and a
    /// toolbar spinner through all of it is indistinguishable from being stuck.
    @State private var transferStage: KNSDomainTransferService.TransferStage?

    @State private var isResolvingKNS = false
    @State private var resolvedAddress: String?
    @State private var resolvedDomain: String?
    /// Every service's answer for a typed name and the one in use: the rest go under "Other domains".
    @State private var nameResolutions: [NameResolution] = []
    @State private var selectedTLD: NameServiceTLD?
    @State private var knsError: String?
    private let knsService = KNSService.shared

    @State private var feeTier: WithdrawFeeTier = .normal
    @State private var customFeeSompi: UInt64?
    @State private var isEditingFee = false
    @State private var customFeeText = ""

    private let baseFeeSompi: UInt64 = 2_000_000

    /// The actual address to use (resolved from a KNS domain, or the direct input) - same
    /// precedence as WithdrawKaspaView.effectiveAddress.
    private var effectiveAddress: String {
        resolvedAddress ?? addressInput
    }

    private var hasValidRecipient: Bool {
        if resolvedAddress != nil { return true }
        return isValidAddress && !isResolvingKNS
    }

    private var priorityFeeSompi: UInt64 {
        if let customFeeSompi { return customFeeSompi }
        return baseFeeSompi * feeTier.multiplier
    }

    private var canSend: Bool {
        hasValidRecipient && !isSubmitting
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Domain") {
                    Text(domain.fullName)
                        .fontWeight(.semibold)
                    Text(domain.inscriptionId)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Section {
                    TextField("kaspa:qr... or domain", text: $addressInput)
                        .font(.system(.body, design: .monospaced))
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .onChange(of: addressInput) { handleInputChange($0) }

                        AddressResolutionCard(address: resolvedAddress ?? (isValidAddress ? addressInput.trimmingCharacters(in: .whitespacesAndNewlines) : nil), domain: resolvedDomain)

                    if !addressInput.isEmpty {
                        if isResolvingKNS {
                            HStack {
                                ProgressView().scaleEffect(0.8)
                                Text("Looking up domain...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } else if let knsError {
                            HStack {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.red)
                                Text(knsError)
                                    .font(.caption)
                                    .foregroundColor(.red)
                            }
                        } else if let resolvedAddress {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                    Text("Resolved: \(resolvedDomain ?? "")")
                                        .font(.caption)
                                        .foregroundColor(.green)
                                }
                                Text(resolvedAddress)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        } else {
                            HStack {
                                Image(systemName: isValidAddress ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundColor(isValidAddress ? .green : .red)
                                Text(verbatim: KaspaAddress.validityText(addressInput, isValid: isValidAddress))
                                    .font(.caption)
                                    .foregroundColor(isValidAddress ? .green : .red)
                            }
                        }
                        if !isResolvingKNS {
                            OtherDomainsDropdown(resolutions: nameResolutions, selected: selectedTLD, onSelect: selectResolution)
                        }
                    }

                    HStack {
                        Button {
                            if let pasted = UIPasteboard.general.string {
                                addressInput = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                                handleInputChange(addressInput)
                            }
                        } label: {
                            Label("Paste", systemImage: "doc.on.clipboard")
                        }
                        Spacer()
                        Button {
                            showQRScanner = true
                        } label: {
                            Label("Scan QR", systemImage: "qrcode.viewfinder")
                        }
                    }
                    .buttonStyle(.borderless)
                } header: {
                    Text("Recipient Address")
                } footer: {
                    Text("Enter a Kaspa address (kaspa:...) or a domain. .kachat names are looked up first.")
                }

                Section {
                    Picker("Fee", selection: $feeTier) {
                        ForEach(WithdrawFeeTier.allCases) { tier in
                            Text(tier.rawValue).tag(tier)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: feeTier) { _ in
                        customFeeSompi = nil
                        isEditingFee = false
                    }

                    HStack {
                        Text("Network Fee")
                        Spacer()
                        if isEditingFee {
                            TextField("0.00", text: $customFeeText)
                                .keyboardType(.decimalPad)
                                .numericKeyboardDoneButton()
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 100)
                                .onSubmit { commitCustomFee() }
                            Button {
                                commitCustomFee()
                            } label: {
                                Image(systemName: "checkmark.circle.fill")
                            }
                            .buttonStyle(.borderless)
                        } else {
                            Button {
                                startEditingFee()
                            } label: {
                                HStack(spacing: 4) {
                                    Text(verbatim: "\(trimmedKas(priorityFeeSompi)) \(KaspaUnit.symbol)")
                                        .underline()
                                    Image(systemName: "pencil")
                                        .font(.caption2)
                                }
                                .foregroundColor(.accentColor)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    Text("Fee")
                } footer: {
                    Text("If the network is busy, Fast or Priority pays a higher fee to help your transfer confirm sooner. Tap the fee amount to set a custom fee.")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("Send Domain")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if !outcomeUnknown {
                        Button("Cancel") { dismiss() }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if outcomeUnknown {
                        // It may have gone through: sending again could spend twice.
                        Button("Done") { dismiss() }
                    } else if isSubmitting {
                        ProgressView()
                    } else {
                        Button("Send") {
                            // Giving a domain away can't be undone, so the phone's lock comes first,
                            // whatever the settings say. Declining leaves the form as it was.
                            DeviceAuth.authenticate(reason: AppLocalization.string("Confirm sending this domain"), onSuccess: {
                                send()
                            })
                        }
                        .disabled(!canSend)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .sheet(isPresented: $showQRScanner) {
                QRScannerView { code in
                    handleScannedQRCode(code)
                }
            }
            // Progress lives in its own sheet rather than a toolbar spinner: the transfer takes
            // long enough that the user needs to be told it is still working, and dismissal is
            // disabled because leaving mid-transfer would hide a running on-chain operation.
            .sheet(isPresented: Binding(
                get: { transferStage != nil },
                set: { if !$0 { transferStage = nil } }
            )) {
                domainTransferProgressSheet
            }
            .sheet(item: Binding(
                get: { result.map { SentTransaction(txId: $0.revealTxId) } },
                set: { if $0 == nil { result = nil } }
            )) { sent in
                SentConfirmationSheet(transaction: sent) {
                    if let result { onComplete(result) }
                    dismiss()
                }
                .presentationDetents([.height(sent.sheetHeight)])
                .presentationDragIndicator(.visible)
            }
        }
    }

    private func handleInputChange(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

        resolvedAddress = nil
        resolvedDomain = nil
        knsError = nil
        isResolvingKNS = false
        nameResolutions = []
        selectedTLD = nil

        guard !trimmed.isEmpty else {
            isValidAddress = false
            return
        }

        if trimmed.hasPrefix("kaspa:") || trimmed.hasPrefix("kaspatest:") {
            isValidAddress = KaspaAddress.isValidOnActiveNetwork(trimmed)
            return
        }

        if NameServicesClient.looksLikeName(trimmed) {
            isValidAddress = false
            resolveKNSDomain(trimmed)
        } else {
            isValidAddress = false
        }
    }

    /// Use one service's answer (the priority one, or a pick from "Other domains").
    private func selectResolution(_ resolution: NameResolution) {
        guard let address = resolution.address else { return }
        resolvedAddress = address
        resolvedDomain = resolution.display
        selectedTLD = resolution.tld
        knsError = nil
    }

    private func resolveKNSDomain(_ domain: String) {
        isResolvingKNS = true

        // On the main actor: the check below must read the field as it is now. Read from a
        // background task while typing fast, it could see an older value, take this lookup for a
        // stale one and stop - leaving "Looking up domain..." up for good.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)

            guard addressInput.trimmingCharacters(in: .whitespacesAndNewlines) == domain ||
                  addressInput.trimmingCharacters(in: .whitespacesAndNewlines) + ".kas" == domain + ".kas" else {
                return
            }

            // Every name service, in priority: the ending typed, else .kachat only (the others wait under Other domains)
            // (see NameServicesClient). The resolved line names which one answered; the others
            // are offered under "Other domains".
            let results = await NameServicesClient.shared.resolveEverywhere(domain)
            await MainActor.run {
                guard addressInput.trimmingCharacters(in: .whitespacesAndNewlines) == domain else { return }
                nameResolutions = results
                isResolvingKNS = false
                if let resolution = NameServicesClient.primary(of: results, typed: domain), resolution.address != nil {
                    selectResolution(resolution)
                } else {
                    resolvedAddress = nil
                    resolvedDomain = nil
                    selectedTLD = nil
                    knsError = NameServicesClient.notFoundMessage(typed: domain, results: results)
                }
            }
        }
    }

    private func handleScannedQRCode(_ code: String) {
        var address = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if address.lowercased().hasPrefix("kaspa:") || address.lowercased().hasPrefix("kaspatest:") {
            if let queryIndex = address.firstIndex(of: "?") {
                address = String(address[..<queryIndex])
            }
        }
        addressInput = address
        handleInputChange(address)
    }

    private func startEditingFee() {
        customFeeText = trimmedKas(priorityFeeSompi)
        isEditingFee = true
    }

    private func commitCustomFee() {
        defer { isEditingFee = false }
        guard let sompi = KaspaUnit.sompi(fromUserText: customFeeText) else { return }
        customFeeSompi = sompi
    }

    private func send() {
        isSubmitting = true
        transferStage = .preparing
        errorMessage = nil
        let recipient = effectiveAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let fee = priorityFeeSompi
        Task {
            do {
                let transferResult = try await KNSDomainTransferService.shared.transferDomain(
                    domain: domain.fullName,
                    assetId: domain.inscriptionId,
                    to: recipient,
                    priorityFeeSompi: fee,
                    fromSpendingAddressIndex: spendingAddressIndex,
                    onProgress: { stage in transferStage = stage }
                )
                await MainActor.run {
                    isSubmitting = false
                    transferStage = nil
                    result = transferResult
                }
            } catch {
                await MainActor.run {
                    isSubmitting = false
                    transferStage = nil
                    errorMessage = UserFacingError.message(for: error)
                    if error is SendOutcomeUnknownError { outcomeUnknown = true }
                    Haptics.impact(.medium)
                }
            }
        }
    }

    @ViewBuilder
    private var domainTransferProgressSheet: some View {
        let stage = transferStage ?? .preparing
        VStack(spacing: 16) {
            Text("Sending \(domain.fullName)")
                .font(.headline)
                .multilineTextAlignment(.center)
                .padding(.top, 24)

            ProgressView(value: stage.fraction)
                .progressViewStyle(.linear)
                .tint(.accentColor)

            Text(LocalizedStringKey(stage.title))
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.center)

            Text("A domain transfer is two transactions, so this takes a moment. Keep the app open until it finishes.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
        .presentationDetents([.height(260)])
        .interactiveDismissDisabled(true)
    }

    private func trimmedKas(_ sompi: UInt64) -> String {
        var text = String(format: "%.8f", Double(sompi) / 100_000_000.0)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}

/// Transaction history for the chatting (identity) address, reached from its dropdown in
/// Profile. Same pattern as ManageAddressesView's SpendingAddressTransactionHistoryView: tapping
/// a transaction opens it directly on whichever block explorer is selected in Settings >
/// Connection > Kaspa Explorer, rather than showing an in-app detail screen.
/// Full-featured detail screen for the wallet's own chatting (identity) address — field-for-field
/// the same screen as ManageAddressesView's SpendingAddressTransactionHistoryView (balance,
/// Transaction History/UTXOs tabs, Compound UTXOs, Export private key, Explorer, Receive/Send),
/// just address-based instead of index-based. Reached from the Profile screen's Chatting Address
/// section's "Manage Address" row.
struct ProfileHelpView: View {
    let onKNSSetupGuide: () -> Void


    var body: some View {
        List {
            Section {
                helpRow(
                    icon: "person.text.rectangle",
                    title: ".kachat Names Guide",
                    subtitle: "Claim a .kachat name, make it your name, and keep it."
                ) {
                    onKNSSetupGuide()
                }
            }
        }
        .navigationTitle("Help")
        .navigationBarTitleDisplayMode(.large)
    }

    private func helpRow(
        icon: String,
        title: String,
        subtitle: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.scaled(size: 20, weight: .semibold))
                    .foregroundColor(.accentColor)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(LocalizedStringKey(title))
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                    Text(LocalizedStringKey(subtitle))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}


// MARK: - Claim Testnet Kaspa (Profile, testnet only)

/// "Claim Testnet Kaspa", above the addresses card on testnet. The official TN10 faucet sits
/// behind a Cloudflare check, so it can't be claimed from in the background: the button copies
/// the chatting address (`kaspatest:` form) and opens the faucet in the in-app browser, with a
/// strip saying it's copied, where you paste it, pass the
/// check and claim the most it offers. The faucet allows one claim a day, so once the address's
/// balance goes up after a visit the button locks for 24 hours (kept per address).

/// KaPay's Wallet tab below Send and Receive, on KaPost's Wallet: the Manage Addresses and
/// Chatting Address squares, then Your Domains and Help. Every app has KaPay's full wallet
/// (owner's call, 2026-11-07), except Contacts, which lives in KaChat and KaPay (owner's call, the
/// same day). A profile is edited on KaPost's own Profile, so the domains list has no Customize
/// Profile here.
struct WalletAccountSections: View {
    let wallet: Wallet
    /// For a toast on the Wallet screen.
    let onMessage: (String) -> Void

    @EnvironmentObject private var walletManager: WalletManager
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @ObservedObject private var nameServices = NameServicesClient.shared
    @ObservedObject private var kachatRegistry = KachatNamesRegistry.shared

    @State private var knsDomains: [KNSDomain] = []
    @State private var knsPrimaryDomain: String?
    @State private var kachatOwnedCount = 0
    @State private var settingPrimaryDomainId: String?
    @State private var setPrimaryMessage: KNSSetPrimaryMessage?
    @State private var showKachatSetupGuide = false

    var body: some View {
        VStack(spacing: 16) {
            addressSquares
            yourDomainsRow
            linkRow(title: "Help", icon: "questionmark.circle") {
                ProfileHelpView(onKNSSetupGuide: { showKachatSetupGuide = true })
            }
        }
        .task(id: wallet.publicAddress) {
            let kns = KNSService.shared
            if let cached = kns.domainCache[wallet.publicAddress] {
                knsDomains = cached.allDomains
                knsPrimaryDomain = cached.primaryDomain
            }
            // Cache-first: only reaches the network when the entry is missing or stale.
            if let info = await kns.fetchInfo(for: wallet.publicAddress) {
                knsDomains = info.allDomains
                knsPrimaryDomain = info.primaryDomain
            }
        }
        .sheet(isPresented: $showKachatSetupGuide) {
            KachatSetupGuideView { showKachatSetupGuide = false }
        }
    }

    // MARK: Address squares

    private var addressSquares: some View {
        HStack(spacing: 14) {
            NavigationLink {
                ManageAddressesView()
            } label: {
                addressSquare(icon: "list.bullet.rectangle", title: "Manage Addresses")
            }
            .buttonStyle(.plain)
            NavigationLink {
                ChattingAddressQRView(address: wallet.publicAddress, balanceSompi: wallet.balanceSompi)
            } label: {
                addressSquare(icon: "qrcode", title: "Chatting Address")
            }
            .buttonStyle(.plain)
        }
    }

    /// Square on a phone. As wide as half an iPad, a square would fill most of the screen with
    /// nothing, so there it keeps the width and a set height.
    @ViewBuilder
    private var addressSquareShape: some View {
        if horizontalSizeClass == .regular {
            Color.clear.frame(height: 170)
        } else {
            Color.clear.aspectRatio(1, contentMode: .fit)
        }
    }

    private func addressSquare(icon: String, title: LocalizedStringKey) -> some View {
        addressSquareShape
            .frame(maxWidth: .infinity)
            .overlay {
                VStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.scaled(size: 22, weight: .medium))
                        .foregroundColor(.accentColor)
                        .frame(width: 48, height: 48)
                        .background(Circle().fill(.regularMaterial))
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                }
                .padding(.horizontal, 10)
            }
            .background(glassBackground(cornerRadius: 18))
            .contentShape(RoundedRectangle(cornerRadius: 18))
    }

    // MARK: Your Domains

    private var yourDomainsRow: some View {
        let walletAddress = wallet.publicAddress
        return NavigationLink {
            KNSDomainsListView(
                walletAddress: walletAddress,
                domains: knsDomains,
                primaryDomain: knsPrimaryDomain,
                settingPrimaryDomainId: settingPrimaryDomainId,
                setPrimaryError: $setPrimaryMessage,
                onSetPrimary: { domain in
                    // It signs with this account's key and changes the name everyone sees: the
                    // phone's lock comes first. Declining leaves everything as it was.
                    DeviceAuth.authenticate(reason: AppLocalization.string("Confirm setting your primary domain")) {
                        Task { await setPrimaryDomain(domain) }
                    }
                },
                onInscribeComplete: { result in
                    Haptics.success()
                    onMessage(localizedFormat("Inscribe submitted for %@.", result.domain))
                    Task { await refreshKNSDomains(for: walletAddress, force: true) }
                },
                onTransferComplete: { result in
                    Haptics.success()
                    onMessage(result.verified
                        ? localizedFormat("%@ transferred to %@.", result.domain, result.recipientAddress)
                        : localizedFormat("Transfer submitted for %@.", result.domain))
                    Task { await refreshKNSDomains(for: walletAddress, force: true) }
                },
                onRefresh: { await refreshKNSDomains(for: walletAddress, force: false) }
            )
        } label: {
            HStack {
                Label("Your Domains", systemImage: "at")
                    .foregroundColor(.primary)
                Spacer()
                // Every name the account owns: .kachat, KNS, .k and .kaspa.
                Text("\(kachatOwnedCount + knsDomains.count + (nameServices.ownerAddress == walletAddress.lowercased() ? nameServices.totalOwned : 0))")
                    .foregroundColor(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(glassBackground(cornerRadius: 18))
        // The .k and .kaspa lookups, so the count includes them before the list opens.
        .task(id: walletAddress) {
            await NameServicesClient.shared.refresh(for: walletAddress)
        }
        // Reloads whenever the registry moves (a registration, sale or transfer lands).
        .task(id: "\(walletAddress)-\(kachatRegistry.revision)") {
            await loadKachatOwnedCount(walletAddress)
        }
    }

    private func linkRow<Destination: View>(title: LocalizedStringKey, icon: String, @ViewBuilder destination: @escaping () -> Destination) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack {
                Label(title, systemImage: icon)
                    .foregroundColor(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(glassBackground(cornerRadius: 18))
    }

    private func glassBackground(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.regularMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
            )
    }

    // MARK: Loading and writes

    private func loadKachatOwnedCount(_ address: String) async {
        guard KachatNamesService.isLaunched, let key = KachatNamesRegistry.keyOf(address) else {
            kachatOwnedCount = 0
            return
        }
        // the saved list's count at once; the read below corrects it when it answers
        if kachatOwnedCount == 0, let cached = KachatOwnedNamesCache.load(address) {
            kachatOwnedCount = cached.names.count
        }
        await kachatRegistry.refreshIfStale(maxAge: 300)
        // the same names Your Domains lists: a lapsed one isn't yours any more
        guard let names = try? await kachatRegistry.heldNames(owner: key) else { return }
        kachatOwnedCount = names.count
        await kachatRegistry.dropLapsed(from: names) { kachatOwnedCount = $0.count }
    }

    /// `force` after a write (inscribe, transfer, set primary): the indexer has to be asked again.
    private func refreshKNSDomains(for address: String, force: Bool) async {
        guard let info = await KNSService.shared.fetchInfo(for: address, force: force) else { return }
        knsDomains = info.allDomains
        knsPrimaryDomain = info.primaryDomain
    }

    private func setPrimaryDomain(_ domain: KNSDomain) async {
        guard settingPrimaryDomainId == nil else { return }
        let walletAddress = wallet.publicAddress
        let assetId = domain.inscriptionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !assetId.isEmpty else {
            setPrimaryMessage = KNSSetPrimaryMessage(text: AppLocalization.string("KNS domain id is missing."), isError: true)
            return
        }
        settingPrimaryDomainId = assetId
        // Clear any previous failure so a retry does not sit under a stale error.
        setPrimaryMessage = nil
        AppLog.log("[KNS_WRITE_UI] SET_PRIMARY_START domain=%@", domain.fullName)
        do {
            try await submitSetPrimaryDomainWithSignatureFallback(domainId: assetId)
            knsPrimaryDomain = domain.fullName
            // The write has only just been submitted, and one refresh often reads back the old
            // primary: a few rounds, bounded.
            let expected = domain.fullName.lowercased()
            for attempt in 0..<3 {
                if attempt > 0 { try? await Task.sleep(nanoseconds: 2_000_000_000) }
                await refreshKNSDomains(for: walletAddress, force: true)
                if (knsPrimaryDomain ?? "").lowercased() == expected { break }
            }
            settingPrimaryDomainId = nil
            Haptics.success()
            onMessage(localizedFormat("Primary domain set to %@.", domain.fullName))
        } catch {
            AppLog.log("[KNS_WRITE_UI] SET_PRIMARY_FAIL domain=%@ %@", domain.fullName, error.localizedDescription)
            settingPrimaryDomainId = nil
            Haptics.impact(.medium)
            let text = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            setPrimaryMessage = KNSSetPrimaryMessage(text: text.count > 160 ? String(text.prefix(157)) + "..." : text, isError: true)
        }
    }

    /// The same signing fallbacks as KaPay: some KNS deployments verify a different message form.
    private func submitSetPrimaryDomainWithSignatureFallback(domainId: String) async throws {
        let signMessage = try KNSService.shared.buildPrimaryNameSigningMessage(domainId: domainId)
        let signingModes: [WalletManager.ArbitraryMessageSigningMode] = [.kaspaPersonalMessage, .rawUTF8, .sha256Digest]
        var lastError: Error?
        for (index, mode) in signingModes.enumerated() {
            let signature = try walletManager.signArbitraryMessage(signMessage, mode: mode)
            do {
                _ = try await KNSService.shared.setPrimaryDomain(signMessage: signMessage, signature: signature)
                return
            } catch {
                lastError = error
                let message = error.localizedDescription.lowercased()
                let signatureRefused = message.contains("signature verification failed") || message.contains("unauthorized")
                guard index < signingModes.count - 1, signatureRefused else { throw error }
            }
        }
        throw lastError ?? KasiaError.apiError("KNS primary domain update failed")
    }

    private func localizedFormat(_ key: String, _ args: CVarArg...) -> String {
        String(format: AppLocalization.string(key), locale: AppLocalization.locale, arguments: args)
    }
}



/// Resolves a fresh receive address before drawing the QR, so the code on screen is never
/// one that has already appeared on chain.
///
/// A view of its own rather than resolving in the NavigationLink's destination builder: that
/// builder is evaluated eagerly while the row is merely on screen, so any work in it would
/// run whether or not the user ever taps, and it cannot await.
struct ReceiveKaspaQRView: View {
    @EnvironmentObject private var walletManager: WalletManager
    @State private var address: String?
    @State private var resolving = true
    @State private var balanceSompi: UInt64?

    var body: some View {
        Group {
            if let address {
                ChattingAddressQRView(
                    address: address,
                    balanceSompi: balanceSompi,
                    subtitle: "A fresh address, never used before. Kaspa sent here lands in this account and shows in your spending total. Use it for everything except .kachat names."
                )
            } else if resolving {
                ProgressView("Preparing a fresh address")
                    .font(.subheadline)
                    .padding()
            } else {
                Text("Spending address is unlocking — go back and try again.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding()
            }
        }
        .task {
            guard address == nil else { return }
            // Warmed on the Wallet screen's appear - when it is there this screen draws immediately,
            // and the check below is a no-op re-confirmation rather than something the user
            // waits behind.
            let account = walletManager.currentWallet?.publicAddress
            if let warmed = ReceiveAddressWarmCache.address(for: account) {
                address = warmed
                resolving = false
            }
            // shown now: it goes on the Manage Addresses list (and is watched for payments)
            let resolved = await walletManager.freshReceiveAddress(revealing: true)
            // Only swap if the warmed answer went stale between warming and opening. A QR is
            // scanned the instant it appears, so it must not change under a pointed camera
            // for any lesser reason.
            if resolved != address { address = resolved }
            ReceiveAddressWarmCache.store(resolved, for: account)
            resolving = false
            guard let resolved else { return }
            // A failed lookup leaves the balance unknown (nothing shown) rather than 0 KAS.
            if let utxos = try? await NodePoolService.shared.getUtxosByAddresses([resolved]) {
                balanceSompi = utxos.reduce(UInt64(0)) { $0 + $1.amount }
            }
        }
    }
}
