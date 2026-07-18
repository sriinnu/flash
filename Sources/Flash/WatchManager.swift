import Foundation

/// Owns every detection engine (FIDO sniffer today, AX watchers next) and
/// starts/stops them as one. Toggled from the menu bar, persisted across
/// launches via the `watchingEnabled` default.
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
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        FidoSniffer.shared.stop()
        Task { @MainActor in FlashController.shared.resolveAll() }
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
