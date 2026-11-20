import AppKit

/// Owns trigger state and fires border pulses on every connected display.
/// One trigger id per detection engine ("fido", "gui", "terminal").
@MainActor
final class FlashController: ObservableObject {

    enum IconState: Equatable {
        case idle                  // plain shield
        case alerting(AlertKind)   // something wants your hands (or an agent wants you)
        case success               // green — touch/entry confirmed, fades back to idle
        case secretRead            // an agent read a secret; stays until you look

        var isAlerting: Bool { if case .alerting = self { return true }; return false }
    }

    static let shared = FlashController()

    @Published private(set) var activeTriggers: Set<String> = []
    @Published private(set) var iconState: IconState = .idle

    /// Confirmed touches since local midnight — shown in the menu-bar panel.
    /// Persisted so a relaunch mid-day doesn't zero it.
    @Published private(set) var touchesToday = 0
    /// Last *real* alert (not Test Flash), in-memory only.
    @Published private(set) var lastAlertAt: Date?
    /// Secret reads since you last opened the panel or Activity.
    @Published private(set) var unseenSecrets = 0

    private init() {
        refreshStats()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { FlashController.shared.rebuildRail() }
        }
    }

    /// The steady edge light that stays up while something waits on you —
    /// the part the Titan's LED does and a 3s animation doesn't.
    private var railWindows: [OverlayWindow] = []
    private var railKind: AlertKind?
    /// The screen frames the rail was drawn for. macOS posts "screen
    /// parameters changed" for more than display changes (the Dock, menu
    /// bar, Spaces), so a rebuild checks this before tearing the rail down.
    private var railScreens: [CGRect] = []

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
    /// What each active trigger is about, so reminders and resolves use
    /// the right look. Missing = `.auth`.
    private var triggerKinds: [String: AlertKind] = [:]

    /// Shortest an alert stays up before a touch may cut it. A ready hand
    /// answers inside a second, and the comet then faded in 0.18s: it looked
    /// like Flash never fired. Slower touches are unaffected.
    private let minimumAlertTime: TimeInterval = 1.2

    /// Longest we'll trust a trigger to resolve itself. If an engine dies
    /// mid-prompt (killed process, crashed helper, unplugged key) without
    /// ever calling `resolve`, the id would otherwise stay in `activeTriggers`
    /// forever — silently swallowing every future `trigger(id)` call, since
    /// the guard below treats "already active" as "already alerting". This
    /// caps that blast radius regardless of why resolve never came.
    private let watchdogTimeout: Duration = .seconds(45)
    /// An agent can sit on a permission prompt for minutes while you're
    /// away; that's the case worth reminding about, so it gets longer.
    private let agentWatchdogTimeout: Duration = .seconds(600)

    /// Begin an alert for a trigger. Ignored if that trigger is already active.
    func trigger(_ id: String, kind: AlertKind = .auth) {
        guard !activeTriggers.contains(id) else { return }
        activeTriggers.insert(id)
        triggerKinds[id] = kind
        lastAlertAt = Date()
        successResetTask?.cancel()
        iconState = restingState()
        pulseAll(kind: kind)
        scheduleReminder()
        scheduleWatchdog(id, timeout: kind == .agentWaiting ? agentWatchdogTimeout : watchdogTimeout)
    }

    /// Something worth seeing that nobody has to answer (an agent read a
    /// secret): one alert, no trigger state, no reminders.
    func notice(_ kind: AlertKind) {
        lastAlertAt = Date()
        pulseAll(kind: kind)
        if kind == .secretAccess {
            unseenSecrets += 1
            if !iconState.isAlerting && iconState != .success { iconState = restingState() }
        }
    }

    /// You opened the panel or Activity: the secret reads have been seen.
    func markSecretsSeen() {
        guard unseenSecrets > 0 else { return }
        unseenSecrets = 0
        if iconState == .secretRead { iconState = restingState() }
    }

    /// What the icon shows when nothing is animating: the most urgent
    /// thing waiting on you, else an unseen secret read, else idle.
    private func restingState() -> IconState {
        if let kind = topKind { return .alerting(kind) }
        return unseenSecrets > 0 ? .secretRead : .idle
    }

    /// A key prompt outranks an agent: it times out on its own.
    private var topKind: AlertKind? {
        guard !activeTriggers.isEmpty else { return nil }
        let kinds = activeTriggers.map { triggerKinds[$0] ?? .auth }
        return kinds.contains(.auth) ? .auth : .agentWaiting
    }

    /// The prompt ended. `success` = answered (key touched, password entered);
    /// `false` = cancelled or vanished without an answer.
    func resolve(_ id: String, success: Bool) {
        guard activeTriggers.remove(id) != nil else { return }
        watchdogTasks[id]?.cancel()
        watchdogTasks[id] = nil
        let kind = triggerKinds.removeValue(forKey: id) ?? .auth

        if success && kind != .auth {
            // An approved agent prompt isn't a key touch: no count, no ripple.
            fadeAfterMinimum(celebrate: false)
            iconState = restingState()
        } else if success {
            recordTouch()
            fadeAfterMinimum(celebrate: FlashSettings.shared.successRipple)
            iconState = .success
            successResetTask?.cancel()
            successResetTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled, let self, self.iconState == .success else { return }
                self.iconState = self.restingState()
            }
        } else {
            iconState = restingState()
        }

        if activeTriggers.isEmpty {
            reminderTask?.cancel()
            reminderTask = nil
        }
        updateRail()
    }

    /// Fades the alert once it has been up `minimumAlertTime`. Only the
    /// windows up now: an alert that starts during the wait must keep running.
    private func fadeAfterMinimum(celebrate: Bool) {
        let shown = alertWindows
        let wait = minimumAlertTime - Date().timeIntervalSince(lastAlertAt ?? .distantPast)
        Task { [weak self] in
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            shown.forEach { $0.fadeOut() }
            if celebrate { self?.celebrateAll() }
        }
    }

    /// Hard reset — used when watching is paused.
    func resolveAll() {
        dismissAlerts()
        activeTriggers.removeAll()
        triggerKinds.removeAll()
        reminderTask?.cancel()
        reminderTask = nil
        successResetTask?.cancel()
        watchdogTasks.values.forEach { $0.cancel() }
        watchdogTasks.removeAll()
        updateRail()
        iconState = restingState()
    }

    /// Manual pulse from the menu or Settings: no trigger state, just the fireworks.
    func testPulse(_ kind: AlertKind = .auth) {
        pulseAll(kind: kind)
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
    /// skip the finesse and go full classic. Reduce Motion gets one fade in
    /// and out instead, no motion and no blinking: classic blinks the whole
    /// border, the opposite of what that setting asks for.
    private func pulseAll(kind: AlertKind, escalated: Bool = false) {
        let settings = FlashSettings.shared
        let calm = reduceMotion
        let style: AlertStyle = escalated ? .classic : settings.style(for: kind)
        let preset = settings.color(for: kind)
        let count = settings.flashCount
        let passes = cometPasses
        // Resolved once per pulse, not per screen, so a "random" roll shows
        // the same colors on every display and the glow matches the stroke.
        let gradient = preset == .random ? FlashColor.randomVividGradient() : preset.gradient
        let glow = gradient[0]
        Log.write("[controller] alert — \(calm ? "steady (Reduce Motion)" : style.rawValue)\(kind == .auth ? "" : " for \(kind.rawValue)")\(escalated ? " (escalated)" : "")")

        for screen in NSScreen.screens {
            let window = OverlayWindow(screen: screen) { frame in
                if calm { return SteadyFadeView(frame: frame, gradient: gradient, glowColor: glow) }
                switch style {
                case .comet:
                    return CometChaseView(frame: frame, gradient: gradient, glowColor: glow, passes: passes)
                case .marquee:
                    return MarqueeView(frame: frame, gradient: gradient)
                case .targetLock:
                    return TargetLockView(frame: frame, gradient: gradient, glowColor: glow)
                case .heartbeat:
                    return HeartbeatView(frame: frame, gradient: gradient, glowColor: glow)
                case .shockwave:
                    return ShockwaveView(frame: frame, gradient: gradient, glowColor: glow)
                case .supernova:
                    return SupernovaView(frame: frame, gradient: gradient, glowColor: glow)
                case .lightning:
                    return LightningView(frame: frame, gradient: gradient, glowColor: glow)
                case .aurora:
                    return AuroraView(frame: frame, gradient: gradient)
                case .breathe:
                    return BreatheView(frame: frame, gradient: gradient, glowColor: glow)
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
                    // The animation's done; if it's still waiting on you, the
                    // light stays on.
                    self?.updateRail()
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

    // MARK: Hold rail

    /// Shows, recolours or clears the steady rail to match what's waiting.
    private func updateRail() {
        let want: AlertKind? = FlashSettings.shared.holdUntilAnswered ? topKind : nil
        guard want != railKind else { return }
        railWindows.forEach { $0.retire() }
        railWindows.removeAll()
        railKind = want
        guard let want else {
            Log.write("[controller] hold rail off")
            return
        }
        let preset = FlashSettings.shared.color(for: want)
        let gradient = preset == .random ? FlashColor.randomVividGradient() : preset.gradient
        let calm = reduceMotion
        for screen in NSScreen.screens {
            let window = OverlayWindow(screen: screen) { frame in HoldRailView(frame: frame, gradient: gradient, calm: calm) }
            // Under the alerts, so a reminder pulse draws over it.
            window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue)
            railWindows.append(window)
            window.play {}
        }
        railScreens = NSScreen.screens.map(\.frame)
        Log.write("[controller] hold rail on for \(want.rawValue) until it's answered")
    }

    /// A display came or went: redraw the rail on the screens there are now.
    fileprivate func rebuildRail() {
        guard railKind != nil else { return }
        let screens = NSScreen.screens.map(\.frame)
        guard screens != railScreens else { return }
        Log.write("[controller] displays changed: redrawing the hold rail on \(screens.count) screen(s)")
        railWindows.forEach { $0.retire() }
        railWindows.removeAll()
        railKind = nil
        updateRail()
    }

    private func scheduleWatchdog(_ id: String, timeout: Duration) {
        watchdogTasks[id]?.cancel()
        watchdogTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self, self.activeTriggers.contains(id) else { return }
            Log.write("[controller] '\(id)' never resolved within \(timeout) — clearing so it can rearm")
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
                self.pulseAll(kind: self.topKind ?? .auth, escalated: true)
            }
        }
    }
}
