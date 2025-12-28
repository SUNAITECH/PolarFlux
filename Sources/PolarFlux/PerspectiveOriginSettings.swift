import Foundation

enum PerspectiveOriginMode: String, CaseIterable, Identifiable {
    case auto = "AUTO"
    case manual = "MANUAL"

    var id: String { rawValue }
    var localizedName: String {
        String(localized: String.LocalizationValue(self.rawValue))
    }
}

struct OriginPreference {
    var mode: PerspectiveOriginMode
    var manualNormalized: Double
}
