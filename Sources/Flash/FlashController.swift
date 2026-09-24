import AppKit

/// Owns trigger state and fires border pulses on every connected display.
/// One trigger id per detection engine ("fido", "gui", "terminal").
@MainActor
final class FlashController: ObservableObject {

    enum IconState {
        case idle      // plain shield
        case alerting  // amber — something wants your hands
        case success   // green — touch/entry confirmed, fades back to idle
    }

    static let shared = FlashController()

    @Published private(set) var activeTriggers: Set<String> = []
    @Published private(set) var iconState: IconState = .idle

    /// Confirmed touches since local midnight — shown in the menu-bar panel.
    /// Persisted so a relaunch mid-day doesn't zero it.
    @Published private(set) var touchesToday = 0
    /// Last *real* alert (not Test Flash), in-memory only.
    @Published private(set) var lastAlertAt: Date?

    private init() {
        refreshStats()
    }

    /// Alert and celebration windows tracked apart so a touch can cut the
    /// alert short without also killing the ripple it's about to trigger.
    private var alertWindows: [OverlayWindow] = []
    private var celebrationWindows: [OverlayWindow] = []

    /// Passes per comet alert. Two ≈ 3s, about what four classic flashes
    /// take — one pass alone was too easy to miss with reminders off.
    private let cometPasses = 2
    private var reminderTask: Task<Void, Never>?
    private var successResetTask: Task<Void, Never>?
    private var watchdogTasks: [String: Task<Void, Never>] = [:]

    /// Longest we'll trust a trigger to resolve itself. If an engine dies
    /// mid-prompt (killed process, crashed helper, unplugged key) without
    /// ever calling `resolve`, the id would otherwise stay in `activeTriggers`
    /// forever — silently swallowing every future `trigger(id)` call, since
    /// the guard below treats "already active" as "already alerting". This
    /// caps that blast radius regardless of why resolve never came.
    private let watchdogTimeout: Duration = .seconds(45)

    /// Begin an alert for a trigger. Ignored if that trigger is already active.
    func trigger(_ id: String) {
        guard !activeTriggers.contains(id) else { return }
        activeTriggers.insert(id)
        lastAlertAt = Date()
        successResetTask?.cancel()
        iconState = .alerting
        pulseAll()
        scheduleReminder()
        scheduleWatchdog(id)
    }

    /// The prompt ended. `success` = answered (key touched, password entered);
    /// `false` = cancelled or vanished without an answer.
    func resolve(_ id: String, success: Bool) {
        guard activeTriggers.remove(id) != nil else { return }
        watchdogTasks[id]?.cancel()
        watchdogTasks[id] = nil

        if success {
            recordTouch()
            dismissAlerts()
            if FlashSettings.shared.successRipple { celebrateAll() }
            iconState = .success
            successResetTask?.cancel()
            successResetTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled, let self, self.iconState == .success else { return }
                self.iconState = self.activeTriggers.isEmpty ? .idle : .alerting
            }
        } else {
            iconState = activeTriggers.isEmpty ? .idle : .alerting
        }

        if activeTriggers.isEmpty {
            reminderTask?.cancel()
            reminderTask = nil
        }
    }

    /// Hard reset — used when watching is paused.
    func resolveAll() {
        dismissAlerts()
        activeTriggers.removeAll()
        reminderTask?.cancel()
        reminderTask = nil
        successResetTask?.cancel()
        watchdogTasks.values.forEach { $0.cancel() }
        watchdogTasks.removeAll()
        iconState = .idle
    }

    /// Manual pulse from the menu — no trigger state, just the fireworks.
    func testPulse() {
        pulseAll()
    }

    /// Manual success ripple from the menu — ignores the settings toggle,
    /// since asking to see it is the whole point.
    func testSuccess() {
        dismissAlerts()
        celebrateAll()
    }

    // MARK: Stats

    private static let statsDayKey = "statsDay"
    private static let statsTouchesKey = "statsTouches"

    /// Re-reads today's count, zeroing it if the stored day isn't today.
    /// Called on launch and each time the panel opens, so an app left
    /// running overnight doesn't show yesterday's number.
    func refreshStats() {
        let defaults = UserDefaults.standard
        let today = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        if defaults.double(forKey: Self.statsDayKey) != today {
            defaults.set(today, forKey: Self.statsDayKey)
            defaults.set(0, forKey: Self.statsTouchesKey)
        }
        touchesToday = defaults.integer(forKey: Self.statsTouchesKey)
    }

    private func recordTouch() {
        refreshStats()
        touchesToday += 1
        UserDefaults.standard.set(touchesToday, forKey: Self.statsTouchesKey)
    }

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// `escalated` = a reminder re-pulse: the first alert was ignored, so
    /// skip the finesse and go full classic. Reduce Motion also forces
    /// classic — every other style moves the border, which is exactly what
    /// that setting exists to switch off.
    private func pulseAll(escalated: Bool = false) {
        let settings = FlashSettings.shared
        let style: AlertStyle = (escalated || reduceMotion) ? .classic : settings.alertStyle
        let preset = settings.flashColor
        let count = settings.flashCount
        let passes = cometPasses
        // Resolved once per pulse, not per screen, so a "random" roll shows
        // the same colors on every display and the glow matches the stroke.
        let gradient = preset == .random ? FlashColor.randomVividGradient() : preset.gradient
        let glow = gradient[0]
        Log.write("[controller] alert — \(style.rawValue)\(escalated ? " (escalated)" : "")")

        for screen in NSScreen.screens {
            let window = OverlayWindow(screen: screen) { frame in
                switch style {
                case .comet:
                    return CometChaseView(frame: frame, gradient: gradient, glowColor: glow, passes: passes)
                case .marquee:
                    return MarqueeView(frame: frame, gradient: gradient)
                case .targetLock:
                    return TargetLockView(frame: frame, gradient: gradient, glowColor: glow)
                case .heartbeat:
                    return HeartbeatView(frame: frame, gradient: gradient, glowColor: glow)
                case .classic:
                    return ClassicFlashView(frame: frame, gradient: gradient, glowColor: glow, flashes: count)
                }
            }
            alertWindows.append(window)
            let name = screen.localizedName
            window.play { [weak self] in
                // Paired with the "alert —" line above: if the app dies and
                // this never shows, it died mid-animation, not in cleanup.
                Log.write("[overlay] \(style.rawValue) finished on \(name)")
                Task { @MainActor in
                    self?.alertWindows.removeAll { $0 === window }
                    Log.write("[overlay] window released, \(self?.alertWindows.count ?? -1) still up")
                }
            }
        }
    }

    private func celebrateAll() {
        let calm = reduceMotion
        for screen in NSScreen.screens {
            let window = OverlayWindow(screen: screen) { frame in
                SuccessRippleView(frame: frame, reduceMotion: calm)
            }
            celebrationWindows.append(window)
            window.play { [weak self] in
                Task { @MainActor in
                    self?.celebrationWindows.removeAll { $0 === window }
                }
            }
        }
    }

    /// Fades any in-flight alert. The windows still clean themselves up via
    /// their `play` completion once the underlying animations finish.
    private func dismissAlerts() {
        alertWindows.forEach { $0.fadeOut() }
    }

    private func scheduleWatchdog(_ id: String) {
        watchdogTasks[id]?.cancel()
        watchdogTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: self?.watchdogTimeout ?? .seconds(45))
            guard !Task.isCancelled, let self, self.activeTriggers.contains(id) else { return }
            Log.write("[controller] '\(id)' never resolved within \(self.watchdogTimeout) — clearing so it can rearm")
            self.resolve(id, success: false)
        }
    }

    private func scheduleReminder() {
        reminderTask?.cancel()
        let interval = FlashSettings.shared.reminderInterval.rawValue
        guard interval > 0 else { return }
        reminderTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self, !self.activeTriggers.isEmpty else { return }
                self.pulseAll(escalated: true)
            }
        }
    }
}
