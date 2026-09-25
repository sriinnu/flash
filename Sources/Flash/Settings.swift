import SwiftUI

enum FlashColor: String, CaseIterable, Identifiable {
    // Order = swatch order. The original four keep their raw values so
    // saved settings survive; `random` stays last.
    case amber, sunset, ember, crimson
    case magenta, synthwave, ultraviolet
    case cyan, ocean, ice
    case lime, aurora
    case random

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

        // Cross-hue pairs: two genuinely different colors read as a
        // gradient from across the room; two shades of one hue read as flat.
        case .sunset:
            return [rgb(1.00, 0.38, 0.55), rgb(1.00, 0.62, 0.10)]   // coral pink → orange
        case .ember:
            return [rgb(1.00, 0.88, 0.25), rgb(1.00, 0.20, 0.10)]   // yellow → red
        case .crimson:
            return [rgb(1.00, 0.25, 0.35), rgb(0.80, 0.05, 0.45)]   // red → wine
        case .synthwave:
            return [rgb(1.00, 0.25, 0.85), rgb(0.10, 0.60, 1.00)]   // hot pink → electric blue
        case .ultraviolet:
            return [rgb(0.72, 0.45, 1.00), rgb(1.00, 0.30, 0.70)]   // violet → pink
        case .ocean:
            return [rgb(0.15, 1.00, 0.90), rgb(0.10, 0.35, 1.00)]   // aqua → deep blue
        case .ice:
            return [rgb(0.80, 0.97, 1.00), rgb(0.30, 0.60, 1.00)]   // frost → blue
        case .aurora:
            return [rgb(0.25, 1.00, 0.65), rgb(0.60, 0.30, 1.00)]   // green → violet
        case .random:
            return [NSColor(red: 0.75, green: 0.35, blue: 1.00, alpha: 1),
                    NSColor(red: 0.20, green: 0.90, blue: 1.00, alpha: 1)]
        }
    }

    private func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
        NSColor(red: r, green: g, blue: b, alpha: 1)
    }

    /// Representative color — glow tint, settings swatch.
    var color: NSColor { gradient[0] }

    /// A fresh, vivid, randomly-hued two-tone gradient for one alert.
    /// Same saturation/brightness floor as the curated presets so a roll
    /// never lands on something washed out — hue is the only thing random.
    static func randomVividGradient() -> [NSColor] {
        let hue = CGFloat.random(in: 0...1)
        // Wide enough to land on a second hue (the presets' lesson), short
        // of complementary, which tends to go muddy where the two meet.
        let hueShift = CGFloat.random(in: 0.12...0.32)
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

/// How the *first* alert for a prompt looks. Reminders always escalate to
/// `.classic` — subtle first, loud second — so a missed comet still ends in
/// the full-border shout if a reminder interval is set.
enum AlertStyle: String, CaseIterable, Identifiable {
    case comet, marquee, targetLock, heartbeat, classic

    var id: String { rawValue }
    var label: String {
        switch self {
        case .comet: return "Comet chase"
        case .marquee: return "Marquee"
        case .targetLock: return "Target lock"
        case .heartbeat: return "Heartbeat"
        case .classic: return "Classic flash"
        }
    }

    /// One-liner under the picker so the choice isn't a guessing game.
    var blurb: String {
        switch self {
        case .comet: return "Two comets race down the edges and collide at the bottom."
        case .marquee: return "Marquee lights chase round the whole border."
        case .targetLock: return "Corner brackets slam in, lock, and trace the border."
        case .heartbeat: return "The border thumps inward — calm, rhythmic."
        case .classic: return "The full border pulses on and off."
        }
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

    var alertStyle: AlertStyle {
        AlertStyle(rawValue: defaults.string(forKey: "alertStyle") ?? "") ?? .comet
    }

    /// Defaults on — `integer(forKey:)` can't tell "unset" from "false".
    var successRipple: Bool {
        defaults.object(forKey: "successRipple") as? Bool ?? true
    }

    var flashCount: Int {
        let n = defaults.integer(forKey: "flashCount")
        return n == 0 ? 4 : n
    }

    // MARK: Detection

    /// Keychain / password / Touch ID / GPG PIN dialogs. Defaults on.
    var watchAuthPrompts: Bool {
        defaults.object(forKey: "watchAuthPrompts") as? Bool ?? true
    }

    /// ssh passphrase / PIN / key-touch prompts via flash-askpass, set in
    /// launchd's environment. Off by default: it changes how every ssh on
    /// the Mac asks for secrets (dialogs instead of the terminal).
    var routeSSHPrompts: Bool {
        defaults.bool(forKey: "routeSSHPrompts")
    }

    /// Commit / push log in the menu-bar panel. Defaults on.
    var activityLogEnabled: Bool {
        defaults.object(forKey: "activityLog") as? Bool ?? true
    }

    /// Folders whose git repos feed the activity log. Unset → whichever of
    /// the usual code folders exist, so it works before anyone opens Settings.
    var watchRoots: [String] {
        get { defaults.stringArray(forKey: "watchRoots") ?? Self.defaultRoots }
        set { defaults.set(Self.normalized(newValue), forKey: "watchRoots") }
    }

    static var defaultRoots: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // One spelling each: APFS is usually case-insensitive, so "Code" and
        // "code" would be the same folder watched twice.
        let candidates = ["code", "Developer", "Projects", "src", "dev", "work", "repos", "GitHub"]
        return normalized(candidates.map { "\(home)/\($0)" }.filter {
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0, isDirectory: &isDir) && isDir.boolValue
        })
    }

    /// Dedupe, and drop any root nested inside another — FSEvents would
    /// report the same file once per overlapping root.
    static func normalized(_ roots: [String]) -> [String] {
        let unique = Array(Set(roots.map { ($0 as NSString).standardizingPath })).sorted()
        return unique.filter { root in
            !unique.contains { other in other != root && root.hasPrefix(other + "/") }
        }
    }
}
