import Foundation
import Testing
@testable import FlashCore

@Suite struct GitRepoTests {

    func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func readsACheckoutFromASubfolder() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("flash")
        let git = repo.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("Sources/App"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try "ref: refs/heads/feat/agent-details\n".write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        let keyed = "https://" + "me:" + "tok" + "@github.com/me/flash.git"
        try "[core]\n\tbare = false\n[remote \"origin\"]\n\turl = \(keyed)\n\tfetch = +refs/heads/*\n[remote \"up\"]\n\turl = git@gitlab.com:x/y.git\n"
            .write(to: git.appendingPathComponent("config"), atomically: true, encoding: .utf8)

        let found = try #require(GitRepo.containing(repo.appendingPathComponent("Sources/App").path))
        #expect(found.name == "flash")
        #expect(found.branch == "feat/agent-details")
        #expect(found.remotes["origin"] == "https://github.com/me/flash.git")   // credentials gone
        #expect(found.remotes["up"] == "git@gitlab.com:x/y.git")
        #expect(GitRepo.containing(root.path) == nil)
    }

    @Test func worktreeUsesItsOwnHeadAndTheCommonConfig() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let main = root.appendingPathComponent("flash/.git")
        let wtGit = main.appendingPathComponent("worktrees/fix")
        try FileManager.default.createDirectory(at: wtGit, withIntermediateDirectories: true)
        try "[remote \"origin\"]\n\turl = https://github.com/me/flash.git\n".write(to: main.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        try "ref: refs/heads/fix\n".write(to: wtGit.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        try "../..\n".write(to: wtGit.appendingPathComponent("commondir"), atomically: true, encoding: .utf8)
        let tree = root.appendingPathComponent("flash-fix")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        try "gitdir: \(wtGit.path)\n".write(to: tree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)

        let found = try #require(GitRepo.containing(tree.path))
        #expect(found.name == "flash-fix")
        #expect(found.branch == "fix")
        #expect(found.remotes["origin"] == "https://github.com/me/flash.git")
    }

    @Test func detachedHeadAndHosts() {
        #expect(GitRepo.branch(fromHead: "f5c926d0123456789abcdef0123456789abcdef0\n") == "f5c926d")
        #expect(GitRepo.host(of: "https://github.com/a/b.git") == "github.com")
        #expect(GitRepo.host(of: "git@github.com:a/b.git") == "github.com")
        #expect(GitRepo.host(of: "ssh://git@gitlab.example.com:2222/a/b") == "gitlab.example.com")
        #expect(GitRepo.host(of: "https://" + "u:" + "p" + "@bitbucket.org/a") == "bitbucket.org")
    }
}
