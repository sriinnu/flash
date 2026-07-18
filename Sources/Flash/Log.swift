import Foundation

/// Tiny logger: stdout when run from a terminal, plus ~/Library/Logs/Flash.log
/// always — so sniffer debug output survives terminal-free launches.
enum Log {

    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Flash.log")
    private static let formatter = ISO8601DateFormatter()

    static func write(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        print(line, terminator: "")
        fflush(stdout)
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
