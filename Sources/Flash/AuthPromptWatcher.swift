import AppKit
import CoreGraphics

/// Spots the system's "I need your say-so" dialogs: keychain access
/// ("… wants to use your confidential information"), admin passwords, Touch
/// ID sheets and GPG PIN entry. Those are the moments an agent's command
/// stalls silently behind whatever window you're looking at.
///
/// It polls the on-screen window list and matches on *owner process name*.
/// Owner names don't need Screen Recording permission (window titles do), so
/// this stays permission-free. The flip side: we know a dialog is up, not
/// which app asked. Good enough to get your eyes there.
final class AuthPromptWatcher {

    static let shared = AuthPromptWatcher()

    /// Processes that only ever draw auth UI. Sriinnu: if a prompt on your
    /// Mac doesn't trigger, run Flash with FLASH_DEBUG_WINDOWS=1 and look in
    /// Flash.log for its owner name, then add it here.
    static let owners: [String: String] = [
        "SecurityAgent": "Keychain / password dialog",
        "coreautha": "Touch ID / password dialog",
        "pinentry-mac": "GPG PIN",
    ]

    private let pollInterval: DispatchTimeInterval = .milliseconds(750)
    private var timer: DispatchSourceTimer?
    private var present: Set<String> = []
    private let debug = ProcessInfo.processInfo.environment["FLASH_DEBUG_WINDOWS"] == "1"
    private var lastOwners: Set<String> = []

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: pollInterval, leeway: .milliseconds(150))
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
        Log.write("[auth] watching for \(Self.owners.keys.sorted().joined(separator: ", "))")
    }

    func stop() {
        timer?.cancel()
        timer = nil
        for owner in present {
            Task { @MainActor in FlashController.shared.resolve("auth:\(owner)", success: false) }
        }
        present.removeAll()
        Log.write("[auth] stopped")
    }

    private func poll() {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return }

        var owners = Set<String>()
        for window in windows {
            if let owner = window[kCGWindowOwnerName as String] as? String {
                owners.insert(owner)
            }
        }

        if debug {
            for owner in owners.subtracting(lastOwners) {
                Log.write("[auth] debug: window owner appeared: \(owner)")
            }
            lastOwners = owners
        }

        let now = owners.intersection(Self.owners.keys)

        for owner in now.subtracting(present) {
            let label = Self.owners[owner] ?? owner
            Log.write("[auth] \(owner) dialog up — \(label)")
            Task { @MainActor in
                FlashController.shared.trigger("auth:\(owner)")
                ActivityLog.shared.record(ActivityEvent(
                    kind: .prompt,
                    repo: nil,
                    ref: nil,
                    summary: label,
                    sha: nil,
                    date: Date(),
                    actor: .unknown
                ))
            }
        }

        // Closed. Allowed or denied is invisible from here, so no green
        // ripple — success is only claimed when it's actually known.
        for owner in present.subtracting(now) {
            Log.write("[auth] \(owner) dialog closed")
            Task { @MainActor in FlashController.shared.resolve("auth:\(owner)", success: false) }
        }

        present = now
    }
}
