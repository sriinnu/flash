import Foundation

/// One tool call from a hook payload, described for a person.
public struct ToolCall {
    public let name: String
    public let input: [String: Any]

    public init(_ payload: [String: Any]) {
        name = payload["tool_name"] as? String ?? "tool"
        input = payload["tool_input"] as? [String: Any] ?? [:]
    }

    /// What a secret rule matched, and where.
    public struct SecretMatch: Equatable {
        /// Rule name: "keychain", "ssh-key", "env-secret", …
        public let rule: String
        /// The text that matched, e.g. "security find-generic-password".
        public let fragment: String
        /// Which target string it was found in, and the UTF-16 range there.
        let target: Int
        let range: NSRange
    }

    // MARK: What the call reaches

    /// The strings that name a command, file or code this call runs or
    /// opens. Never prose: an Agent prompt that mentions ".env" reaches
    /// nothing, and neither does the text an Edit writes into a README.
    var targets: [String] {
        func string(_ key: String) -> [String] { (input[key] as? String).map { [$0] } ?? [] }
        switch name {
        case "Bash": return string("command")
        case "REPL": return string("code")
        case "Read", "Edit", "MultiEdit", "Write": return string("file_path")
        case "NotebookEdit": return string("notebook_path")
        case "Grep": return string("path") + string("glob")
        case "Glob": return string("pattern") + string("path")
        case "Agent", "Task", "SendMessage", "SubagentHandback", "TodoWrite", "AskUserQuestion",
             "WebFetch", "WebSearch", "Skill", "ExitPlanMode":
            return []
        default:
            // MCP and unknown tools: anything under a key that names a
            // command or path, at any depth.
            return Self.strings(in: input, keys: Self.targetKeys)
        }
    }

    /// The targets with written-only text blanked out (DataMask): what the
    /// secret rules scan. Same lengths, so match ranges fit `targets`.
    var scanTargets: [String] {
        switch name {
        case "Bash": return targets.map(DataMask.shell)
        case "REPL": return targets.map(DataMask.script)
        default: return targets
        }
    }

    static let targetKeys: Set<String> = [
        "command", "cmd", "code", "script", "path", "paths", "file", "files",
        "file_path", "filePath", "filename", "args", "argv", "directory", "dir",
    ]

    static func strings(in value: Any, keys: Set<String>, collecting: Bool = false) -> [String] {
        switch value {
        case let string as String: return collecting ? [string] : []
        case let array as [Any]: return array.flatMap { strings(in: $0, keys: keys, collecting: collecting) }
        case let dict as [String: Any]:
            return dict.keys.sorted().flatMap { key in
                strings(in: dict[key]!, keys: keys, collecting: collecting || keys.contains(key))
            }
        default: return []
        }
    }

    // MARK: Secret rules

    /// Keychain, password managers, token CLIs, SSH and signing keys,
    /// credential files, env secrets, the Apple dev vault. The hook binary
    /// and the app share this one list.
    static let rules: [(name: String, regex: NSRegularExpression)] = [
        ("keychain", #"(?i)\bsecurity\s+(?:find-(?:generic|internet)-password|dump-keychain|export|unlock-keychain|set-key-partition-list)\b|Library/Keychains|git-credential-osxkeychain"#),
        ("password-manager", #"(?i)\bop\s+(?:read|inject|run|signin|item\s+get|document\s+get)\b|\bbw\s+(?:get|unlock|export)\b|1password"#),
        ("token-cli", #"(?i)\bgh\s+auth\s+token\b|\bgcloud\s+auth\s+(?:application-default\s+)?print-(?:access|identity)-token\b|\baws\s+(?:configure\s+get|sts\s+get-session-token|ecr\s+get-login-password)\b|\baz\s+account\s+get-access-token\b|\bgit\s+credential\s+fill\b|\bnpm\s+token\b|\bkubectl\s+config\s+view\b[^|;&\n]*--raw"#),
        ("ssh-key", #"/\.ssh/|~/\.ssh\b|\bid_(?:rsa|ecdsa|ed25519|dsa)(?:_sk)?\b"#),
        ("key-file", #"(?i)\.(?:p12|p8|pem|pfx)\b"#),
        ("env-file", #"(?:^|[\s/'"=])\.env(?:\.(?!example\b|sample\b|template\b|dist\b)[\w-]+)?(?:$|[\s'";|&)])"#),
        ("credentials-file", #"\.aws/credentials|\.netrc\b|\.npmrc\b|\.pypirc\b|gh/hosts\.yml|\.claude/\.credentials\.json|\.docker/config\.json|\.kube/config\b|\.git-credentials\b|\.gnupg/|application_default_credentials\.json"#),
        ("gpg-secret", #"\bgpg2?\b[^|;&\n]*\s(?:--export-secret-(?:sub)?keys|--decrypt|-d)\b"#),
        // Case-sensitive on purpose: env var names are upper case, and
        // "$token" in a script is usually a local.
        ("env-secret", #"\bprintenv\b|(?:^|[|;&]\s*)env\s*(?:$|[|;&>])|\$\{![A-Za-z_]\w*\}|\$\{?[A-Z0-9_]*(?:TOKEN|SECRET|API_?KEY|PASSWORD|PASSWD|ACCESS_?KEY|PRIVATE_?KEY)\b"#),
        ("apple-dev-vault", #"(?i)apple-dev-account"#),
    ].map { ($0.0, try! NSRegularExpression(pattern: $0.1, options: [.anchorsMatchLines])) }

    /// The earliest secret match across this call's targets, if any.
    public var secretMatch: SecretMatch? {
        var best: SecretMatch?
        let originals = targets
        for (index, target) in scanTargets.enumerated() {
            let ns = originals[index] as NSString
            for rule in Self.rules {
                guard let match = rule.regex.firstMatch(in: target, range: NSRange(location: 0, length: ns.length))
                else { continue }
                if best == nil || index < best!.target || (index == best!.target && match.range.location < best!.range.location) {
                    let fragment = ns.substring(with: match.range).trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "/'\";|&)=")))
                    best = SecretMatch(rule: rule.name, fragment: fragment, target: index, range: match.range)
                }
            }
        }
        return best
    }

    public var touchesSecret: Bool { secretMatch != nil }

    /// The keychain item a `security find-*-password` names: its service
    /// (-s), else label (-l), else account (-a).
    public var keychainItem: String? {
        guard let command = scanTargets.first,
              let call = command.range(of: #"\bsecurity\s+find-(?:generic|internet)-password\b(?:"[^"]*"|'[^']*'|[^|;&\n)"'])*"#,
                                       options: .regularExpression)
        else { return nil }
        let args = String(command[call])
        for flag in ["s", "l", "a"] {
            let pattern = #"\s-"# + flag + #"\s+(?:"([^"]+)"|'([^']+)'|(\S+))"#
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: args, range: NSRange(args.startIndex..., in: args))
            else { continue }
            for group in 1...3 {
                if let range = Range(match.range(at: group), in: args) { return String(args[range]) }
            }
        }
        return nil
    }

    // MARK: Description

    /// "Run `security find-generic-password -s github.com`", "Read ~/.ssh/config".
    /// A long command is cut around its secret match, so the reason it was
    /// flagged is always on screen.
    public var summary: String {
        func path(_ key: String) -> String {
            let p = input[key] as? String ?? ""
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
        }
        switch name {
        case "Bash": return "Run \u{60}\(excerpt(input["command"] as? String ?? ""))\u{60}"
        case "REPL": return "Script \u{60}\(excerpt(input["code"] as? String ?? ""))\u{60}"
        case "Read": return "Read \(path("file_path"))"
        case "Edit", "MultiEdit", "Write": return "Edit \(path("file_path"))"
        case "NotebookEdit": return "Edit \(path("notebook_path"))"
        case "WebFetch": return "Fetch \(Self.oneLine(input["url"] as? String ?? "", 90))"
        case "Grep", "Glob": return "Search \(Self.oneLine(input["pattern"] as? String ?? "", 90)) \(path("path"))"
        default: return name.hasPrefix("mcp__") ? "Use \(name.dropFirst(5))" : name
        }
    }

    static func oneLine(_ text: String, _ limit: Int) -> String {
        let one = text.replacingOccurrences(of: "\n", with: " ")
        return one.count > limit ? String(one.prefix(limit)) + "…" : one
    }

    /// The first `width` characters, or a window around the secret match
    /// when that falls past them.
    func excerpt(_ text: String, width: Int = 90) -> String {
        let one = text.replacingOccurrences(of: "\n", with: " ")
        guard one.count > width else { return one }
        guard let match = secretMatch, match.target == 0,
              let range = Range(match.range, in: one), one.distance(from: one.startIndex, to: range.upperBound) > width
        else { return String(one.prefix(width)) + "…" }
        let start = one.index(range.lowerBound, offsetBy: -30, limitedBy: one.startIndex) ?? one.startIndex
        let end = one.index(start, offsetBy: width, limitedBy: one.endIndex) ?? one.endIndex
        return (start == one.startIndex ? "" : "…") + one[start..<end] + (end == one.endIndex ? "" : "…")
    }

    /// Pairs a PermissionRequest with its PostToolUse: tool plus the thing
    /// it targets, so extra or reordered input fields don't break the pair.
    public var fingerprint: String {
        if let target = targets.first { return name + ":" + target }
        let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
        return name + ":" + (data.flatMap { String(data: $0, encoding: .utf8) } ?? "")
    }
}
