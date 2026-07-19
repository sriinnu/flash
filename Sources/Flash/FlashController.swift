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

    private var overlayWindows: [BorderWindow] = []
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

    private func pulseAll() {
        let preset = FlashSettings.shared.flashColor
        let count = FlashSettings.shared.flashCount
        // Resolved once per pulse, not per screen — see BorderWindow's init.
        let gradient = preset == .random ? FlashColor.randomVividGradient() : preset.gradient
        let glow = gradient[0]
        for screen in NSScreen.screens {
            let window = BorderWindow(screen: screen, gradient: gradient, glowColor: glow)
            overlayWindows.append(window)
            window.pulse(flashes: count) { [weak self] in
                Task { @MainActor in
                    self?.overlayWindows.removeAll { $0 === window }
                }
            }
        }
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
                self.pulseAll()
            }
        }
    }
}
