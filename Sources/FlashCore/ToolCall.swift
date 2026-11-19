import Foundation

/// One tool call from a hook payload, described for a person.
public struct ToolCall {
    public let name: String
    public let input: [String: Any]

    public init(_ payload: [String: Any]) {
        name = payload["tool_name"] as? String ?? "tool"
        input = payload["tool_input"] as? [String: Any] ?? [:]
    }

    /// "Run `security find-generic-password -s github.com`", "Read ~/.ssh/config"
    public var summary: String {
        func short(_ s: String, _ n: Int = 90) -> String {
            let one = s.replacingOccurrences(of: "\n", with: " ")
            return one.count > n ? String(one.prefix(n)) + "…" : one
        }
        func path(_ key: String) -> String {
            let p = input[key] as? String ?? ""
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
        }
        switch name {
        case "Bash": return "Run `\(short(input["command"] as? String ?? ""))`"
        case "Read": return "Read \(path("file_path"))"
        case "Edit", "MultiEdit", "Write": return "Edit \(path("file_path"))"
        case "NotebookEdit": return "Edit \(path("notebook_path"))"
        case "WebFetch": return "Fetch \(short(input["url"] as? String ?? ""))"
        case "Grep", "Glob": return "Search \(short(input["pattern"] as? String ?? "")) \(path("path"))"
        default: return name.hasPrefix("mcp__") ? "Use \(name.dropFirst(5))" : name
        }
    }

    /// Same call, same string: pairs a PermissionRequest with its PostToolUse.
    public var fingerprint: String {
        let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
        return name + ":" + (data.flatMap { String(data: $0, encoding: .utf8) } ?? "")
    }

    /// Keychain, password managers, SSH and signing keys, env files, the
    /// Apple dev vault. The hook binary and the app share this one copy.
    public var touchesSecret: Bool {
        let text = ([name] + input.values.compactMap { $0 as? String }).joined(separator: " ")
        return Self.secretPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static let secretPattern = try! NSRegularExpression(
        pattern: [
            #"\bsecurity\s+(find-(generic|internet)-password|dump-keychain|export|unlock-keychain)"#,
            #"\bop\s+(read|inject|run|signin|item\s+get)\b"#,
            #"\bbw\s+(get|unlock|export)\b"#,
            #"\bgh\s+auth\s+token\b"#,
            #"/\.ssh/|~/\.ssh\b"#,
            #"\bid_(rsa|ecdsa|ed25519)(_sk)?\b"#,
            #"apple-dev-account|Library/Keychains|1password"#,
            #"(^|[\s/'"])\.env(\.[\w-]+)?($|[\s'"])"#,
            #"\.(p12|p8|pem)\b"#,
        ].joined(separator: "|"),
        options: [.caseInsensitive])
}
