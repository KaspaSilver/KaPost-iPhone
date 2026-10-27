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
    @State private var defaultTipText = ""
    @State private var instantTipEnabled = false
    /// The default tip is typed in `tipCurrency` rather than KAS.
    @State private var tipInFiat = false
    @State private var tipCurrency: AppCurrency = .usDollar
    @State private var cooldownEnabled = true

    private static let fallbackTipKas = 1.0

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
                    Toggle("Send a default tip instantly", isOn: $instantTipEnabled)
                        .onChange(of: instantTipEnabled) { enabled in
                            if enabled {
                                if defaultTipText.trimmingCharacters(in: .whitespaces).isEmpty {
                                    defaultTipText = Self.trimmed(Self.fallbackTipKas)
                                }
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
                                .numericKeyboardDoneButton()
                                .onSubmit { commitDefaultTip() }
                                .onChange(of: defaultTipText) { _ in commitDefaultTip() }
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
                    }
                } header: {
                    Text("Tipping")
                } footer: {
                    if instantTipEnabled {
                        Text(verbatim: tipFooter)
                    }
                }
            }
            .navigationTitle("KaPost Settings")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                cooldownEnabled = settingsViewModel.settings.kaPostsCooldownEnabled
                let settings = settingsViewModel.settings
                tipCurrency = settings.currency
                if let fiat = settings.kaPostsDefaultTipFiat, fiat > 0 {
                    instantTipEnabled = true
                    tipInFiat = true
                    tipCurrency = settings.kaPostsDefaultTipFiatCurrency ?? settings.currency
                    defaultTipText = Self.fiatText(fiat)
                } else if let sompi = settings.kaPostsDefaultTipSompi, sompi > 0 {
                    instantTipEnabled = true
                    defaultTipText = Self.trimmed(Double(sompi) / 100_000_000.0)
                }
            }
    }

    /// The amount typed, as a number (either unit).
    private var typedAmount: Double? {
        // The KAS parser reads any decimal number (the locale's comma included, up to 8 places).
        KaspaUnit.sompi(fromUserText: defaultTipText).map { Double($0) / 100_000_000.0 }
    }

    /// What a tip sends: in KAS, or the currency amount with what it comes to in KAS today.
    private var tipFooter: String {
        guard tipInFiat else {
            return AppLocalization.string("Tap the unit to set the tip in your currency instead.")
        }
        let price = priceService.price(in: tipCurrency)
        if let amount = typedAmount, amount > 0, let price, price > 0 {
            return String(format: AppLocalization.string("Each tip sends %@ worth of KAS at the price of the moment - about %@ KAS now."),
                          formatFiatAmount(amount, currency: tipCurrency), formatKasAmountPlain(amount / price))
        }
        return AppLocalization.string("Each tip sends this much worth of KAS at the price of the moment.")
    }

    /// Flips the tip between KAS and the app's currency, carrying the amount over at today's
    /// price (the number stays as typed when there is no price yet).
    private func switchTipUnit() {
        Haptics.selection()
        let toFiat = !tipInFiat
        let currency = toFiat ? settingsViewModel.settings.currency : tipCurrency
        let price = priceService.price(in: currency)
        var newText = defaultTipText
        if let amount = typedAmount, amount > 0, let price, price > 0 {
            newText = toFiat ? Self.fiatText(amount * price) : Self.trimmed(amount / price)
        }
        tipCurrency = currency
        tipInFiat = toFiat
        defaultTipText = newText
        commitDefaultTip()
    }

    private func commitDefaultTip() {
        guard instantTipEnabled else { return }
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

    /// A currency amount for the field: two decimals, trimmed ("1", "1.5", "0.25").
    private static func fiatText(_ value: Double) -> String {
        var text = String(format: "%.2f", value)
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
