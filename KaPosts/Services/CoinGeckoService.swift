import Foundation

/// Free public CoinGecko REST client for the current KAS price in the app's currency, used by
/// `KaspaPriceService`. No API key required. Mirrors the cache-on-failure philosophy used throughout the app's
/// other REST clients (e.g. KNSService): return nil/empty on any failure rather than throwing,
/// so callers can fall back to their own last-known-good state instead of crashing or showing
/// a hard error. Currency is caller-supplied (`AppCurrency`, Settings > Customization > Currency) -
/// CoinGecko's public API natively supports any of its listed `vs_currency` values, so switching
/// away from USD needs no change on CoinGecko's side, just passing the selected code through.
/// `Sendable` (all stored properties immutable), so it can be used off the main actor.
final class CoinGeckoService: Sendable {
    static let shared = CoinGeckoService()

    private let session: URLSession
    private let baseURL = "https://api.coingecko.com"

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20
        session = URLSession(configuration: config)
    }

    private struct SimplePriceResponse: Decodable {
        let kaspa: [String: Double]
    }

    /// `change24hPercent` is nil only on a decode/response oddity, not treated as a separate
    /// failure from the price fetch itself — CoinGecko returns both in the same call
    /// (`include_24hr_change=true`), so there's no second request to independently fail.
    func getCurrentPrice(currency: AppCurrency) async -> (price: Double, change24hPercent: Double?)? {
        guard var components = URLComponents(string: baseURL + "/api/v3/simple/price") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "ids", value: "kaspa"),
            URLQueryItem(name: "vs_currencies", value: currency.rawValue),
            URLQueryItem(name: "include_24hr_change", value: "true")
        ]
        guard let url = components.url else { return nil }

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let decoded = try JSONDecoder().decode(SimplePriceResponse.self, from: data)
            guard let price = decoded.kaspa[currency.rawValue] else { return nil }
            let change24h = decoded.kaspa["\(currency.rawValue)_24h_change"]
            return (price: price, change24hPercent: change24h)
        } catch {
            return nil
        }
    }
}
