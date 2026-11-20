import Foundation

/// Just enough of a git checkout to label a log line: its name, branch and
/// remotes, read from the files (no `git` subprocess). Works for worktrees,
/// whose `.git` is a file pointing at the real git dir.
public struct GitRepo: Equatable {
    /// The checkout's folder name: "flash".
    public let name: String
    /// "main", or a short sha when detached.
    public let branch: String?
    /// remote name → URL, credentials stripped.
    public let remotes: [String: String]

    public init(name: String, branch: String?, remotes: [String: String]) {
        self.name = name
        self.branch = branch
        self.remotes = remotes
    }

    /// The repo containing `directory`, walking up; nil outside one.
    public static func containing(_ directory: String, fileManager: FileManager = .default) -> GitRepo? {
        var dir = URL(fileURLWithPath: directory).standardizedFileURL
        for _ in 0..<64 {
            let dotGit = dir.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: dotGit.path, isDirectory: &isDir) {
                var gitDir = dotGit
                if !isDir.boolValue {
                    // Worktree or submodule: "gitdir: <path>"
                    guard let text = try? String(contentsOf: dotGit, encoding: .utf8),
                          let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
                    let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                    gitDir = path.hasPrefix("/") ? URL(fileURLWithPath: path) : dir.appendingPathComponent(path).standardizedFileURL
                }
                // A worktree's config lives in the common dir.
                var common = gitDir
                if let rel = try? String(contentsOf: gitDir.appendingPathComponent("commondir"), encoding: .utf8) {
                    let path = rel.trimmingCharacters(in: .whitespacesAndNewlines)
                    common = path.hasPrefix("/") ? URL(fileURLWithPath: path) : gitDir.appendingPathComponent(path).standardizedFileURL
                }
                let head = (try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8)) ?? ""
                let config = (try? String(contentsOf: common.appendingPathComponent("config"), encoding: .utf8)) ?? ""
                return GitRepo(name: dir.lastPathComponent, branch: branch(fromHead: head), remotes: remotes(fromConfig: config))
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }

    static func branch(fromHead head: String) -> String? {
        let text = head.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("ref: refs/heads/") { return String(text.dropFirst("ref: refs/heads/".count)) }
        if text.count >= 7, text.allSatisfy(\.isHexDigit) { return String(text.prefix(7)) }
        return nil
    }

    static func remotes(fromConfig config: String) -> [String: String] {
        var out: [String: String] = [:]
        var current: String?
        for raw in config.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                current = nil
                if line.hasPrefix("[remote \""), let end = line.lastIndex(of: "\"") {
                    let start = line.index(line.startIndex, offsetBy: "[remote \"".count)
                    if start < end { current = String(line[start..<end]) }
                }
            } else if let name = current, line.hasPrefix("url") {
                let parts = line.split(separator: "=", maxSplits: 1)
                if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "url" {
                    out[name] = stripCredentials(parts[1].trimmingCharacters(in: .whitespaces))
                }
            }
        }
        return out
    }

    /// Drops the "user:password@" part of a URL, so a remote or base URL
    /// that carries a token never reaches a log line.
    public static func stripCredentials(_ url: String) -> String {
        guard let scheme = url.range(of: "://"),
              let at = url[scheme.upperBound...].range(of: "@"),
              !url[scheme.upperBound..<at.lowerBound].contains("/") else { return url }
        return String(url[..<scheme.upperBound]) + url[at.upperBound...]
    }

    /// "github.com" from "https://github.com/a/b.git" or "git@github.com:a/b.git".
    public static func host(of url: String) -> String? {
        let clean = stripCredentials(url)
        if let parsed = URL(string: clean), let host = parsed.host { return host }
        // scp-like: user@host:path
        if let colon = clean.firstIndex(of: ":"), !clean[..<colon].contains("/") {
            let left = clean[..<colon]
            return String(left.split(separator: "@").last ?? left)
        }
        return nil
    }
}
