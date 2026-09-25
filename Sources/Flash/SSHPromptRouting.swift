import Foundation

/// Points ssh at `flash-askpass` for the whole login session, so passphrase,
/// PIN and key-touch prompts reach you as a dialog + flash instead of
/// stalling in a terminal nobody's watching. That matters most for agents
/// running inside GUI apps (Claude.app & co.), which never read your shell
/// profile — hence launchd's environment rather than `export` lines.
///
/// launchd forgets `setenv` on reboot. Flash re-applies it at every launch,
/// and with launch-at-login on, that covers it. Apps already running keep
/// their old environment until relaunched.
enum SSHPromptRouting {

    private static let keys = ["SSH_ASKPASS", "SSH_ASKPASS_REQUIRE"]

    static var askpassPath: String? {
        guard let path = Bundle.main.resourceURL?.appendingPathComponent("flash-askpass").path,
              FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }

    static func apply(enabled: Bool) {
        guard let askpass = askpassPath else {
            Log.write("[ssh] flash-askpass not in bundle — run from `make run`/`make install`, not `swift run`")
            return
        }
        if enabled {
            launchctl(["setenv", "SSH_ASKPASS", askpass])
            // force: use askpass even without DISPLAY, the macOS norm.
            launchctl(["setenv", "SSH_ASKPASS_REQUIRE", "force"])
            Log.write("[ssh] routing ssh prompts through \(askpass)")
        } else if launchctl(["getenv", "SSH_ASKPASS"])?.trimmingCharacters(in: .whitespacesAndNewlines) == askpass {
            // Only undo what we set — never clobber someone else's askpass.
            keys.forEach { launchctl(["unsetenv", $0]) }
            Log.write("[ssh] ssh prompt routing removed")
        }
    }

    @discardableResult
    private static func launchctl(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            Log.write("[ssh] launchctl \(arguments.first ?? "") failed: \(error.localizedDescription)")
            return nil
        }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }
}
