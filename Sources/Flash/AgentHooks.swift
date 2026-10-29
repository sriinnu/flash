import Foundation

/// Claude Code hook events, delivered by `tools/flash-agent-hook` as raw JSON
/// files in the inbox. Watch-only by construction: the hook runs async and
/// prints nothing, so Flash can see an agent but never approve or deny.
///
///   Notification (permission_prompt, …) → agent waiting: alert + log entry
///   PermissionRequest                   → what it asked for (fills the entry)
///   PostToolUse                         → it ran: resolve the wait; a secret
///                                         read nobody asked you about → notice
///   PostToolUseFailure, Stop, …         → resolve without success
///
/// Claude Code doesn't say whether a call was auto-approved. A call that had
/// a PermissionRequest was put to you; one without wasn't.
@MainActor
enum AgentHookRouter {

    /// One empty file per waiting session. The hook script checks it so an
    /// ordinary tool call doesn't cost an inbox file.
    static let waitingDirectory = EventInbox.directory.deletingLastPathComponent()
        .appendingPathComponent("agent-waiting", isDirectory: true)

    /// Notification types that mean "blocked until you answer". idle_prompt
    /// (finished, waiting for your next message) isn't: it fires every turn.
    private static let waitingTypes: Set<String> = [
        "permission_prompt", "elicitation_dialog", "agent_needs_input",
    ]

    /// The two halves of a wait arrive in either order, a moment apart.
    private static var pendingSummary: [String: (text: String, at: Date)] = [:]
    private static var waitEntry: [String: (id: UUID, at: Date)] = [:]
    /// Calls put to you, per session, by fingerprint.
    private static var askedYou: [String: [String: Date]] = [:]

    static func handle(_ payload: [String: Any]) {
        guard let event = payload["hook_event_name"] as? String,
              let session = payload["session_id"] as? String else { return }
        let repo = (payload["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }

        switch event {
        case "PermissionRequest":
            let call = ToolCall(payload)
            askedYou[session, default: [:]][call.fingerprint] = Date()
            if let entry = waitEntry[session], Date().timeIntervalSince(entry.at) < 10 {
                ActivityLog.shared.updateSummary(id: entry.id, to: call.summary)
            } else {
                pendingSummary[session] = (call.summary, Date())
            }

        case "Notification":
            guard let type = payload["notification_type"] as? String, waitingTypes.contains(type) else { return }
            var summary = payload["message"] as? String ?? "Claude is waiting on you"
            if let pending = pendingSummary.removeValue(forKey: session),
               Date().timeIntervalSince(pending.at) < 10 {
                summary = pending.text
            }
            Log.write("[agent] waiting (\(type)) in \(repo ?? "?"): \(summary)")
            FlashController.shared.trigger(waitID(session), kind: .agentWaiting)
            setWaiting(session, true)
            let entry = ActivityEvent(kind: .agentWaiting, repo: repo, ref: nil, summary: summary,
                                      sha: nil, date: Date(), actor: .agent("Claude"))
            ActivityLog.shared.record(entry)
            waitEntry[session] = (entry.id, Date())

        case "PostToolUse":
            finishWait(session, success: true)
            let call = ToolCall(payload)
            guard call.touchesSecret else { return }
            let cutoff = Date().addingTimeInterval(-600)
            let yours = (askedYou[session]?[call.fingerprint] ?? .distantPast) > cutoff
            askedYou[session] = askedYou[session]?.filter { $0.value > cutoff }
            Log.write("[agent] secret access in \(repo ?? "?") (\(yours ? "you approved" : "auto-approved")): \(call.summary)")
            ActivityLog.shared.record(ActivityEvent(
                kind: .secretAccess, repo: repo, ref: nil,
                summary: call.summary + (yours ? " · you approved" : " · auto-approved"),
                sha: nil, date: Date(), actor: .agent("Claude")))
            // You already saw this one in a prompt; only the silent ones flash.
            if !yours { FlashController.shared.notice(.secretAccess) }

        case "PostToolUseFailure", "PermissionDenied", "Stop", "UserPromptSubmit":
            finishWait(session, success: false)

        default:
            break
        }
    }

    private static func waitID(_ session: String) -> String { "agent:\(session)" }

    private static func finishWait(_ session: String, success: Bool) {
        guard waitEntry.removeValue(forKey: session) != nil else { return }
        setWaiting(session, false)
        FlashController.shared.resolve(waitID(session), success: success)
    }

    private static func setWaiting(_ session: String, _ waiting: Bool) {
        // Session ids are UUIDs; anything else never becomes a path.
        guard UUID(uuidString: session) != nil else { return }
        let marker = waitingDirectory.appendingPathComponent(session)
        if waiting {
            try? FileManager.default.createDirectory(at: waitingDirectory, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: marker.path, contents: nil)
        } else {
            try? FileManager.default.removeItem(at: marker)
        }
    }
}

/// One tool call from a hook payload, described for a person.
struct ToolCall {
    let name: String
    let input: [String: Any]

    init(_ payload: [String: Any]) {
        name = payload["tool_name"] as? String ?? "tool"
        input = payload["tool_input"] as? [String: Any] ?? [:]
    }

    /// "Run `security find-generic-password -s github.com`", "Read ~/.ssh/config"
    var summary: String {
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
    var fingerprint: String {
        let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
        return name + ":" + (data.flatMap { String(data: $0, encoding: .utf8) } ?? "")
    }

    /// Keychain, password managers, SSH and signing keys, env files, the
    /// Apple dev vault. Keep in step with `secrets` in tools/flash-agent-hook,
    /// which filters before anything reaches the inbox.
    var touchesSecret: Bool {
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
