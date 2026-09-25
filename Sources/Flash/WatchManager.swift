import Foundation

/// Owns every detection engine (FIDO sniffer, signing signals, event inbox,
/// auth-prompt watcher, repo activity) and starts/stops them as one.
/// Toggled from the menu bar, persisted across launches via the
/// `watchingEnabled` default.
final class WatchManager: ObservableObject {

    static let shared = WatchManager()

    @Published private(set) var isRunning = false

    var enabledPreference: Bool {
        get { UserDefaults.standard.object(forKey: "watchingEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "watchingEnabled") }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true

        let sniffer = FidoSniffer.shared
        sniffer.onTouchNeeded = {
            Task { @MainActor in FlashController.shared.trigger("fido") }
        }
        sniffer.onTouchResolved = { success in
            Task { @MainActor in FlashController.shared.resolve("fido", success: success) }
        }
        sniffer.start()
        SignTrigger.shared.start()

        EventInbox.shared.onEvent = { fields in
            Task { @MainActor in InboxRouter.handle(fields) }
        }
        EventInbox.shared.start()
        startOptionalWatchers()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        FidoSniffer.shared.stop()
        SignTrigger.shared.stop()
        EventInbox.shared.stop()
        AuthPromptWatcher.shared.stop()
        RepoActivityWatcher.shared.stop()
        Task { @MainActor in FlashController.shared.resolveAll() }
    }

    /// Settings changed (toggles, watched folders): restart just the engines
    /// those settings drive. No-op while paused — `start()` reads them fresh.
    func reloadWatchers() {
        guard isRunning else { return }
        AuthPromptWatcher.shared.stop()
        RepoActivityWatcher.shared.stop()
        startOptionalWatchers()
    }

    private func startOptionalWatchers() {
        let settings = FlashSettings.shared
        if settings.watchAuthPrompts {
            AuthPromptWatcher.shared.start()
        }
        if settings.activityLogEnabled {
            RepoActivityWatcher.shared.start(roots: settings.watchRoots)
        }
    }

    func toggle() {
        if isRunning {
            enabledPreference = false
            stop()
        } else {
            enabledPreference = true
            start()
        }
    }
}
