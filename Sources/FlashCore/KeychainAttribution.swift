import Foundation

/// One process, as much as Flash needs to say who asked for a keychain
/// dialog. `args` and `environment` are filled only for the processes an
/// attribution walks (reading them costs a sysctl each).
public struct ProcessRecord: Equatable {
    public let pid: Int32
    public let ppid: Int32
    public let name: String
    public let started: Date
    public var path = ""
    public var args: [String] = []
    /// Only the keys `KeychainAttribution` reads (CLAUDECODE, TERM_PROGRAM, …).
    public var environment: [String: String] = [:]

    public init(pid: Int32, ppid: Int32, name: String, started: Date,
                path: String = "", args: [String] = [], environment: [String: String] = [:]) {
        self.pid = pid
        self.ppid = ppid
        self.name = name
        self.started = started
        self.path = path
        self.args = args
        self.environment = environment
    }

    /// Environment keys worth keeping from KERN_PROCARGS2.
    public static let environmentKeys: Set<String> = ["CLAUDECODE", "CODEX_SANDBOX", "TERM_PROGRAM", "__CFBundleIdentifier"]

    /// KERN_PROCARGS2 layout: argc (Int32), exec path, NUL padding, argc
    /// NUL-terminated args, then the environment the same way.
    public static func parseProcArgs(_ bytes: [UInt8]) -> (path: String, args: [String], environment: [String: String])? {
        guard bytes.count > 4 else { return nil }
        let argc = Int(bytes.withUnsafeBytes { $0.load(as: Int32.self) })
        var index = 4
        func string() -> String? {
            guard index < bytes.count else { return nil }
            let start = index
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            let value = String(decoding: bytes[start..<index], as: UTF8.self)
            index += 1
            return value
        }
        guard let path = string() else { return nil }
        while index < bytes.count, bytes[index] == 0 { index += 1 }
        var args: [String] = []
        for _ in 0..<max(argc, 0) {
            guard let arg = string() else { break }
            args.append(arg)
        }
        var environment: [String: String] = [:]
        while let entry = string(), !entry.isEmpty {
            guard let eq = entry.firstIndex(of: "=") else { continue }
            let key = String(entry[..<eq])
            if environmentKeys.contains(key) { environment[key] = String(entry[entry.index(after: eq)...]) }
        }
        return (path, args, environment)
    }
}

/// Who is blocked on the keychain dialog that just appeared.
///
/// macOS doesn't say which process a SecurityAgent dialog is for, and
/// there's no public way to watch another process's keychain reads. But
/// the asking process is alive and waiting while the dialog is up, and a
/// command-line client (`security`, a git credential helper, `codesign`,
/// …) is visible in the process table with its arguments. So: the youngest
/// such client, its command line, and the chain of parents that started
/// it, which says agent or you.
///
/// A GUI app asking for its own item (a browser's Safe Storage) has no
/// client process; then there's no requester, and Flash says so.
public struct KeychainRequester: Equatable {
    public let pid: Int32
    /// "security find-generic-password -s github.com -w"
    public let command: String
    /// Parent names, nearest first: ["zsh", "claude", "Ghostty"].
    public let chain: [String]
    /// "Claude", "codex", …, when an agent started it.
    public let agent: String?
    /// Terminal or app it came from, when known.
    public let app: String?
    /// The keychain item, for `security find-*-password`.
    public let item: String?
    /// Other clients that started in the same window: when it's not 0, the
    /// pick is the youngest, not a certainty, and the log says so.
    public var others = 0

    /// "security find-generic-password -s X (pid 412) ← zsh ← claude"
    public var label: String {
        ([command + " (pid \(pid))"] + chain.prefix(4)).joined(separator: " ← ")
            + (others > 0 ? " (\(others) other candidate\(others == 1 ? "" : "s"))" : "")
    }
}

public enum KeychainAttribution {

    /// Command-line programs that talk to the keychain or raise the
    /// dialogs Flash watches for.
    public static let clients: Set<String> = [
        "security", "git-credential-osxkeychain", "git-credential-manager",
        "docker-credential-osxkeychain", "docker-credential-desktop",
        "ssh", "ssh-add", "ssh-keygen",
        "codesign", "productsign", "notarytool", "altool",
        "gpg", "gpg2", "op", "gh", "sudo", "su",
    ]
    // Not osascript: menu-bar widgets run it every few seconds, so it was
    // the "youngest client" for dialogs it had nothing to do with.

    /// Same list flash-notify walks the process tree with.
    static let agentPrefixes = ["claude", "codex", "ribhu", "aider", "cursor-agent", "gemini", "goose", "opencode"]

    /// Client processes started within `window` before `now`, youngest
    /// first. A CLI raises its dialog within a second or two of starting;
    /// 30s leaves room for codesign, which asks partway through.
    public static func candidates(in table: [Int32: ProcessRecord], at now: Date,
                                  window: TimeInterval = 30, clients: Set<String> = clients) -> [Int32] {
        table.values
            .filter { clients.contains($0.name) && now.timeIntervalSince($0.started) <= window
                && now.timeIntervalSince($0.started) >= -5 }
            .sorted { $0.started > $1.started }
            .map(\.pid)
    }

    /// The pid's ancestors, nearest first, stopping at launchd.
    public static func ancestors(of pid: Int32, in table: [Int32: ProcessRecord]) -> [ProcessRecord] {
        var chain: [ProcessRecord] = []
        var current = table[pid]?.ppid
        while let p = current, p > 1, let record = table[p], chain.count < 40 {
            chain.append(record)
            current = record.ppid
        }
        return chain
    }

    /// The name the hooks use for the same agent ("Claude"), so Activity
    /// doesn't show one agent under two spellings.
    static func agentName(_ prefix: String) -> String {
        prefix == "claude" ? "Claude" : prefix
    }

    /// Claude Code's native build names its process after its version
    /// ("2.1.326"); the binary's file name says more.
    static func displayName(_ record: ProcessRecord) -> String {
        let versionLike = !record.name.isEmpty && record.name.allSatisfy { $0.isNumber || $0 == "." }
        guard versionLike, !record.path.isEmpty else { return record.name }
        let base = URL(fileURLWithPath: record.path).lastPathComponent
        return base.allSatisfy({ $0.isNumber || $0 == "." }) && record.path.contains("/claude/") ? "claude" : base
    }

    /// Describe `pid`; its record and ancestors should carry args/env.
    public static func describe(_ pid: Int32, in table: [Int32: ProcessRecord]) -> KeychainRequester? {
        guard let record = table[pid] else { return nil }
        let chain = ancestors(of: pid, in: table)
        let command = record.args.isEmpty ? record.name : record.args.enumerated()
            .map { $0.offset == 0 ? URL(fileURLWithPath: $0.element).lastPathComponent : $0.element }
            .joined(separator: " ")

        var agent: String?
        if record.environment["CLAUDECODE"] == "1" || chain.contains(where: { $0.environment["CLAUDECODE"] == "1" }) {
            agent = "Claude"
        }
        if agent == nil {
            for ancestor in chain {
                let names = [ancestor.name, URL(fileURLWithPath: ancestor.path).lastPathComponent]
                    + ancestor.args.prefix(2).map { URL(fileURLWithPath: $0).lastPathComponent }
                if let prefix = agentPrefixes.first(where: { prefix in names.contains { $0.lowercased().hasPrefix(prefix) } }) {
                    agent = agentName(prefix)
                    break
                }
                // Claude Code's native build runs from …/claude/versions/<n>.
                if ancestor.path.contains("/claude/versions/") {
                    agent = "Claude"
                    break
                }
            }
        }

        let app = record.environment["TERM_PROGRAM"]
            ?? chain.compactMap { $0.environment["TERM_PROGRAM"] }.first
            ?? chain.compactMap { ancestor -> String? in
                guard let range = ancestor.path.range(of: ".app/Contents/MacOS/") else { return nil }
                return URL(fileURLWithPath: String(ancestor.path[..<range.lowerBound])).lastPathComponent
            }.first

        let item = ToolCall(["tool_name": "Bash", "tool_input": ["command": command]]).keychainItem
        return KeychainRequester(pid: pid, command: command, chain: chain.map(displayName),
                                 agent: agent, app: app, item: item)
    }
}
