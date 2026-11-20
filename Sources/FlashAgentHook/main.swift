import Foundation
import FlashCore

// flash-agent-hook: the Claude Code hook that tells Flash what an agent did.
// Settings point at Contents/Resources/flash-agent-hook, a shim that execs
// this binary (Contents/MacOS/flash-agent-hook).
//
// Reads the hook JSON from stdin, keeps only what Flash needs, and writes it
// to Flash's inbox. Before anything touches disk the tool's output is
// replaced by a verdict (did it print a secret?) and every string is
// redacted (FlashCore.HookPayload). It prints nothing, so it can't approve,
// deny or change a call: Flash watches agents, it doesn't steer them.
//
// No inbox (Flash never ran here) → does nothing. Every failure exits 0:
// a broken hook must never get in the agent's way.

let environment = ProcessInfo.processInfo.environment
let inbox = URL(fileURLWithPath: environment["FLASH_INBOX"]
    ?? NSHomeDirectory() + "/Library/Application Support/Flash/inbox", isDirectory: true)

var isDirectory: ObjCBool = false
guard FileManager.default.fileExists(atPath: inbox.path, isDirectory: &isDirectory), isDirectory.boolValue
else { exit(0) }

let input = FileHandle.standardInput.readDataToEndOfFile()
guard !input.isEmpty,
      let payload = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any]
else { exit(0) }

/// Flash marks a session that's waiting on you; markers it forgot to clear
/// (a crash) stop counting after 15 minutes.
func isWaiting(_ session: String?) -> Bool {
    guard let session, UUID(uuidString: session) != nil else { return false }
    let marker = inbox.deletingLastPathComponent()
        .appendingPathComponent("agent-waiting", isDirectory: true)
        .appendingPathComponent(session)
    guard let modified = (try? FileManager.default.attributesOfItem(atPath: marker.path))?[.modificationDate] as? Date
    else { return false }
    return Date().timeIntervalSince(modified) < 15 * 60
}

guard HookPayload.shouldForward(payload, waiting: isWaiting(payload["session_id"] as? String)) else { exit(0) }

// Model and provider: the transcript's newest assistant line (the
// subagent's own transcript for a subagent's call) and Claude Code's
// provider switches, which this process inherits.
var forwarded = HookPayload.sanitize(payload)
let identity = AgentIdentity(
    model: AgentIdentity.transcriptPath(for: payload).flatMap(AgentIdentity.lastModel(transcriptAt:)),
    provider: AgentIdentity.claudeProvider(environment))
forwarded[AgentIdentity.payloadKey] = identity.dictionary

guard let output = try? JSONSerialization.data(withJSONObject: forwarded) else { exit(0) }

// Hidden temp name (the drain skips dotfiles), private from the first byte,
// then one rename so Flash never reads half a file.
let stamp = Int(Date().timeIntervalSince1970)
let suffix = "\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
let tmp = inbox.appendingPathComponent(".tmp.\(suffix)")
let final = inbox.appendingPathComponent("\(stamp)-\(suffix).hook")
guard FileManager.default.createFile(atPath: tmp.path, contents: output, attributes: [.posixPermissions: 0o600])
else { exit(0) }
if rename(tmp.path, final.path) != 0 { unlink(tmp.path) }
exit(0)
