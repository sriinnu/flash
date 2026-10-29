import Foundation

/// Tiny logger: stdout when run from a terminal, plus ~/Library/Logs/Flash.log
/// always — so sniffer debug output survives terminal-free launches.
///
/// The file keeps the last `retention` and drops older lines: about 25 KB a
/// day, so a week is ~175 KB. It used to grow forever (1.4 MB by October).
enum Log {

    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Flash.log")
    static let retention: TimeInterval = 7 * 24 * 3600

    private static let formatter = ISO8601DateFormatter()
    /// Engines log from their own queues; one lock keeps a prune from
    /// rewriting the file under an append.
    private static let lock = NSLock()
    private static var prunedOn: String?

    static func write(_ message: String) {
        let stamp = formatter.string(from: Date())
        let line = "[\(stamp)] \(message)\n"
        print(line, terminator: "")
        fflush(stdout)
        guard let data = line.data(using: .utf8) else { return }

        lock.lock()
        defer { lock.unlock() }
        // First write of each day trims, so a Flash that runs for weeks
        // without a relaunch still keeps one week.
        let day = String(stamp.prefix(10))
        if prunedOn != day {
            prunedOn = day
            pruneLocked()
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    /// Lines start with an ISO-8601 UTC stamp, which sorts as text, so the
    /// cut is a string compare. Untimestamped lines (crash stacks) go with
    /// the line above them.
    private static func pruneLocked() {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let cutoff = "[" + formatter.string(from: Date().addingTimeInterval(-retention))
        var keep = false
        var kept: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("[") { keep = line >= cutoff }
            if keep { kept.append(line) }
        }
        let trimmed = kept.joined(separator: "\n")
        guard trimmed.utf8.count < text.utf8.count else { return }
        try? trimmed.write(to: url, atomically: true, encoding: .utf8)
    }
}
