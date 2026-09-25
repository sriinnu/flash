import Foundation

/// Flash's one door for outside events. Scripts (`flash-notify`, and through
/// it `flash-askpass` and the git hooks) drop a small `key=value` file into
/// the inbox folder; a directory watcher wakes us, we read, route, delete.
///
/// A folder instead of a socket on purpose, Sriinnu: the client stays a
/// plain shell script with no `nc` quirks, a stuck event is just a file you
/// can `cat`, and nothing breaks if Flash isn't running — files older than
/// `maxAge` are dropped unread on the next drain.
final class EventInbox {

    static let shared = EventInbox()

    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Flash/inbox", isDirectory: true)

    /// Called on the main queue with each event's fields.
    var onEvent: (([String: String]) -> Void)?

    private let maxAge: TimeInterval = 30
    private var source: DispatchSourceFileSystemObject?

    /// Created at launch whether or not watching is on, so flash-notify's
    /// "does Flash exist here?" check (the folder) is true from first run.
    static func ensureDirectory() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func start() {
        guard source == nil else { return }
        Self.ensureDirectory()
        drain()   // anything that landed while we were paused / not running

        let fd = open(Self.directory.path, O_EVTONLY)
        guard fd >= 0 else {
            Log.write("[inbox] can't watch \(Self.directory.path) (errno \(errno))")
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        src.setEventHandler { [weak self] in self?.drain() }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
        Log.write("[inbox] listening at \(Self.directory.path)")
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    private func drain() {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: Self.directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]   // flash-notify's half-written .tmp files
        ) else { return }

        // Names start with the epoch second, so this is roughly arrival order.
        for url in urls.filter({ $0.pathExtension == "event" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            defer { try? fm.removeItem(at: url) }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            guard Date().timeIntervalSince(modified) <= maxAge else {
                Log.write("[inbox] dropped stale \(url.lastPathComponent)")
                continue
            }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            onEvent?(Self.parse(text))
        }
    }

    /// `key=value` per line; later keys win, so callers can override the
    /// defaults flash-notify writes first.
    static func parse(_ text: String) -> [String: String] {
        var fields: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            fields[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        return fields
    }
}

/// What each inbox event means. Kept apart from EventInbox so the transport
/// never needs to know about alerts or the activity log.
@MainActor
enum InboxRouter {

    /// ids whose `prompt.end` already landed. Two events from one script can
    /// share an epoch second and drain in either order; a begin that shows up
    /// after its own end must not start an alert nobody will ever stop.
    private static var recentlyEnded: [String: Date] = [:]

    static func handle(_ fields: [String: String]) {
        let actor = Actor(fields: fields)

        switch fields["event"] {
        case "prompt.begin":
            guard let id = fields["id"], recentlyEnded[id] == nil else { return }
            let kind = fields["kind"] ?? "prompt"
            Log.write("[inbox] prompt.begin \(kind) id=\(id) by \(actor.label.isEmpty ? "?" : actor.label)")
            FlashController.shared.trigger("prompt:\(id)")
            ActivityLog.shared.record(ActivityEvent(
                kind: .prompt,
                repo: nil,
                ref: nil,
                summary: promptLabel(kind),
                sha: nil,
                date: Date(),
                actor: actor
            ))

        case "prompt.end":
            guard let id = fields["id"] else { return }
            let cutoff = Date().addingTimeInterval(-60)
            recentlyEnded = recentlyEnded.filter { $0.value > cutoff }
            recentlyEnded[id] = Date()
            FlashController.shared.resolve("prompt:\(id)", success: fields["ok"] == "1")

        case "attrib":
            guard let sha = fields["sha"], !sha.isEmpty else { return }
            ActivityLog.shared.attribute(sha: sha, actor: actor)

        default:
            Log.write("[inbox] unknown event: \(fields["event"] ?? "nil")")
        }
    }

    static func promptLabel(_ kind: String) -> String {
        switch kind {
        case "touch": return "Security key touch"
        case "ssh-passphrase": return "SSH key passphrase"
        case "pin": return "PIN"
        case "password": return "Password"
        case "username": return "Username"
        case "confirm": return "Confirmation"
        default: return "Git is waiting on you"
        }
    }
}
