import Dispatch
import Foundation

/// Catches SSH-commit-signing touch requests via SIGUSR1/SIGUSR2 from
/// `git-ssh-keygen-titan`, since libfido2 opens the key with
/// kIOHIDOptionsTypeSeizeDevice during signing — that evicts FidoSniffer's
/// non-exclusive HID listener for the whole transaction, so this trigger has
/// to come from the signing process itself rather than from watching the key.
final class SignTrigger {

    static let shared = SignTrigger()

    private var touchSource: DispatchSourceSignal?
    private var resolveSource: DispatchSourceSignal?

    private static let resultURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("flash-signing-result")

    func start() {
        guard touchSource == nil else { return }

        // Dispatch handles delivery off the raw signal handler, which is the
        // only async-signal-safe way to run real code on receipt in Swift.
        signal(SIGUSR1, SIG_IGN)
        signal(SIGUSR2, SIG_IGN)

        let touch = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        touch.setEventHandler {
            Log.write("[sign] SIGUSR1 — SSH signing wants a touch ⚡")
            Task { @MainActor in FlashController.shared.trigger("ssh-sign") }
        }
        touch.resume()
        touchSource = touch

        let resolve = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
        resolve.setEventHandler {
            let raw = try? String(contentsOf: Self.resultURL, encoding: .utf8)
            let exitCode = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
            let success = exitCode == "0"
            Log.write("[sign] SIGUSR2 — resolved, exit=\(exitCode ?? "?") success=\(success)")
            Task { @MainActor in FlashController.shared.resolve("ssh-sign", success: success) }
        }
        resolve.resume()
        resolveSource = resolve

        Log.write("[sign] listening for SIGUSR1/SIGUSR2")
    }

    func stop() {
        touchSource?.cancel()
        touchSource = nil
        resolveSource?.cancel()
        resolveSource = nil
        Log.write("[sign] stopped")
    }
}
