import Foundation

/// What Flash does with a Claude Code hook payload before it touches disk.
/// The hook binary calls this; the app only ever sees the result.
public enum HookPayload {

    /// Set in place of `tool_response`: what the tool printed, judged, not kept.
    public static let verdictKey = "flash_output"

    /// Notification and PermissionRequest always (rare, and the point);
    /// PostToolUse when it touched a secret or printed one; the rest only
    /// while that session is waiting on you, to resolve the alert.
    public static func shouldForward(_ payload: [String: Any], waiting: Bool) -> Bool {
        switch payload["hook_event_name"] as? String {
        case "Notification", "PermissionRequest":
            return true
        case "PostToolUse":
            return waiting || ToolCall(payload).touchesSecret || OutputVerdict(judging: payload).found
        case "PostToolUseFailure", "PermissionDenied", "Stop", "UserPromptSubmit":
            return waiting
        default:
            return false
        }
    }

    /// The payload minus the tool's output (a verdict instead), every
    /// remaining string redacted.
    public static func sanitize(_ payload: [String: Any]) -> [String: Any] {
        var clean = payload
        if payload["tool_response"] != nil {
            clean[verdictKey] = OutputVerdict(judging: payload).dictionary
        }
        clean.removeValue(forKey: "tool_response")
        return Redact.json(clean) as? [String: Any] ?? [:]
    }
}

/// "Did the agent print a secret?" — decided from the tool's output, which
/// is then thrown away.
public struct OutputVerdict: Equatable {
    /// Bytes of output judged.
    public var bytes = 0
    /// Secret shapes seen in the output ("github-token", …).
    public var kinds: [String] = []
    /// A `security find-*-password -w/-g` whose value went to the output
    /// rather than into a variable.
    public var keychainValue = false

    public var found: Bool { keychainValue || !kinds.isEmpty }

    /// "github-token, keychain value"; nil when nothing was found.
    public var label: String? {
        let parts = kinds + (keychainValue ? ["keychain value"] : [])
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    public init(bytes: Int = 0, kinds: [String] = [], keychainValue: Bool = false) {
        self.bytes = bytes
        self.kinds = kinds
        self.keychainValue = keychainValue
    }

    /// From a raw payload (in the hook, before sanitizing).
    public init(judging payload: [String: Any]) {
        guard let response = payload["tool_response"],
              !Self.echoesInput.contains(payload["tool_name"] as? String ?? "")
        else { return }
        let output = Self.strings(in: response).joined(separator: "\n")
        bytes = output.utf8.count
        kinds = Redact.kinds(in: output)
        let command = (payload["tool_input"] as? [String: Any])?["command"] as? String ?? ""
        keychainValue = Self.printsKeychainValue(command) && Self.looksLikeValue(output)
    }

    /// From a sanitized payload's `flash_output` (in the app).
    public init?(_ value: Any?) {
        guard let dict = value as? [String: Any] else { return nil }
        bytes = dict["bytes"] as? Int ?? 0
        kinds = dict["kinds"] as? [String] ?? []
        keychainValue = dict["keychainValue"] as? Bool ?? false
    }

    /// Tools whose output is the agent's own input handed back (the file it
    /// just wrote, the patch it made). Nothing new was revealed.
    static let echoesInput: Set<String> = ["Edit", "MultiEdit", "Write", "NotebookEdit", "TodoWrite"]

    var dictionary: [String: Any] {
        ["bytes": bytes, "kinds": kinds, "keychainValue": keychainValue]
    }

    /// A `security find-generic-password … -w` (or `-g`) that isn't inside
    /// `$( … )` or backticks, so its value lands in the output.
    private static let keychainLookup = try! NSRegularExpression(
        pattern: #"\bsecurity\s+find-(?:generic|internet)-password\b(?:"[^"]*"|'[^']*'|[^|;&\n)"'])*?\s-[a-zA-Z]*[wg]\b"#)

    static func printsKeychainValue(_ command: String) -> Bool {
        let regex = keychainLookup
        let ns = command as NSString
        for match in regex.matches(in: command, range: NSRange(location: 0, length: ns.length)) {
            let before = ns.substring(to: match.range.location)
            let opened = before.components(separatedBy: "$(").count - 1
            let closed = before.components(separatedBy: ")").count - 1
            let ticks = before.filter { $0 == "\u{60}" }.count
            if opened <= closed && ticks % 2 == 0 { return true }
        }
        return false
    }

    /// Something other than security(1)'s "not found" chatter.
    static func looksLikeValue(_ output: String) -> Bool {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4 else { return false }
        return !trimmed.contains("could not be found") && !trimmed.hasPrefix("security: ")
    }

    static func strings(in value: Any) -> [String] {
        switch value {
        case let string as String: return [string]
        case let array as [Any]: return array.flatMap(strings)
        case let dict as [String: Any]: return dict.keys.sorted().flatMap { strings(in: dict[$0]!) }
        default: return []
        }
    }
}
