import Foundation
import UIKit

/// The KAS spot price in the currency picked in Settings, for the amount fields and fiat labels.
///
/// This is the price half of KaChat's PortfolioViewModel, without the portfolios: the last price
/// this device saw paints at once (persisted per currency), a fresh one is fetched at launch, on
/// return to the app when it is over five minutes old, and on a currency change, and a failed
/// fetch keeps retrying on a growing pause (CoinGecko's keyless tier throttles launch bursts).
@MainActor
final class KaspaPriceService: ObservableObject {
    static let shared = KaspaPriceService()

    /// Despite the name, in `currentCurrency` - the name is kept so the send screens read the
    /// same as KaChat's.
    @Published private(set) var currentPriceUsd: Double?
    @Published private(set) var priceChange24h: Double?
    private(set) var currentCurrency: AppCurrency = SettingsViewModel.loadSettings().currency

    private let coinGecko: CoinGeckoService
    private var lastPriceFetchAt: Date?
    private var priceRetryTask: Task<Void, Never>?
    private var foregroundObserver: NSObjectProtocol?
    private var settingsObserver: NSObjectProtocol?

    init(coinGecko: CoinGeckoService = .shared) {
        self.coinGecko = coinGecko
        restorePersistedPrice()
        refreshPrice()
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshPriceIfStale() }
        }
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .settingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleSettingsChanged() }
        }
    }

    deinit {
        if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
    }

    func refreshPrice() {
        let currency = currentCurrency
        Task { [weak self] in
            guard let self else { return }
            if let result = await self.coinGecko.getCurrentPrice(currency: currency) {
                self.applyPrice(result, currency: currency)
            } else {
                self.ensurePriceLoaded()
            }
        }
    }

    func refreshPriceIfStale() {
        if let last = lastPriceFetchAt, Date().timeIntervalSince(last) < 5 * 60, currentPriceUsd != nil { return }
        refreshPrice()
    }

    /// 1 KAS in `currency`: the live price for the app's currency, else the last one this
    /// device saw for that currency (nil if it never fetched one).
    func price(in currency: AppCurrency) -> Double? {
        if currency == currentCurrency { return currentPriceUsd }
        guard let data = UserDefaults.standard.data(forKey: priceKey(currency)),
              let saved = try? JSONDecoder().decode(PersistedPrice.self, from: data) else { return nil }
        return saved.price
    }

    private struct PersistedPrice: Codable {
        let price: Double
        let change24h: Double?
        let fetchedAt: Date
    }

    private func priceKey(_ currency: AppCurrency) -> String { "kachat_kas_price_\(currency.rawValue)" }

    private func restorePersistedPrice() {
        guard let data = UserDefaults.standard.data(forKey: priceKey(currentCurrency)),
              let saved = try? JSONDecoder().decode(PersistedPrice.self, from: data) else { return }
        currentPriceUsd = saved.price
        priceChange24h = saved.change24h
    }

    private func applyPrice(_ result: (price: Double, change24hPercent: Double?), currency: AppCurrency) {
        guard currency == currentCurrency else { return }
        currentPriceUsd = result.price
        priceChange24h = result.change24hPercent
        lastPriceFetchAt = Date()
        let saved = PersistedPrice(price: result.price, change24h: result.change24hPercent, fetchedAt: Date())
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: priceKey(currency))
        }
        priceRetryTask?.cancel()
        priceRetryTask = nil
    }

    private func ensurePriceLoaded() {
        guard priceRetryTask == nil else { return }
        let currency = currentCurrency
        priceRetryTask = Task { [weak self] in
            for delay in [3.0, 8.0, 20.0, 45.0, 90.0, 180.0] {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self, !Task.isCancelled, self.currentCurrency == currency else { return }
                if let result = await self.coinGecko.getCurrentPrice(currency: currency) {
                    self.applyPrice(result, currency: currency)
                    return
                }
            }
            self?.priceRetryTask = nil
        }
    }

    private func handleSettingsChanged() {
        let newCurrency = SettingsViewModel.loadSettings().currency
        guard newCurrency != currentCurrency else { return }
        currentCurrency = newCurrency
        priceRetryTask?.cancel()
        priceRetryTask = nil
        currentPriceUsd = nil
        priceChange24h = nil
        restorePersistedPrice()
        refreshPrice()
    }
}
