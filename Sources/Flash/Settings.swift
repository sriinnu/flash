import SwiftUI

enum FlashColor: String, CaseIterable, Identifiable {
    case amber, cyan, magenta, lime

    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    /// Two-tone neon gradient for the border stroke.
    var gradient: [NSColor] {
        switch self {
        case .amber:
            return [NSColor(red: 1.00, green: 0.84, blue: 0.04, alpha: 1),
                    NSColor(red: 1.00, green: 0.55, blue: 0.02, alpha: 1)]
        case .cyan:
            return [NSColor(red: 0.40, green: 0.85, blue: 1.00, alpha: 1),
                    NSColor(red: 0.04, green: 0.48, blue: 1.00, alpha: 1)]
        case .magenta:
            return [NSColor(red: 1.00, green: 0.25, blue: 0.42, alpha: 1),
                    NSColor(red: 0.75, green: 0.35, blue: 0.96, alpha: 1)]
        case .lime:
            return [NSColor(red: 0.68, green: 1.00, blue: 0.10, alpha: 1),
                    NSColor(red: 0.18, green: 0.80, blue: 0.35, alpha: 1)]
        }
    }

    /// Representative color — glow tint, settings swatch.
    var color: NSColor { gradient[0] }
}

enum ReminderInterval: Int, CaseIterable, Identifiable {
    case off = 0
    case fifteen = 15
    case thirty = 30
    case sixty = 60

    var id: Int { rawValue }
    var label: String { rawValue == 0 ? "Off" : "Every \(rawValue)s" }
}

/// Reads live from UserDefaults; views bind via @AppStorage with the same keys.
final class FlashSettings {
    static let shared = FlashSettings()
    private let defaults = UserDefaults.standard

    var flashColor: FlashColor {
        FlashColor(rawValue: defaults.string(forKey: "flashColor") ?? "") ?? .amber
    }

    var reminderInterval: ReminderInterval {
        ReminderInterval(rawValue: defaults.integer(forKey: "reminderInterval")) ?? .off
    }

    var flashCount: Int {
        let n = defaults.integer(forKey: "flashCount")
        return n == 0 ? 4 : n
    }
}
