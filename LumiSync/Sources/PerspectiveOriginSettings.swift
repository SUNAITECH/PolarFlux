import Foundation

enum PerspectiveOriginMode: String, CaseIterable, Identifiable {
    case auto = "Auto"
    case manual = "Manual"

    var id: String { rawValue }
}

struct OriginPreference {
    var mode: PerspectiveOriginMode
    var manualNormalized: Double
}
