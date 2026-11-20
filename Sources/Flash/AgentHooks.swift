import Foundation
import FlashCore

/// Claude Code hook events, delivered by `tools/flash-agent-hook` as raw JSON
/// files in the inbox. Watch-only by construction: the hook runs async and
/// prints nothing, so Flash can see an agent but never approve or deny.
///
///   Notification (permission_prompt, …) → agent waiting: alert + log entry
///   PermissionRequest                   → what it asked for (fills the entry)
///   PostToolUse                         → it ran: resolve the wait; a secret
///                                         read nobody asked you about, or any
///                                         call that printed one → notice
///
/// The hook binary has already dropped the tool's output and redacted the
/// rest (FlashCore.HookPayload); `flash_output` is its verdict on what the
/// output held.
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
            let printed = OutputVerdict(payload[HookPayload.verdictKey])?.label
            let match = call.secretMatch
            guard match != nil || printed != nil else { return }
            let cutoff = Date().addingTimeInterval(-600)
            let yours = (askedYou[session]?[call.fingerprint] ?? .distantPast) > cutoff
            askedYou[session] = askedYou[session]?.filter { $0.value > cutoff }

            // What, why, how it got through, and what came out:
            // "keychain ANTHROPIC_API_KEY · auto-approved · printed keychain value"
            let why = match.map { m in call.keychainItem.map { "\(m.rule) \($0)" } ?? m.rule } ?? "output"
            let details = [why, yours ? "you approved" : "auto-approved"] + (printed.map { ["printed \($0)"] } ?? [])
            let who = agentName(payload)
            // "Claude · Opus 5.5 · Anthropic API": the model is best effort
            // (read from the transcript), so "model unknown" when it's missing.
            let identity = AgentIdentity(payload[AgentIdentity.payloadKey])
            let through = identity?.label.map { (identity?.model == nil ? "model unknown · " : "") + $0 }
            Log.write("[agent] secret access · \(details.joined(separator: " · ")) · \(who)"
                      + (through.map { " · \($0)" } ?? "") + " \(session.prefix(8)) in \(repo ?? "?")"
                      + " — \(call.summary)" + (match.map { " — matched «\($0.fragment)»" } ?? ""))
            ActivityLog.shared.record(ActivityEvent(
                kind: .secretAccess, repo: repo, ref: nil,
                summary: ([call.summary] + details + (identity?.model.map { [AgentIdentity.displayName($0)] } ?? []))
                    .joined(separator: " · "),
                sha: nil, date: Date(), actor: .agent(who)))
            // You already saw a prompted read; a printed secret is in the
            // agent's transcript now, so that one flashes either way.
            if !yours || printed != nil { FlashController.shared.notice(.secretAccess) }

        case "PostToolUseFailure", "PermissionDenied", "Stop", "UserPromptSubmit":
            finishWait(session, success: false)

        default:
            break
        }
    }

    /// "Claude", or "Claude · Explore" for a subagent's call.
    private static func agentName(_ payload: [String: Any]) -> String {
        guard let type = payload["agent_type"] as? String, !type.isEmpty else { return "Claude" }
        return "Claude · \(type)"
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
