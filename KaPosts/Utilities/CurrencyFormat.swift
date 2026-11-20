import Foundation

/// Resolves an `AppCurrency` to its display symbol (e.g. "$", "€") - Bitcoin isn't ISO 4217, so
/// it's spelled out rather than trusted to `NumberFormatter`'s fallback behavior for an
/// unrecognized code. Mirrors KaChat's `PortfolioView.currencySymbol(for:)`, kept separate since that one
/// stays `private` to its file - shared here for callers outside Portfolio (see
/// `KaspaFiatAmountState`).
func currencySymbol(for currency: AppCurrency) -> String {
    if currency == .bitcoin { return "₿" }
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = currency.code
    return formatter.currencySymbol ?? currency.code
}

/// Generic fiat total - symbol + the currency's decimals (2, or 8 for bitcoin), for a read-only
/// display label (e.g. a live KAS-to-fiat conversion next to a Max button). Not meant to be parsed
/// back - see `KaspaFiatAmountState`, which keeps its own plain (no symbol) edit buffer for that.
func formatFiatAmount(_ value: Double, currency: AppCurrency) -> String {
    let sign = value < 0 ? "-" : ""
    return "\(sign)\(currencySymbol(for: currency))\(formatCurrencyAmountPlain(abs(value), currency: currency))"
}

/// A plain amount in `currency` with its decimals (`AppCurrency.fractionDigits`), no symbol:
/// what a currency-mode amount field shows and parses back.
func formatCurrencyAmountPlain(_ value: Double, currency: AppCurrency) -> String {
    String(format: "%.\(currency.fractionDigits)f", value)
}

/// Trimmed 8-decimal KAS amount (e.g. "12.5" rather than "12.50000000").
func formatKasAmountPlain(_ value: Double) -> String {
    var text = String(format: "%.8f", value)
    while text.hasSuffix("0") { text.removeLast() }
    if text.hasSuffix(".") { text.removeLast() }
    return text
}
