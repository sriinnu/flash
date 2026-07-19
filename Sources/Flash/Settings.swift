import SwiftUI

enum FlashColor: String, CaseIterable, Identifiable {
    case amber, cyan, magenta, lime, random

    var id: String { rawValue }
    var label: String { self == .random ? "Random" : rawValue.capitalized }

    /// Two-tone neon gradient for the border stroke. Each preset's first stop
    /// (used for the glow) is tuned for comparable perceptual brightness —
    /// magenta used to sit at roughly half the luminance of the others,
    /// which meant it was the weakest preset for the one thing this app
    /// needs: catching your eye when you're not looking at the screen.
    ///
    /// `.random`'s value here is only a settings-swatch placeholder — the
    /// real per-alert gradient comes from `randomVividGradient()`, which
    /// FlashController resolves once per pulse (not per screen, not per
    /// property access) so every display flashes the same roll and the
    /// glow tint always matches the stroke.
    var gradient: [NSColor] {
        switch self {
        case .amber:
            return [NSColor(red: 1.00, green: 0.82, blue: 0.00, alpha: 1),
                    NSColor(red: 1.00, green: 0.42, blue: 0.00, alpha: 1)]
        case .cyan:
            return [NSColor(red: 0.20, green: 0.90, blue: 1.00, alpha: 1),
                    NSColor(red: 0.00, green: 0.55, blue: 1.00, alpha: 1)]
        case .magenta:
            return [NSColor(red: 1.00, green: 0.15, blue: 0.60, alpha: 1),
                    NSColor(red: 0.72, green: 0.10, blue: 1.00, alpha: 1)]
        case .lime:
            return [NSColor(red: 0.70, green: 1.00, blue: 0.05, alpha: 1),
                    NSColor(red: 0.10, green: 0.90, blue: 0.35, alpha: 1)]
        case .random:
            return [NSColor(red: 0.75, green: 0.35, blue: 1.00, alpha: 1),
                    NSColor(red: 0.20, green: 0.90, blue: 1.00, alpha: 1)]
        }
    }

    /// Representative color — glow tint, settings swatch.
    var color: NSColor { gradient[0] }

    /// A fresh, vivid, randomly-hued two-tone gradient for one alert.
    /// Same saturation/brightness floor as the curated presets so a roll
    /// never lands on something washed out — hue is the only thing random.
    static func randomVividGradient() -> [NSColor] {
        let hue = CGFloat.random(in: 0...1)
        let hueShift = CGFloat.random(in: 0.06...0.16)
        let c1 = NSColor(hue: hue, saturation: CGFloat.random(in: 0.85...1.0), brightness: 1.0, alpha: 1)
        let c2 = NSColor(
            hue: (hue + hueShift).truncatingRemainder(dividingBy: 1),
            saturation: 1.0,
            brightness: CGFloat.random(in: 0.75...0.9),
            alpha: 1
        )
        return [c1, c2]
    }
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
