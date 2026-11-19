import Foundation
import FlashCore

/// One entry of Flash.log: `[stamp] [tag] message`. Untimestamped lines
/// (crash stacks) are folded into the entry above them, as `Log` prunes them.
struct LogLine: Identifiable, Equatable {
    let id: Int
    let date: Date?
    let tag: String?
    var message: String

    /// The line as it sits in the file, for Copy.
    var raw: String {
        let stamp = date.map { "[" + LogLine.stampFormatter.string(from: $0) + "] " } ?? ""
        return stamp + (tag.map { "[\($0)] " } ?? "") + message
    }

    // ISO8601DateFormatter is documented thread-safe; the tail parses off main.
    nonisolated(unsafe) static let stampFormatter = ISO8601DateFormatter()
}

/// Follows ~/Library/Logs/Flash.log the way `tail -F` does: reads it whole,
/// then only the appended bytes. `Log` prunes by atomic rewrite (new inode),
/// so a delete/rename of the watched file means "reopen and read it again".
/// All state lives on `queue`; updates are delivered on main.
final class LogTail: @unchecked Sendable {

    enum Update {
        /// The whole file, after an open, a reopen, or a truncation. nil: no file.
        case reset([LogLine]?)
        /// New bytes: text continuing the last entry (a stack), then new entries.
        case append(extendLast: String?, lines: [LogLine])
    }

    private let url: URL
    private let onUpdate: @MainActor (Update) -> Void
    private let queue = DispatchQueue(label: "flash.logtail")

    private var source: DispatchSourceFileSystemObject?
    private var handle: FileHandle?
    private var offset: UInt64 = 0
    /// Bytes after the last newline: a line Log is still writing.
    private var partial = Data()
    private var nextID = 0
    private var running = false
    private var retry: DispatchWorkItem?
    /// So a missing file is reported once, not on every retry.
    private var reportedMissing = false

    init(url: URL, onUpdate: @escaping @MainActor (Update) -> Void) {
        self.url = url
        self.onUpdate = onUpdate
    }

    func start() {
        queue.async {
            guard !self.running else { return }
            self.running = true
            self.reopen()
        }
    }

    func stop() {
        queue.async {
            self.running = false
            self.reportedMissing = false
            self.teardown()
        }
    }

    // MARK: Queue-confined

    private func teardown() {
        retry?.cancel()
        retry = nil
        source?.cancel()   // the cancel handler releases (and closes) the handle
        source = nil
        handle = nil
    }

    private func reopen() {
        teardown()
        guard running else { return }
        offset = 0
        partial = Data()

        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else {
            if !reportedMissing { deliver(.reset(nil)) }
            reportedMissing = true
            scheduleRetry()   // not written yet; Log creates it on first write
            return
        }
        reportedMissing = false
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        self.handle = handle

        let data = (try? handle.readToEnd()) ?? Data()
        offset = UInt64(data.count)
        let (extend, lines) = parse(data)
        // A leading continuation has no entry to join; keep it as its own line.
        var all = lines
        if let extend { all.insert(LogLine(id: takeID(), date: nil, tag: nil, message: extend), at: 0) }
        deliver(.reset(all))

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .revoke], queue: queue)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            self.changed(source.data)
        }
        source.setCancelHandler { _ = handle }
        source.resume()
        self.source = source
    }

    private func changed(_ event: DispatchSource.FileSystemEvent) {
        if !event.isDisjoint(with: [.delete, .rename, .revoke]) {
            reopen()
            return
        }
        guard let handle else { return }
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else { return reopen() }
        let size = UInt64(info.st_size)
        if size < offset { return reopen() }   // truncated in place
        guard size > offset else { return }
        do {
            try handle.seek(toOffset: offset)
            let data = try handle.readToEnd() ?? Data()
            offset += UInt64(data.count)
            let (extend, lines) = parse(data)
            if extend != nil || !lines.isEmpty {
                deliver(.append(extendLast: extend, lines: lines))
            }
        } catch {
            reopen()
        }
    }

    private func scheduleRetry() {
        let work = DispatchWorkItem { [weak self] in self?.reopen() }
        retry = work
        queue.asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// Complete lines only; the unterminated tail waits in `partial`.
    private func parse(_ data: Data) -> (extend: String?, lines: [LogLine]) {
        partial.append(data)
        guard let lastNewline = partial.lastIndex(of: UInt8(ascii: "\n")) else { return (nil, []) }
        let complete = partial[partial.startIndex..<lastNewline]
        partial = Data(partial[partial.index(after: lastNewline)...])

        let text = String(decoding: complete, as: UTF8.self)
        var extend: String?
        var lines: [LogLine] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let entry = Self.header(raw) {
                lines.append(LogLine(id: takeID(), date: entry.date, tag: entry.tag, message: entry.message))
            } else if lines.isEmpty {
                extend = extend.map { $0 + "\n" + raw } ?? String(raw)
            } else {
                lines[lines.count - 1].message += "\n" + raw
            }
        }
        return (extend, lines)
    }

    private func takeID() -> Int {
        nextID += 1
        return nextID
    }

    /// `[2026-11-19T18:39:50Z] [sign] SIGUSR1 …` → date, "sign", "SIGUSR1 …".
    static func header(_ line: Substring) -> (date: Date, tag: String?, message: String)? {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]"),
              let date = LogLine.stampFormatter.date(from: String(line[line.index(after: line.startIndex)..<close]))
        else { return nil }
        var rest = line[line.index(after: close)...].drop { $0 == " " }
        var tag: String?
        if rest.hasPrefix("["), let end = rest.firstIndex(of: "]") {
            let name = rest[rest.index(after: rest.startIndex)..<end]
            if !name.isEmpty, !name.contains(" ") {
                tag = String(name)
                rest = rest[rest.index(after: end)...].drop { $0 == " " }
            }
        }
        return (date, tag, String(rest))
    }

    private func deliver(_ update: Update) {
        let onUpdate = onUpdate
        DispatchQueue.main.async { MainActor.assumeIsolated { onUpdate(update) } }
    }
}

/// What the Logs window shows. Tails the file only while the window is open.
@MainActor
final class LogViewer: ObservableObject {

    static let shared = LogViewer()

    @Published private(set) var lines: [LogLine] = []
    /// No Flash.log on disk yet.
    @Published private(set) var missing = false
    /// The window's scope picker; a `flash://logs?…` URL sets it too.
    @Published var scope: LogScope = .all

    /// A week is ~5k lines; the cap only guards a runaway engine.
    private let capacity = 50_000
    private var tail: LogTail!

    private init() {
        tail = LogTail(url: Log.url) { [weak self] update in self?.apply(update) }
    }

    func start() { tail.start() }
    func stop() { tail.stop() }

    private func apply(_ update: LogTail.Update) {
        switch update {
        case .reset(let all):
            missing = all == nil
            lines = all ?? []
        case .append(let extend, let new):
            if let extend, !lines.isEmpty { lines[lines.count - 1].message += "\n" + extend }
            lines.append(contentsOf: new)
        }
        if lines.count > capacity { lines.removeFirst(lines.count - capacity) }
    }
}
