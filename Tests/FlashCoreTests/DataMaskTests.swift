import Testing
@testable import FlashCore

/// Text that's only written (commit messages, file content, heredocs to a
/// file) isn't a secret read; text that runs still is.
@Suite struct DataMaskTests {

    static let kc = "security find-generic-password"

    func rule(_ tool: String, _ key: String, _ text: String) -> String? {
        ToolCall(["tool_name": tool, "tool_input": [key: text]]).secretMatch?.rule
    }

    // The real false positives: a commit message and a PR body written from a REPL script.
    static let writtenScripts: [String] = [
        "await write(sp + '/msg4.txt', `Logged as \"asked by \(kc) -s X -w ← zsh\"`);",
        "await write(sp + '/body4.md', `- Log: \\`asked by \(kc) -s X -w (pid N)\\``);",
        "await edit('README.md', 'old line', 'run \(kc) -s api -w to read it');",
        "await edit('README.md', [['a', '\(kc) -s x'], ['b', 'c']]);",
        "tools.Agent({description: 'audit', prompt: 'check whether \(kc) is logged'});",
        "// \(kc) -s x -w\nconst a = 1;",
        "/* \(kc) */ const b = 2;",
        "await write(p, JSON.stringify({note: '\(kc)'}));",
    ]

    static let runningScripts: [String] = [
        "await $`\(kc) -s api -w`",
        "await tools.Bash({command: '\(kc) -s api -w', description: 'read it'});",
        "await write(p, `token: ${await $`\(kc) -s api -w`.text()}`);",
        "const cmd = '\(kc) -s api -w'; await $(cmd);",
        "await $(\"\(kc) -s api -w\")",
        "const r = /x'y/; await $`\(kc) -s z`",
        "file('/Users/me/.ssh/id_ed25519').text()",
    ]

    @Test(arguments: writtenScripts) func writtenScriptTextIsNotAccess(_ code: String) {
        #expect(rule("REPL", "code", code) == nil, "\(code)")
    }

    @Test(arguments: runningScripts) func runningScriptsStillMatch(_ code: String) {
        #expect(rule("REPL", "code", code) != nil, "\(code)")
    }

    static let writtenShell: [String] = [
        "cat > notes.md <<'EOF'\nrun \(kc) -s api -w\nEOF\necho done",
        "cat <<EOF > notes.md\nrun \(kc) -s api -w\nEOF",
        "tee doc.md <<\"EOF\" >/dev/null\n\(kc)\nEOF",
        "git commit -S -m \"log \(kc) callers\" -- a.swift",
        "gh pr create --title 'keychain' --body '\(kc) -s X'",
    ]

    static let runningShell: [String] = [
        "\(kc) -s api -w",
        "cat <<'EOF' | bash\n\(kc) -s api -w\nEOF",
        "bash <<'EOF'\n\(kc) -s api -w\nEOF",
        "cat > out.txt <<EOF\nkey=$(\(kc) -s api -w)\nEOF",
        "git commit -m \"$(\(kc) -s api -w)\"",
        "echo hi; \(kc) -s api -w; git commit -m 'x'",
    ]

    @Test(arguments: writtenShell) func writtenShellTextIsNotAccess(_ command: String) {
        #expect(rule("Bash", "command", command) == nil, "\(command)")
    }

    @Test(arguments: runningShell) func runningShellStillMatches(_ command: String) {
        #expect(rule("Bash", "command", command) == "keychain", "\(command)")
    }

    @Test func maskKeepsLengthAndNewlines() {
        let code = "await write(p, 'a\\nb');\n// c\nx"
        let masked = DataMask.script(code)
        #expect(masked.utf16.count == code.utf16.count)
        #expect(masked.filter { $0 == "\n" }.count == code.filter { $0 == "\n" }.count)
    }

    @Test func excerptStillShowsTheRealMatch() {
        let call = ToolCall(["tool_name": "Bash", "tool_input": ["command": "git commit -m '\(Self.kc)' && \(Self.kc) -s real -w"]])
        #expect(call.keychainItem == "real")
    }
}
