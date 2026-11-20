import Foundation
import Testing
@testable import FlashCore

private func call(_ tool: String, _ input: [String: Any]) -> ToolCall {
    ToolCall(["tool_name": tool, "tool_input": input])
}
private func bash(_ command: String) -> ToolCall { call("Bash", ["command": command]) }

/// Cases taken from a real week of Flash.log (feel pass, 2026-11-19).
@Suite struct ToolCallTests {

    // MARK: False positives that used to flash crimson

    @Test func prosePromptsReachNothing() {
        let prompt = "Check ~/.ssh/config and the .env loader, then run security find-generic-password"
        for tool in ["Agent", "Task", "SendMessage", "SubagentHandback"] {
            #expect(!call(tool, ["prompt": prompt, "message": prompt]).touchesSecret, "\(tool)")
        }
    }

    @Test func editContentIsNotATarget() {
        let edit = call("Edit", ["file_path": "/repo/README.md", "old_string": "x", "new_string": "Put id_ed25519 in ~/.ssh/"])
        #expect(!edit.touchesSecret)
        #expect(!call("Write", ["file_path": "/repo/src/scan.test.ts", "content": "const p = '.env'"]).touchesSecret)
    }

    @Test func envTemplatesAreNotSecrets() {
        #expect(!bash("cp .env.example .env.sample && cat .env.template").touchesSecret)
        #expect(bash("cat .env.local").touchesSecret)
        #expect(bash("source .env").touchesSecret)
    }

    // MARK: Accesses that used to pass silently

    static let accesses: [(String, String)] = [
        ("env-secret", #"for v in VAAYU_BRIDGE_MACOS_TOKEN VAAYU_GATEWAY_TOKEN; do [ -n "${!v}" ] && echo "$v set"; done"#),
        ("env-secret", "printenv | sort"),
        ("env-secret", "env | grep -i key"),
        ("env-secret", #"curl -H "Authorization: Bearer $GITHUB_TOKEN" https://api.github.com"#),
        ("credentials-file", "cat ~/.aws/credentials"),
        ("credentials-file", "grep machine ~/.netrc"),
        ("credentials-file", "cat ~/.config/gh/hosts.yml"),
        ("credentials-file", "jq . ~/.claude/.credentials.json"),
        ("token-cli", "gcloud auth print-access-token"),
        ("token-cli", "aws configure get aws_secret_access_key"),
        ("token-cli", "printf 'host=github.com' | git credential fill"),
        ("gpg-secret", "gpg --export-secret-keys --armor me"),
        ("keychain", "security find-generic-password -s ANTHROPIC_API_KEY -w"),
        ("ssh-key", "ssh-keygen -y -f ~/.ssh/id_ed25519_sk"),
        ("key-file", "openssl pkcs12 -in cert.p12 -nodes"),
    ]

    @Test(arguments: accesses)
    func catchesRealAccesses(rule: String, command: String) {
        #expect(bash(command).secretMatch?.rule == rule, "\(command)")
    }

    @Test func lowercaseLocalsAreNotEnvSecrets() {
        #expect(!bash(#"token=$(cat count.txt); echo "$token""#).touchesSecret)
    }

    @Test func mcpAndScriptsAreSearchedByKey() {
        let mcp = call("mcp__fs__read", ["options": ["path": "/Users/me/.aws/credentials"], "note": "about .env"])
        #expect(mcp.secretMatch?.rule == "credentials-file")
        #expect(!call("mcp__notes__add", ["text": "rotate ~/.ssh keys"]).touchesSecret)
        #expect(call("REPL", ["code": "await $`security find-generic-password -s X -w`"]).touchesSecret)
    }

    // MARK: Who / what

    @Test func namesTheKeychainItem() {
        #expect(bash("security find-generic-password -s ANTHROPIC_API_KEY -w").keychainItem == "ANTHROPIC_API_KEY")
        #expect(bash(#"security find-internet-password -a me -l "GitHub (work)" -g"#).keychainItem == "GitHub (work)")
        #expect(bash("ls ~/.ssh").keychainItem == nil)
    }

    @Test func longCommandsShowTheMatch() {
        let command = "cd /private/tmp/build/chitragupta && make -j8 && ./scripts/package.sh --sign && "
            + "security find-generic-password -s NOTARY -w"
        let summary = bash(command).summary
        #expect(summary.contains("security find-generic-password"), "\(summary)")
        #expect(summary.hasPrefix("Run `…"))
        #expect(bash("ls ~/.ssh").summary == "Run `ls ~/.ssh`")
    }

    @Test func fingerprintIgnoresExtraFields() {
        let asked = call("Bash", ["command": "cat ~/.netrc"])
        let ran = call("Bash", ["command": "cat ~/.netrc", "description": "Read netrc", "timeout": 120000])
        #expect(asked.fingerprint == ran.fingerprint)
    }
}
