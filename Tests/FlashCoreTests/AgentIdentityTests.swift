import Foundation
import Testing
@testable import FlashCore

@Suite struct AgentIdentityTests {

    static let names: [(String, String)] = [
        ("claude-opus-5-5", "Opus 5.5"),
        ("claude-fable-5-2", "Fable 5.2"),
        ("claude-sonnet-4-5-20250929", "Sonnet 4.5"),
        ("claude-opus-4-20250514", "Opus 4"),
        ("us.anthropic.claude-haiku-4-5-20251001-v1:0", "Haiku 4.5"),
        ("claude-3-5-sonnet-20241022", "Sonnet 3.5"),
        ("gpt-5-codex", "gpt-5-codex"),
    ]

    @Test(arguments: names) func displayNames(_ pair: (String, String)) {
        #expect(AgentIdentity.displayName(pair.0) == pair.1)
    }

    @Test func providerFromClaudeCodeSwitches() {
        #expect(AgentIdentity.claudeProvider([:]) == "Anthropic API")
        #expect(AgentIdentity.claudeProvider(["CLAUDE_CODE_USE_BEDROCK": "1"]) == "Bedrock")
        #expect(AgentIdentity.claudeProvider(["CLAUDE_CODE_USE_VERTEX": "true"]) == "Vertex")
        #expect(AgentIdentity.claudeProvider(["CLAUDE_CODE_USE_BEDROCK": "0"]) == "Anthropic API")
        #expect(AgentIdentity.claudeProvider(["ANTHROPIC_BASE_URL": "https://api.anthropic.com"]) == "Anthropic API")
        // A base URL can carry a key: only the host is kept.
        let keyed = "https://" + "u:" + "k" + "@llm.corp.net/v1"
        #expect(AgentIdentity.claudeProvider(["ANTHROPIC_BASE_URL": keyed]) == "proxy llm.corp.net")
    }

    func line(_ type: String, _ model: String?) -> String {
        var message: [String: Any] = ["role": type]
        if let model { message["model"] = model }
        let data = try! JSONSerialization.data(withJSONObject: ["type": type, "message": message])
        return String(decoding: data, as: UTF8.self)
    }

    @Test func newestRealModelWins() {
        let text = [line("assistant", "claude-sonnet-4-5"), line("user", nil),
                    line("assistant", "claude-opus-5-5"), line("assistant", "<synthetic>"), "{not json"]
            .joined(separator: "\n")
        #expect(AgentIdentity.lastModel(inTranscript: Substring(text)) == "claude-opus-5-5")
        #expect(AgentIdentity.lastModel(inTranscript: Substring(line("user", nil))) == nil)
    }

    @Test func readsPastABigToolResult() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("s.jsonl").path
        // 600 KB of tool output after the assistant line: past the first window.
        let big = line("user", nil).replacingOccurrences(of: "user\"}", with: "user\", \"pad\": \"" + String(repeating: "x", count: 600_000) + "\"}")
        try ([line("assistant", "claude-opus-5-5"), big].joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        #expect(AgentIdentity.lastModel(transcriptAt: path) == "claude-opus-5-5")
        #expect(AgentIdentity.lastModel(transcriptAt: dir.appendingPathComponent("none").path) == nil)
    }

    @Test func subagentsUseTheirOwnTranscript() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sub = dir.appendingPathComponent("abc/subagents")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let main = dir.appendingPathComponent("abc.jsonl").path
        FileManager.default.createFile(atPath: sub.appendingPathComponent("agent-a1.jsonl").path, contents: Data())
        #expect(AgentIdentity.transcriptPath(for: ["transcript_path": main, "agent_id": "a1"]) == sub.appendingPathComponent("agent-a1.jsonl").path)
        #expect(AgentIdentity.transcriptPath(for: ["transcript_path": main, "agent_id": "missing"]) == main)
        #expect(AgentIdentity.transcriptPath(for: ["transcript_path": main, "agent_id": "../../etc"]) == main)
        #expect(AgentIdentity.transcriptPath(for: ["transcript_path": main]) == main)
    }

    @Test func labelSaysWhatIsKnown() {
        #expect(AgentIdentity(model: "claude-opus-5-5", provider: "Anthropic API").label == "Opus 5.5 · Anthropic API")
        #expect(AgentIdentity(model: nil, provider: "Bedrock").label == "Bedrock")
        #expect(AgentIdentity().label == nil)
        #expect(AgentIdentity(AgentIdentity(model: "m", provider: "p").dictionary) == AgentIdentity(model: "m", provider: "p"))
    }
}
