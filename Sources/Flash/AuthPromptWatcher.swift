import AppKit
import CoreGraphics
import FlashCore

/// Spots the system's "I need your say-so" dialogs: keychain access
/// ("… wants to use your confidential information"), admin passwords, Touch
/// ID sheets and GPG PIN entry. Those are the moments an agent's command
/// stalls silently behind whatever window you're looking at.
///
/// It polls the on-screen window list and matches on *owner process name*.
/// Owner names don't need Screen Recording permission (window titles do), so
/// this stays permission-free. The dialog itself doesn't say which app
/// asked; `ProcessSnapshot.keychainRequester` finds the command-line client
/// blocked on it (and who started that), so the log reads "asked by
/// `security find-generic-password -s X` ← zsh ← claude".
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
    /// When each dialog appeared, for "closed after 4s".
    private var appeared: [String: Date] = [:]
    private let probeQueue = DispatchQueue(label: "flash.auth.requester", qos: .userInitiated)
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
        var geometry: [String: String] = [:]
        for window in windows {
            if let owner = window[kCGWindowOwnerName as String] as? String {
                owners.insert(owner)
                if Self.owners[owner] != nil, geometry[owner] == nil {
                    geometry[owner] = Self.describe(window)
                }
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
            let shape = geometry[owner] ?? "?"
            appeared[owner] = Date()
            Task { @MainActor in FlashController.shared.trigger("auth:\(owner)") }
            // The asker is blocked until the dialog goes, so it's still in the
            // process table; read it off the main queue (a sysctl per parent).
            probeQueue.async {
                let requester = ProcessSnapshot.keychainRequester()
                let who = requester.map { r in "asked by \(r.label)" + (r.context.isEmpty ? "" : " — \(r.context)") }
                    ?? "asker not found (an app, not a command-line tool)"
                Log.write("[auth] \(owner) dialog up — \(label) — \(who) — window \(shape)")
                Task { @MainActor in
                    ActivityLog.shared.record(ActivityEvent(
                        kind: .prompt,
                        repo: requester?.project,
                        ref: requester?.branch,
                        summary: requester.map { r in
                            [label, r.item.map { "item \($0)" } ?? r.credentialHost.map { "for \($0)" }, r.gitCommand ?? r.command, r.provider]
                                .compactMap { $0 }.joined(separator: " · ")
                        } ?? label,
                        sha: nil,
                        date: Date(),
                        actor: requester.map { r in r.agent.map { .agent($0) } ?? .you(r.app) } ?? .unknown
                    ))
                }
            }
        }

        // Closed. Allowed or denied is invisible from here, so no green
        // ripple — success is only claimed when it's actually known.
        for owner in present.subtracting(now) {
            let open = appeared.removeValue(forKey: owner).map { Date().timeIntervalSince($0) }
            Log.write("[auth] \(owner) dialog closed" + (open.map { String(format: " after %.1fs", $0) } ?? ""))
            Task { @MainActor in FlashController.shared.resolve("auth:\(owner)", success: false) }
        }

        present = now
    }

    /// "420×180 at 510,300, alpha 1, layer 2147483631": logged with every
    /// "dialog up", so a dialog that seems to stay up for hours leaves
    /// evidence of what window it really was.
    static func describe(_ window: [String: Any]) -> String {
        let bounds = (window[kCGWindowBounds as String] as? [String: CGFloat]) ?? [:]
        let alpha = window[kCGWindowAlpha as String] as? CGFloat ?? -1
        let layer = window[kCGWindowLayer as String] as? Int ?? -1
        return String(format: "%.0f×%.0f at %.0f,%.0f, alpha %.2g, layer %d",
                      bounds["Width"] ?? 0, bounds["Height"] ?? 0, bounds["X"] ?? 0, bounds["Y"] ?? 0, alpha, layer)
    }
}
