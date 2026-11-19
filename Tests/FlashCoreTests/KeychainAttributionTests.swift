import Foundation
import Testing
@testable import FlashCore

@Suite struct KeychainAttributionTests {

    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func proc(_ pid: Int32, _ ppid: Int32, _ name: String, ago: TimeInterval = 600,
              path: String = "", args: [String] = [], env: [String: String] = [:]) -> ProcessRecord {
        ProcessRecord(pid: pid, ppid: ppid, name: name, started: now.addingTimeInterval(-ago),
                      path: path, args: args, environment: env)
    }

    /// A real shape: Ghostty → zsh → claude (native, version-named) → zsh → security.
    var agentTable: [Int32: ProcessRecord] {
        [
            100: proc(100, 1, "ghostty", path: "/Applications/Ghostty.app/Contents/MacOS/ghostty"),
            200: proc(200, 100, "zsh", path: "/bin/zsh", env: ["TERM_PROGRAM": "ghostty"]),
            300: proc(300, 200, "2.1.326", path: "/Users/me/.local/share/claude/versions/2.1.326"),
            400: proc(400, 300, "zsh", ago: 3, path: "/bin/zsh"),
            500: proc(500, 400, "security", ago: 1, path: "/usr/bin/security",
                      args: ["/usr/bin/security", "find-generic-password", "-s", "ANTHROPIC_API_KEY", "-w"]),
            // A widget polling osascript every few seconds: never the asker.
            600: proc(600, 1, "osascript", ago: 0.5),
            // An ssh session from an hour ago: outside the window.
            700: proc(700, 200, "ssh", ago: 3600),
        ]
    }

    @Test func picksTheYoungestClientInTheWindow() {
        #expect(KeychainAttribution.candidates(in: agentTable, at: now) == [500])
    }

    @Test func namesAgentItemAndTerminal() throws {
        let requester = try #require(KeychainAttribution.describe(500, in: agentTable))
        #expect(requester.command == "security find-generic-password -s ANTHROPIC_API_KEY -w")
        #expect(requester.item == "ANTHROPIC_API_KEY")
        #expect(requester.agent == "Claude")
        #expect(requester.app == "ghostty")
        #expect(requester.chain.prefix(3) == ["zsh", "claude", "zsh"])
        #expect(requester.label.hasPrefix("security find-generic-password -s ANTHROPIC_API_KEY -w (pid 500) ← zsh ← claude"))
    }

    @Test func youWhenNoAgentIsAnAncestor() throws {
        var table = agentTable
        table[400] = proc(400, 200, "zsh", ago: 3, path: "/bin/zsh")   // your shell, not Claude's
        let requester = try #require(KeychainAttribution.describe(500, in: table))
        #expect(requester.agent == nil)
        #expect(requester.app == "ghostty")
    }

    @Test func ambiguityIsSaid() throws {
        var table = agentTable
        table[800] = proc(800, 200, "git-credential-osxkeychain", ago: 4)
        #expect(KeychainAttribution.candidates(in: table, at: now) == [500, 800])
        var requester = try #require(KeychainAttribution.describe(500, in: table))
        requester.others = 1
        #expect(requester.label.hasSuffix("(1 other candidate)"))
    }

    @Test func parsesProcArgs() throws {
        var bytes: [UInt8] = []
        withUnsafeBytes(of: Int32(3)) { bytes += $0 }
        func cstring(_ s: String) { bytes += Array(s.utf8) + [0] }
        cstring("/usr/bin/security")
        bytes += [0, 0, 0]   // padding after the exec path
        cstring("/usr/bin/security"); cstring("find-generic-password"); cstring("-w")
        cstring("HOME=/Users/me"); cstring("TERM_PROGRAM=ghostty"); cstring("CLAUDECODE=1")
        bytes += [0]
        let parsed = try #require(ProcessRecord.parseProcArgs(bytes))
        #expect(parsed.path == "/usr/bin/security")
        #expect(parsed.args == ["/usr/bin/security", "find-generic-password", "-w"])
        #expect(parsed.environment == ["TERM_PROGRAM": "ghostty", "CLAUDECODE": "1"])
    }

    @Test func agentNameMatchesTheHooks() throws {
        let table: [Int32: ProcessRecord] = [
            1000: proc(1000, 1, "claude", path: "/opt/homebrew/bin/claude"),
            1001: proc(1001, 1000, "security", ago: 1),
            2000: proc(2000, 1, "codex-cli", path: "/usr/local/bin/codex-cli"),
            2001: proc(2001, 2000, "ssh-add", ago: 1),
        ]
        #expect(KeychainAttribution.describe(1001, in: table)?.agent == "Claude")
        #expect(KeychainAttribution.describe(2001, in: table)?.agent == "codex")
    }

    @Test func claudeCodeEnvMarksAnAgentEvenWithoutAncestry() throws {
        let table: [Int32: ProcessRecord] = [
            10: proc(10, 1, "security", ago: 1, args: ["security", "unlock-keychain"], env: ["CLAUDECODE": "1"]),
        ]
        #expect(KeychainAttribution.describe(10, in: table)?.agent == "Claude")
    }
}
