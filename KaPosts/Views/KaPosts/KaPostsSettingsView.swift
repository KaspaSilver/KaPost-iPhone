import SwiftUI

/// KaPosts' own settings, reached from the gear in the feed's icon row: the cool down before
/// post (the 5-second Undo window every action waits out, or none), and the default tip - the
/// amount a tap on "Tip" sends at once, with no amount screen in between. The tip is set in KAS
/// or, with the unit tapped, in the app's currency (USD unless changed in Settings): then each
/// tip sends that much worth of KAS at the price of the moment.
struct KaPostsSettingsView: View {
    let onClose: () -> Void
    /// Pushed from Settings rather than presented: no stack of its own.
    var embedded = false

    @EnvironmentObject private var settingsViewModel: SettingsViewModel
    @ObservedObject private var priceService = KaspaPriceService.shared
    /// Tips From on the row below, once its page has changed it.
    @ObservedObject private var tipSourceStore = KaPostsTipSourceStore.shared
    @State private var defaultTipText = ""
    @State private var instantTipEnabled = false
    /// The tip amount is being typed: a checkmark beside it locks it in, then it's read-only
    /// with a pencil to change it.
    @State private var editingTip = false
    @FocusState private var tipFieldFocused: Bool
    /// The default tip is typed in `tipCurrency` rather than KAS.
    @State private var tipInFiat = false
    @State private var tipCurrency: AppCurrency = .usDollar
    @State private var cooldownEnabled = false
    /// Tip In: Kaspa, kUSDT, or nil to ask each time.
    @State private var tipAsset: KaPostsTipAsset?

    /// What the amount starts at when the switch goes on: the smallest tip the network takes.
    private static var fallbackTipKas: Double { Double(instantTipMinimumSompi) / 100_000_000.0 }

    /// Instant tips go on one tap, with no swipe, so the most one may send: a bigger default tip opens
    /// the tip sheet, whose swipe is the confirmation.
    static let instantTipLimitSompi: UInt64 = 10 * 100_000_000
    /// The smallest default tip: Kaspa's storage mass (KIP-9) refuses a payment output much under
    /// 0.1 KAS whatever coins pay for it, so 0.0021 KAS could never go out. 0.2 KAS, the wallet's
    /// dust threshold, leaves room for the change output too.
    static let instantTipMinimumSompi: UInt64 = KasiaTransactionBuilder.dustThreshold
    static var instantTipMinimumText: String { "\(KaspaUnit.plain(instantTipMinimumSompi)) \(KaspaUnit.symbol)" }
    static let instantTipLimitNotice = "Instant tips are limited to 10 KAS. Swipe up to send this one."

    var body: some View {
        if embedded {
            form
        } else {
            NavigationStack {
                form
                    .kaPostsStatusChrome()
            }
        }
    }

    private var tipSourceTitle: String {
        switch SendSource.defaultTip() {
        case .chatting: return AppLocalization.string("Chatting Address")
        case .spending(_, _, let label): return label
        case nil: return AppLocalization.string("Not available")
        }
    }

    private var form: some View {
            Form {
                Section {
                    Toggle("Cool down before post", isOn: $cooldownEnabled)
                        .onChange(of: cooldownEnabled) { enabled in
                            guard enabled != settingsViewModel.settings.kaPostsCooldownEnabled else { return }
                            settingsViewModel.settings.kaPostsCooldownEnabled = enabled
                            settingsViewModel.saveSettings()
                        }
                } footer: {
                    Text(cooldownEnabled
                         ? "Posts, comments, likes, reposts, votes, edits and deletes wait 5 seconds, with an Undo, before they go on chain."
                         : "Posts, comments, likes, reposts, votes, edits and deletes go on chain at once, with no Undo.")
                }

                Section {
                    Picker("Tip In", selection: $tipAsset) {
                        Text("Ask Each Time").tag(KaPostsTipAsset?.none)
                        Text(verbatim: "Kaspa").tag(KaPostsTipAsset?.some(.kaspa))
                        Text(verbatim: WalletToken.kusdt.symbol).tag(KaPostsTipAsset?.some(.kusdt))
                    }
                    .onChange(of: tipAsset) { asset in
                        guard asset != settingsViewModel.settings.kaPostsTipAssetInUse else { return }
                        Haptics.selection()
                        settingsViewModel.settings.kaPostsTipAsset = asset
                        // an instant tip is always Kaspa: Ask Each Time and kUSDT turn it off
                        if asset != .kaspa {
                            instantTipEnabled = false
                            settingsViewModel.settings.kaPostsDefaultTipSompi = nil
                            settingsViewModel.settings.kaPostsDefaultTipFiat = nil
                            settingsViewModel.settings.kaPostsDefaultTipFiatCurrency = nil
                        }
                        settingsViewModel.saveSettings()
                    }
                    if tipAsset == .kaspa {
                    Toggle("Send a default tip instantly", isOn: $instantTipEnabled)
                        .onChange(of: instantTipEnabled) { enabled in
                            if enabled {
                                // No Face ID: sends don't ask (owner's call, 2026-11-13).
                                guard settingsViewModel.settings.kaPostsDefaultTipSompi == nil,
                                      settingsViewModel.settings.kaPostsDefaultTipFiat == nil else { return }
                                // starts at 0.2 KAS (anything left from before that the network
                                // wouldn't take is replaced too)
                                if defaultTipText.trimmingCharacters(in: .whitespaces).isEmpty
                                    || (typedAmount ?? 0) <= 0 || tipBelowMinimum {
                                    tipInFiat = false
                                    defaultTipText = Self.trimmed(Self.fallbackTipKas)
                                }
                                editingTip = false
                                commitDefaultTip()
                            } else {
                                settingsViewModel.settings.kaPostsDefaultTipSompi = nil
                                settingsViewModel.settings.kaPostsDefaultTipFiat = nil
                                settingsViewModel.settings.kaPostsDefaultTipFiatCurrency = nil
                                settingsViewModel.saveSettings()
                            }
                        }
                    if instantTipEnabled {
                        HStack {
                            if tipInFiat {
                                Text(verbatim: currencySymbol(for: tipCurrency))
                                    .font(.headline)
                                    .foregroundColor(.secondary)
                                    .frame(minWidth: 22)
                            } else {
                                Image("KaspaLogo")
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 22, height: 22)
                            }
                            TextField("1", text: $defaultTipText)
                                .keyboardType(.decimalPad)
                                .focused($tipFieldFocused)
                                .disabled(!editingTip)
                                .foregroundColor(editingTip ? .primary : .secondary)
                                .onSubmit { lockTip() }
                                // Nothing is saved while typing: the checkmark saves, and so does
                                // the keyboard closing some other way, with an amount that can go out.
                                .onChange(of: tipFieldFocused) { focused in
                                    guard !focused else { return }
                                    editingTip = false
                                    // left empty, zero or too small: show the saved tip again
                                    if tipAmountIsValid { commitDefaultTip() } else { showSavedTip() }
                                }
                            // Beside the value: a checkmark locks the amount in (or, with an amount
                            // that can't go out, puts the saved one back) and closes the keyboard,
                            // then a pencil opens it again.
                            Button {
                                if editingTip {
                                    lockTip()
                                } else {
                                    Haptics.selection()
                                    editingTip = true
                                    // a turn later, once the field is enabled and can take focus
                                    DispatchQueue.main.async { tipFieldFocused = true }
                                }
                            } label: {
                                Image(systemName: editingTip ? "checkmark" : "pencil")
                                    .font(.subheadline.weight(.bold))
                                    .foregroundColor(editingTip ? .black : .accentColor)
                                    .frame(width: 32, height: 32)
                                    .background(Circle().fill(editingTip ? Color.accentColor : Color.accentColor.opacity(0.12)))
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(Text(editingTip ? "Done" : "Edit"))
                            // Tap to set the tip in the other unit.
                            Button(action: switchTipUnit) {
                                HStack(spacing: 4) {
                                    Text(verbatim: tipInFiat ? tipCurrency.code : KaspaUnit.symbol)
                                    Image(systemName: "arrow.up.arrow.down")
                                        .font(.caption.weight(.semibold))
                                }
                                .foregroundColor(.accentColor)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(Text(tipInFiat ? "Tip in \(tipCurrency.code), switch to KAS" : "Tip in KAS, switch to \(settingsViewModel.settings.currency.code)"))
                        }
                        // a full-width line under the amount, not one starting at the unit button
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                    }
                    }
                    if tipAsset != .kusdt {
                    NavigationLink {
                        TipSourcePage()
                    } label: {
                        HStack {
                            Text("Tips From")
                            Spacer()
                            Text(verbatim: tipSourceTitle)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    }
                } header: {
                    Text("Tipping")
                } footer: {
                    if tipAsset == nil {
                        Text("Tip asks whether to send Kaspa or kUSDT each time.")
                    } else if tipAsset == .kusdt {
                        Text("Tip sends kUSDT to the poster's chatting address. kUSDT tips aren't counted on the post.")
                    } else if instantTipEnabled {
                        VStack(alignment: .leading, spacing: 6) {
                            if tipBelowMinimum {
                                Text(verbatim: String(format: AppLocalization.string("The smallest tip the network takes is %@."),
                                                      Self.instantTipMinimumText))
                                    .foregroundColor(.red)
                            }
                            Text(verbatim: tipFooter)
                        }
                    }
                }
            }
            .navigationTitle("KaPost Settings")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                cooldownEnabled = settingsViewModel.settings.kaPostsCooldownEnabled
                let settings = settingsViewModel.settings
                tipCurrency = settings.currency
                tipAsset = settings.kaPostsTipAssetInUse
                if settings.kaPostsDefaultTipFiat ?? 0 > 0 || settings.kaPostsDefaultTipSompi ?? 0 > 0 {
                    instantTipEnabled = true
                    showSavedTip()
                }
            }
    }

    /// The amount typed, as a number (either unit).
    private var typedAmount: Double? {
        // The KAS parser reads any decimal number (the locale's comma included, up to 8 places).
        KaspaUnit.sompi(fromUserText: defaultTipText).map { Double($0) / 100_000_000.0 }
    }

    /// The typed tip in sompi: as typed in KAS, or worked out at today's price for a currency
    /// (nil without a price).
    private var typedSompi: UInt64? {
        guard let amount = typedAmount, amount > 0 else { return nil }
        guard tipInFiat else { return KaspaUnit.sompi(fromUserText: defaultTipText) }
        guard let price = tipPrice(in: tipCurrency), price > 0 else { return nil }
        return UInt64((amount / price * 100_000_000).rounded())
    }

    /// The KAS price a currency tip is measured at here: the fresh one tips are sent at
    /// (`KaspaPriceService.freshPrice`) when there is one, else the last known.
    private func tipPrice(in currency: AppCurrency) -> Double? {
        priceService.freshPrice(in: currency) ?? priceService.price(in: currency)
    }

    /// An amount that can be saved: above zero and not under the network's minimum.
    private var tipAmountIsValid: Bool {
        (typedAmount ?? 0) > 0 && !tipBelowMinimum
    }

    /// Under the smallest tip the network takes (`instantTipMinimumSompi`): not saved.
    private var tipBelowMinimum: Bool {
        guard let sompi = typedSompi else { return false }
        return sompi < Self.instantTipMinimumSompi
    }

    /// What a tip sends: in KAS, or the currency amount with what it comes to in KAS today.
    private var tipFooter: String {
        tipAmountFooter + " " + AppLocalization.string("Up to 10 KAS goes out without asking; a bigger tip opens the tip screen.")
    }

    private var tipAmountFooter: String {
        guard tipInFiat else {
            return AppLocalization.string("Tap the unit to set the tip in your currency instead.")
        }
        let price = tipPrice(in: tipCurrency)
        if let amount = typedAmount, amount > 0, let price, price > 0 {
            return String(format: AppLocalization.string("Each tip sends %@ worth of KAS at the price of the moment - about %@ KAS now."),
                          formatFiatAmount(amount, currency: tipCurrency), formatKasAmountPlain(amount / price))
        }
        return AppLocalization.string("Each tip sends this much worth of KAS at the price of the moment.")
    }

    /// Flips the tip between KAS and the app's currency, carrying the amount over at today's
    /// price (the number stays as typed when there is no price yet). Saved at once unless the
    /// amount is being typed (then the checkmark saves it). An amount that comes out under the
    /// network's minimum (a currency amount rounds to the cent) puts the saved tip back instead.
    private func switchTipUnit() {
        Haptics.selection()
        let toFiat = !tipInFiat
        let currency = toFiat ? settingsViewModel.settings.currency : tipCurrency
        let price = tipPrice(in: currency)
        var newText = defaultTipText
        if let amount = typedAmount, amount > 0, let price, price > 0 {
            newText = toFiat ? Self.fiatText(amount * price, currency: currency) : Self.trimmed(amount / price)
        }
        tipCurrency = currency
        tipInFiat = toFiat
        defaultTipText = newText
        if tipBelowMinimum {
            showSavedTip()
            return
        }
        if !editingTip { commitDefaultTip() }
    }

    /// The saved default tip, in the unit it was saved in.
    private func showSavedTip() {
        let settings = settingsViewModel.settings
        if let fiat = settings.kaPostsDefaultTipFiat, fiat > 0 {
            tipInFiat = true
            tipCurrency = settings.kaPostsDefaultTipFiatCurrency ?? settings.currency
            defaultTipText = Self.fiatText(fiat, currency: tipCurrency)
        } else if let sompi = settings.kaPostsDefaultTipSompi, sompi > 0 {
            tipInFiat = false
            defaultTipText = Self.trimmed(Double(sompi) / 100_000_000.0)
        }
    }

    /// The checkmark (or the keyboard's return): saves the amount and closes the keyboard. One
    /// that can't go out (empty, zero, under the minimum) isn't saved: the saved tip comes back,
    /// so the keyboard can always be closed.
    private func lockTip() {
        Haptics.selection()
        if tipAmountIsValid {
            commitDefaultTip()
        } else {
            showSavedTip()
        }
        tipFieldFocused = false
        editingTip = false
    }

    private func commitDefaultTip() {
        guard instantTipEnabled, !tipBelowMinimum else { return }
        if tipInFiat {
            guard let amount = typedAmount, amount > 0 else { return }
            let settings = settingsViewModel.settings
            guard amount != settings.kaPostsDefaultTipFiat || tipCurrency != settings.kaPostsDefaultTipFiatCurrency
                    || settings.kaPostsDefaultTipSompi != nil else { return }
            settingsViewModel.settings.kaPostsDefaultTipFiat = amount
            settingsViewModel.settings.kaPostsDefaultTipFiatCurrency = tipCurrency
            settingsViewModel.settings.kaPostsDefaultTipSompi = nil
        } else {
            guard let sompi = KaspaUnit.sompi(fromUserText: defaultTipText), sompi > 0 else { return }
            guard sompi != settingsViewModel.settings.kaPostsDefaultTipSompi
                    || settingsViewModel.settings.kaPostsDefaultTipFiat != nil else { return }
            settingsViewModel.settings.kaPostsDefaultTipSompi = sompi
            settingsViewModel.settings.kaPostsDefaultTipFiat = nil
            settingsViewModel.settings.kaPostsDefaultTipFiatCurrency = nil
        }
        settingsViewModel.saveSettings()
    }

    /// A currency amount for the field: the currency's decimals (8 for Bitcoin, else 2), trimmed
    /// ("1", "1.5", "0.25").
    private static func fiatText(_ value: Double, currency: AppCurrency) -> String {
        var text = formatCurrencyAmountPlain(value, currency: currency)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    private static func trimmed(_ kas: Double) -> String {
        var text = String(format: "%.8f", kas)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}


/// KaPosts > Settings > Tips From: the address tips leave from unless the tip sheet picks another.
/// The chatting address sends a tip that counts on the post; another address sends it privately
/// (`ChatService.sendPayment`: no post named, nothing counted, nobody listed as the tipper).
private struct TipSourcePage: View {
    @ObservedObject private var tipSourceStore = KaPostsTipSourceStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Tips from your Chatting Address count on the post, and you're listed as a tipper. From another address a tip is private: the author gets it, and sees it in your chat, but it doesn't count on the post or name you.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                OwnAddressList(selected: SendSource.defaultTip()?.address) { picked in
                    let index = picked.spendingIndex
                    guard index != tipSourceStore.index else { return }
                    tipSourceStore.index = index
                    Haptics.selection()
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .navigationTitle("Tips From")
        .navigationBarTitleDisplayMode(.inline)
    }
}
