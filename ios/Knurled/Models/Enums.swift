import Foundation

enum Units: String, Codable, Sendable, Hashable {
    case kg
    case lb
}

enum SwapPolicy: String, Codable, Sendable, Hashable {
    case trackingOnly = "tracking_only"
    case progressionEquivalent = "progression_equivalent"
}

enum ValidationStatus: String, Codable, Sendable, Hashable {
    case valid
    case invalid
}
