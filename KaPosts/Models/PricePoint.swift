import Foundation

/// A single (timestamp, value) sample of KAS price history.
struct PricePoint: Equatable, Codable {
    let timestamp: Date
    let value: Double
}
