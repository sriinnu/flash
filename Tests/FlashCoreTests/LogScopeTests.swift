import Foundation
import Testing
@testable import FlashCore

@Suite struct LogScopeTests {
    @Test func parsesURLs() {
        #expect(LogScope(url: URL(string: "flash://logs?view=audit")!) == .audit)
        #expect(LogScope(url: URL(string: "flash://logs?view=all")!) == .all)
        #expect(LogScope(url: URL(string: "flash://logs?tag=Agent")!) == .tag("agent"))
        #expect(LogScope(url: URL(string: "flash://logs")!) == nil)
        #expect(LogScope(url: URL(string: "flash://logs?view=bogus")!) == nil)
        #expect(LogScope(url: URL(string: "flash://logs?tag=")!) == nil)
    }

    @Test func auditIsTheSecretTrail() {
        for tag in ["agent", "auth", "inbox", "ssh"] { #expect(LogScope.audit.includes(tag)) }
        for tag in ["overlay", "sign", "controller"] { #expect(!LogScope.audit.includes(tag)) }
        #expect(!LogScope.audit.includes(nil))
        #expect(LogScope.all.includes(nil))
        #expect(LogScope.tag("ssh").includes("ssh") && !LogScope.tag("ssh").includes("auth"))
    }
}
