import Foundation
import Testing
@testable import FlashCore

/// Fakes are assembled at run time so the repo never holds a token-shaped
/// literal for a scanner (or a person) to trip on.
private func fake(_ prefix: String, _ count: Int = 36) -> String {
    prefix + String(repeating: "aB3x", count: count / 4 + 1).prefix(count)
}

@Suite struct RedactTests {

    static let shapes: [(String, String)] = [
        ("anthropic-key", fake("sk-ant-api03-", 40)),
        ("openai-key", fake("sk-proj-", 40)),
        ("github-token", fake("ghp_")),
        ("github-token", fake("github_pat_", 60)),
        ("gitlab-token", fake("glpat-", 20)),
        ("aws-key-id", "AKIA" + "ABCDEFGHIJKLMNOP"),
        ("slack-token", fake("xoxb-", 30)),
        ("google-key", fake("AIza", 35)),
        ("npm-token", fake("npm_", 36)),
        ("huggingface-token", fake("hf_", 34)),
        ("stripe-key", fake("sk_" + "live_", 24)),
        ("jwt", "eyJ" + fake("", 20) + "." + fake("", 24) + "." + fake("", 24)),
    ]

    @Test(arguments: shapes)
    func masksTokenShapes(kind: String, token: String) {
        let line = "curl -s https://api.example.com -d key=\(token) && echo done"
        let out = Redact.text(line)
        #expect(!out.contains(token))
        #expect(out.contains("[REDACTED"))
        #expect(Redact.kinds(in: line).contains(kind))
    }

    @Test func masksPrivateKeyBlock() {
        let label = "OPENSSH " + "PRIVATE KEY"
        let pem = "-----BEGIN \(label)-----\n" + fake("", 64) + "\n-----END \(label)-----"
        let out = Redact.text("cat ~/.ssh/id_ed25519\n" + pem)
        #expect(!out.contains(fake("", 64)))
        #expect(out.contains("[REDACTED private-key]"))
    }

    @Test func masksHeadersURLsFlagsAndAssignments() {
        let secret = fake("v9", 13)
        let cases = [
            "curl -H 'Authorization: Bearer \(secret)xyz' https://x",
            "git clone https://" + "someone:" + secret + "@github.com/o/r",
            "mysql --password=\(secret)",
            "op signin --token \(secret)",
            "export GITHUB_TOKEN=\(secret)",
            "API_KEY='\(secret)' npm run",
            #"{"client_secret": "\#(secret)"}"#,
        ]
        for line in cases {
            #expect(!Redact.text(line).contains(secret), "leaked in: \(line)")
        }
    }

    /// Commands that name a secret without holding one stay readable.
    @Test func leavesReferencesAlone() {
        let lines = [
            #"[ "$ANTHROPIC_API_KEY" = "$(security find-generic-password -s ANTHROPIC_API_KEY -w 2>/dev/null)" ]"#,
            "export GITHUB_TOKEN=$(gh auth token)",
            "TOKEN=$" + "{TOKEN:-}",
            "git config --get user.signingkey",
            "ls ~/.ssh && cat ~/.ssh/config",
        ]
        for line in lines {
            #expect(Redact.text(line) == line, "changed: \(line)")
        }
    }

    @Test func isIdempotent() {
        let once = Redact.text("GITHUB_TOKEN=\(fake("ghp_")) and Bearer \(fake("", 30))")
        #expect(Redact.text(once) == once)
    }

    @Test func redactsInsideJSON() throws {
        let token = fake("ghp_")
        let value = try #require(Redact.json(["a": ["b": "x \(token)"], "n": 3]) as? [String: Any])
        let data = try JSONSerialization.data(withJSONObject: value)
        #expect(!String(decoding: data, as: UTF8.self).contains(token))
    }
}

@Suite struct HookPayloadTests {

    private func post(_ command: String, stdout: String, stderr: String = "") -> [String: Any] {
        [
            "hook_event_name": "PostToolUse",
            "session_id": UUID().uuidString,
            "tool_name": "Bash",
            "tool_input": ["command": command],
            "tool_response": ["stdout": stdout, "stderr": stderr, "interrupted": false],
        ]
    }

    private func written(_ payload: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: HookPayload.sanitize(payload))
        return String(decoding: data, as: UTF8.self)
    }

    /// The bug this replaces: the bash hook wrote tool_response, which for
    /// a -w lookup is the password itself.
    @Test func keychainValueNeverReachesDisk() throws {
        let password = fake("pw-", 20)
        let payload = post("security find-generic-password -s ANTHROPIC_API_KEY -w", stdout: password + "\n")
        #expect(HookPayload.shouldForward(payload, waiting: false))
        let json = try written(payload)
        #expect(!json.contains(password))
        #expect(!json.contains("tool_response"))
        let verdict = OutputVerdict(HookPayload.sanitize(payload)[HookPayload.verdictKey])
        #expect(verdict?.keychainValue == true)
        #expect(verdict?.label == "keychain value")
    }

    @Test func dashGPrintsToStderr() {
        let payload = post("security find-internet-password -s github.com -g",
                           stdout: "keychain: ...", stderr: "password: \"" + fake("", 9) + "\"")
        #expect(OutputVerdict(judging: payload).keychainValue)
    }

    @Test func capturedLookupIsNotPrinted() {
        let command = #"[ "$K" = "$(security find-generic-password -s K -w 2>/dev/null)" ] && echo same"#
        #expect(!OutputVerdict(judging: post(command, stdout: "same\n")).keychainValue)
        let notFound = "security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain."
        #expect(!OutputVerdict(judging: post("security find-generic-password -s K -w", stdout: notFound)).keychainValue)
    }

    /// An agent cat-ing a config that holds a token: no secret path in the
    /// command, but the output gives it away.
    @Test func printedTokenIsForwardedAndJudgedNotKept() throws {
        let token = fake("ghp_")
        let payload = post("cat ~/.config/some-tool/config.yml", stdout: "oauth: \(token)\n")
        #expect(HookPayload.shouldForward(payload, waiting: false))
        #expect(!(try written(payload)).contains(token))
        #expect(OutputVerdict(HookPayload.sanitize(payload)[HookPayload.verdictKey])?.kinds == ["github-token"])
    }

    @Test func inlineSecretInCommandIsRedacted() throws {
        let token = fake("ghp_")
        let payload: [String: Any] = [
            "hook_event_name": "PermissionRequest", "session_id": "s",
            "tool_name": "Bash", "tool_input": ["command": "curl -H 'Authorization: token \(token)' https://api.github.com"],
        ]
        #expect(!(try written(payload)).contains(token))
    }

    @Test func ordinaryCallsStayInTheHook() {
        let payload = post("swift build", stdout: "Build complete!")
        #expect(!HookPayload.shouldForward(payload, waiting: false))
        #expect(HookPayload.shouldForward(payload, waiting: true))
        let stop: [String: Any] = ["hook_event_name": "Stop", "session_id": "s"]
        #expect(!HookPayload.shouldForward(stop, waiting: false))
        #expect(HookPayload.shouldForward(["hook_event_name": "Notification"], waiting: false))
    }
}
