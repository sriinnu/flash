import Foundation

/// Which model and which provider an agent's call went through.
///
/// Claude Code's tool hooks don't carry the model. Its transcript does:
/// every assistant line has `message.model`. That's an internal format, not
/// a promise, so a missing or changed field means "model unknown", never a
/// guess. The provider comes from Claude Code's own switches
/// (`CLAUDE_CODE_USE_BEDROCK`, …), which the hook inherits.
public struct AgentIdentity: Equatable {
    /// "claude-opus-5-5", as the transcript has it.
    public var model: String?
    /// "Anthropic API", "Bedrock", "Vertex", "Foundry", "proxy llm.corp.net".
    public var provider: String?

    public init(model: String? = nil, provider: String? = nil) {
        self.model = model
        self.provider = provider
    }

    public static let payloadKey = "flash_agent"

    public var dictionary: [String: Any] {
        var out: [String: Any] = [:]
        if let model { out["model"] = model }
        if let provider { out["provider"] = provider }
        return out
    }

    public init?(_ value: Any?) {
        guard let dict = value as? [String: Any] else { return nil }
        model = dict["model"] as? String
        provider = dict["provider"] as? String
    }

    /// "Opus 5.5 · Anthropic API"; nil when neither is known.
    public var label: String? {
        let parts = [model.map(Self.displayName), provider].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Model

    /// "claude-opus-5-5" → "Opus 5.5", "claude-sonnet-4-5-20250929" → "Sonnet 4.5",
    /// "us.anthropic.claude-haiku-4-5-20251001-v1:0" → "Haiku 4.5",
    /// "claude-3-5-sonnet-20241022" → "Sonnet 3.5". Anything else as given.
    public static func displayName(_ model: String) -> String {
        let id = model.lowercased()
        let patterns = [
            #"claude-([a-z]+)-(\d+)(?:-(\d{1,2}))?(?:-\d{8})?(?:\b|$)"#,
            #"claude-(\d+)(?:-(\d{1,2}))?-([a-z]+)"#,
        ]
        for (index, pattern) in patterns.enumerated() {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: id, range: NSRange(id.startIndex..., in: id)) else { continue }
            func group(_ n: Int) -> String? { Range(match.range(at: n), in: id).map { String(id[$0]) } }
            let (family, major, minor) = index == 0 ? (group(1), group(2), group(3)) : (group(3), group(1), group(2))
            guard let family, let major else { continue }
            return family.prefix(1).uppercased() + family.dropFirst() + " " + major + (minor.map { "." + $0 } ?? "")
        }
        return model
    }

    /// The model of the newest assistant line in a transcript's tail.
    public static func lastModel(inTranscript text: Substring) -> String? {
        for line in text.split(separator: "\n").reversed() {
            guard line.contains("\"model\""),
                  let data = line.data(using: .utf8),
                  let entry = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let message = entry["message"] as? [String: Any],
                  let model = message["model"] as? String,
                  !model.isEmpty, !model.hasPrefix("<") // "<synthetic>": Claude Code's own notes
            else { continue }
            return model
        }
        return nil
    }

    /// Reads the end of a transcript, growing the window until an assistant
    /// line turns up (a big tool result can push it back).
    public static func lastModel(transcriptAt path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return nil }
        for window in [UInt64(256 << 10), 2 << 20, 8 << 20] {
            let start = size > window ? size - window : 0
            try? handle.seek(toOffset: start)
            guard let data = try? handle.readToEnd() else { return nil }
            var text = Substring(String(decoding: data, as: UTF8.self))
            // The first line is cut mid-way unless we started at 0.
            if start > 0, let newline = text.firstIndex(of: "\n") { text = text[text.index(after: newline)...] }
            if let model = lastModel(inTranscript: text) { return model }
            if start == 0 { break }
        }
        return nil
    }

    /// A subagent writes its own transcript next to the session's:
    /// `<dir>/<session>/subagents/agent-<id>.jsonl`.
    public static func transcriptPath(for payload: [String: Any]) -> String? {
        guard let main = payload["transcript_path"] as? String, !main.isEmpty else { return nil }
        guard let agent = payload["agent_id"] as? String, !agent.isEmpty,
              agent.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return main }
        let session = URL(fileURLWithPath: main).deletingPathExtension()
        let sub = session.appendingPathComponent("subagents").appendingPathComponent("agent-\(agent).jsonl").path
        return FileManager.default.fileExists(atPath: sub) ? sub : main
    }

    // MARK: Provider

    /// Claude Code's provider from its environment.
    public static func claudeProvider(_ env: [String: String]) -> String {
        func on(_ key: String) -> Bool {
            guard let value = env[key]?.lowercased() else { return false }
            return !value.isEmpty && value != "0" && value != "false"
        }
        if on("CLAUDE_CODE_USE_BEDROCK") { return "Bedrock" }
        if on("CLAUDE_CODE_USE_VERTEX") { return "Vertex" }
        if on("CLAUDE_CODE_USE_FOUNDRY") { return "Foundry" }
        if on("CLAUDE_CODE_USE_MANTLE") { return "Mantle" }
        if let base = env["ANTHROPIC_BASE_URL"], !base.isEmpty,
           let host = URL(string: base)?.host, host != "api.anthropic.com" {
            return "proxy \(host)"   // host only: a base URL can carry a key
        }
        return "Anthropic API"
    }

    /// The env keys `claudeProvider` reads (for reading another process's).
    public static let providerKeys: Set<String> = [
        "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
        "CLAUDE_CODE_USE_MANTLE", "ANTHROPIC_BASE_URL",
    ]
}
