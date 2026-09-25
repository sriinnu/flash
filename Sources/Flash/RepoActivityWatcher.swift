import CoreServices
import Foundation

/// Feeds the activity log from git's own reflogs, via FSEvents over the
/// watched folders. No hooks and no setup, and it can't be skipped: `--no-verify`,
/// GitHub Desktop and IDEs that bypass hooks all still append to the reflog.
///
///   <repo>/.git/logs/refs/heads/<branch>          "commit: …"        → commit
///   <repo>/.git/logs/refs/remotes/<remote>/<br>   "update by push"   → push
///
/// Watching remote-tracking reflogs means a push shows up only once it
/// *succeeded*. A fetch touches the same files but says "fetch: …", so it's
/// filtered out.
final class RepoActivityWatcher {

    static let shared = RepoActivityWatcher()

    private var stream: FSEventStreamRef?
    /// Bytes already read per reflog, so each change yields only new lines.
    private var offsets: [String: UInt64] = [:]
    /// Lines older than this are history, not activity.
    private var startedAt = Date()

    func start(roots: [String]) {
        guard stream == nil else { return }
        let existing = roots.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else {
            Log.write("[activity] no watched folders exist — activity log idle")
            return
        }
        startedAt = Date().addingTimeInterval(-2)
        offsets.removeAll()

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        // C callback: no captures, so the watcher comes back through `info`.
        // It's a process-lifetime singleton, hence the unretained pass.
        let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<RepoActivityWatcher>.fromOpaque(info).takeUnretainedValue()
            guard let list = unsafeBitCast(paths, to: NSArray.self) as? [String] else { return }
            watcher.handle(list)
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            existing as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.4,   // coalescing latency, seconds
            flags
        ) else {
            Log.write("[activity] FSEventStreamCreate failed")
            return
        }
        FSEventStreamSetDispatchQueue(created, .main)
        FSEventStreamStart(created)
        stream = created
        Log.write("[activity] watching \(existing.joined(separator: ", "))")
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
        Log.write("[activity] stopped")
    }

    // MARK: Event handling

    private func handle(_ paths: [String]) {
        for path in paths {
            guard let git = path.range(of: "/.git/") else { continue }
            let inside = path[git.upperBound...]

            let kind: ActivityEvent.Kind
            let ref: String
            if let r = inside.range(of: "logs/refs/heads/") {
                kind = .commit
                ref = String(inside[r.upperBound...])
            } else if let r = inside.range(of: "logs/refs/remotes/") {
                kind = .push
                ref = String(inside[r.upperBound...])
            } else {
                continue
            }
            let repo = (String(path[..<git.lowerBound]) as NSString).lastPathComponent

            for line in newLines(at: path) {
                guard let entry = ReflogEntry(line: line), entry.date >= startedAt else { continue }
                let event: ActivityEvent
                switch kind {
                case .commit:
                    guard entry.message.hasPrefix("commit") else { continue }   // skip reset/rebase/pull/checkout
                    event = ActivityEvent(kind: .commit, repo: repo, ref: ref, summary: entry.subject,
                                          sha: entry.newSHA, date: entry.date, actor: .unknown)
                case .push:
                    guard entry.message.hasPrefix("update by push") else { continue }   // skip fetches
                    event = ActivityEvent(kind: .push, repo: repo, ref: ref, summary: "Pushed to \(ref)",
                                          sha: entry.newSHA, date: entry.date, actor: .unknown)
                case .prompt:
                    continue
                }
                Task { @MainActor in ActivityLog.shared.record(event) }
            }
        }
    }

    /// Only what was appended since the last read. The first read of a file
    /// looks at its last 16 KB, and the `startedAt` filter throws out anything
    /// from before Flash started watching.
    private func newLines(at path: String) -> [String] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return [] }

        var start = offsets[path] ?? (size > 16_384 ? size - 16_384 : 0)
        if start > size { start = 0 }   // reflog expired / rewritten underneath us
        offsets[path] = size
        guard size > start else { return [] }

        do {
            try handle.seek(toOffset: start)
            let data = try handle.readToEnd() ?? Data()
            return String(decoding: data, as: UTF8.self)
                .split(separator: "\n")
                .map(String.init)
        } catch {
            return []
        }
    }
}

/// One reflog line: `<old> <new> <name> <<email>> <unix-ts> <tz>\t<message>`.
struct ReflogEntry {
    let newSHA: String
    let date: Date
    let message: String

    init?(line: String) {
        let halves = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
        guard halves.count == 2 else { return nil }
        let head = halves[0].split(separator: " ")
        guard head.count >= 4,
              head[1].count >= 40,
              let ts = TimeInterval(head[head.count - 2]) else { return nil }
        newSHA = String(head[1])
        date = Date(timeIntervalSince1970: ts)
        message = String(halves[1])
    }

    /// "commit (amend): fix the thing" → "fix the thing"
    var subject: String {
        guard let colon = message.range(of: ": ") else { return message }
        return String(message[colon.upperBound...])
    }
}
