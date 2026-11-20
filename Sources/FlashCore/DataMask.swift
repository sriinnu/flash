import Foundation

/// Blanks out the text in a command or script that is only being written
/// somewhere (a commit message, a file's new content, a heredoc fed to
/// `cat >`), so the secret rules only see what actually runs.
///
/// Masked characters become spaces (newlines stay), so the string keeps its
/// UTF-16 length and a match range still points at the original text.
///
/// It errs towards running: anything it can't place (an unquoted heredoc
/// with `$(…)` in it, a string handed to an unknown function) stays visible.
/// A missed secret read is worse than an extra notice.
public enum DataMask {

    // MARK: Scripts (the REPL tool's JavaScript)

    /// Calls whose arguments after the first are content, not code:
    /// `write(path, content)`, `edit(path, old, next)`.
    static let contentCalls: Set<String> = ["write", "edit"]
    /// Object keys whose values are prose or file content.
    static let dataKeys: Set<String> = [
        "content", "old_string", "new_string", "prompt", "description", "body", "title",
        "message", "summary", "text", "reason", "label", "question",
    ]
    /// Object keys whose values run.
    static let execKeys: Set<String> = ["command", "code", "cmd", "script"]

    private enum Frame {
        case call(name: String, arg: Int)
        case group
        case bracket
        case brace(key: String?, expectingKey: Bool)
        case template(exec: Bool)
        case interpolation
    }

    public static func script(_ code: String) -> String {
        var units = Array(code.utf16)
        let n = units.count
        var frames: [Frame] = []
        var i = 0
        var lastWord: String?          // identifier just before, for calls and tags
        var lastSignificant: UInt16 = 0 // for regex-literal detection

        func blank(_ range: Range<Int>) {
            for k in range where units[k] != 10 { units[k] = 32 }
        }
        func isIdent(_ c: UInt16) -> Bool {
            (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 36 || c > 127
        }
        func skipSpace(_ j: Int) -> Int {
            var j = j
            while j < n, units[j] == 32 || units[j] == 9 || units[j] == 10 || units[j] == 13 { j += 1 }
            return j
        }
        /// Is a string at the current depth data?
        func isData() -> Bool {
            for frame in frames.reversed() {
                switch frame {
                case .brace(let key, _):
                    if let key, execKeys.contains(key) { return false }
                    if let key, dataKeys.contains(key) { return true }
                case .call(let name, let arg):
                    if name == "$" { return false }
                    if contentCalls.contains(name) { return arg >= 1 }
                case .template(let exec):
                    if exec { return false }
                case .group, .bracket, .interpolation:
                    continue
                }
            }
            return false
        }
        /// After a key-position token: a `:` makes it the key.
        func takeKey(_ name: String, after j: Int) -> Bool {
            guard case .brace(_, true) = frames.last else { return false }
            let k = skipSpace(j)
            guard k < n, units[k] == 58 else { return false }
            frames[frames.count - 1] = .brace(key: name, expectingKey: false)
            return true
        }
        /// Scans template text from `j` to the closing backtick or a `${`;
        /// returns the index after it, and whether it stopped at `${`.
        func scanTemplate(from j: Int, exec: Bool) -> (Int, Bool) {
            var k = j
            let data = !exec && isData()
            let start = k
            while k < n {
                if units[k] == 92 { k += 2; continue }
                if units[k] == 96 { if data { blank(start..<k) }; return (k + 1, false) }
                if units[k] == 36, k + 1 < n, units[k + 1] == 123 { if data { blank(start..<k) }; return (k + 2, true) }
                k += 1
            }
            if data { blank(start..<n) }
            return (n, false)
        }

        while i < n {
            let c = units[i]
            // Comments never run.
            if c == 47, i + 1 < n, units[i + 1] == 47 {
                var k = i; while k < n, units[k] != 10 { k += 1 }
                blank(i..<k); i = k; continue
            }
            if c == 47, i + 1 < n, units[i + 1] == 42 {
                var k = i + 2
                while k + 1 < n, !(units[k] == 42 && units[k + 1] == 47) { k += 1 }
                k = min(n, k + 2); blank(i..<k); i = k; continue
            }
            // A regex literal, where an operand can start: skip it whole so
            // its quotes don't open strings.
            if c == 47 {
                let operandStart: Set<UInt16> = [0, 40, 44, 61, 58, 91, 33, 38, 124, 63, 123, 125, 59, 43, 45, 42, 37, 60, 62, 126, 94]
                if operandStart.contains(lastSignificant) && lastWord == nil {
                    var k = i + 1; var inClass = false
                    while k < n, units[k] != 10 {
                        if units[k] == 92 { k += 2; continue }
                        if units[k] == 91 { inClass = true } else if units[k] == 93 { inClass = false }
                        else if units[k] == 47, !inClass { break }
                        k += 1
                    }
                    i = min(n, k + 1); lastSignificant = 41; continue
                }
            }
            if c == 39 || c == 34 {
                var k = i + 1
                while k < n, units[k] != c, units[k] != 10 { if units[k] == 92 { k += 1 }; k += 1 }
                let end = min(k, n)
                let name = String(utf16CodeUnits: Array(units[(i + 1)..<end]), count: end - i - 1)
                if !takeKey(name, after: end + 1), isData() { blank((i + 1)..<end) }
                i = min(n, end + 1); lastWord = nil; lastSignificant = c; continue
            }
            if c == 96 {
                let exec = lastWord == "$"
                frames.append(.template(exec: exec))
                let (next, interpolating) = scanTemplate(from: i + 1, exec: exec)
                if interpolating { frames.append(.interpolation) } else { frames.removeLast() }
                i = next; lastWord = nil; lastSignificant = interpolating ? 123 : 96; continue
            }
            if isIdent(c) {
                var k = i; while k < n, isIdent(units[k]) { k += 1 }
                let word = String(utf16CodeUnits: Array(units[i..<k]), count: k - i)
                if !takeKey(word, after: k) { lastWord = word } else { lastWord = nil }
                i = k; lastSignificant = 97; continue
            }
            switch c {
            case 40:
                let keywords: Set<String> = ["if", "while", "for", "switch", "catch", "function", "return", "await", "typeof"]
                if let word = lastWord, !keywords.contains(word) { frames.append(.call(name: word, arg: 0)) }
                else { frames.append(.group) }
            case 41:
                if let index = frames.lastIndex(where: { if case .call = $0 { return true }; if case .group = $0 { return true }; return false }) {
                    frames.removeSubrange(index...)
                }
            case 91: frames.append(.bracket)
            case 93:
                if let index = frames.lastIndex(where: { if case .bracket = $0 { return true }; return false }) { frames.removeSubrange(index...) }
            case 123: frames.append(.brace(key: nil, expectingKey: true))
            case 125:
                if case .interpolation = frames.last {
                    frames.removeLast()
                    guard case .template(let exec) = frames.last else { break }
                    let (next, interpolating) = scanTemplate(from: i + 1, exec: exec)
                    if interpolating { frames.append(.interpolation) } else { frames.removeLast() }
                    i = next; lastWord = nil; lastSignificant = interpolating ? 123 : 96; continue
                }
                if let index = frames.lastIndex(where: { if case .brace = $0 { return true }; return false }) { frames.removeSubrange(index...) }
            case 44:
                switch frames.last {
                case .call(let name, let arg)?: frames[frames.count - 1] = .call(name: name, arg: arg + 1)
                case .brace?: frames[frames.count - 1] = .brace(key: nil, expectingKey: true)
                default: break
                }
            default: break
            }
            if c != 32 && c != 9 && c != 10 && c != 13 { lastSignificant = c; lastWord = nil }
            i += 1
        }
        return String(utf16CodeUnits: units, count: units.count)
    }

    // MARK: Shell commands (the Bash tool)

    private static let heredoc = try! NSRegularExpression(pattern: #"<<-?[ \t]*(['"]?)([A-Za-z_][A-Za-z0-9_]*)\1"#)
    private static let runsInput = try! NSRegularExpression(
        pattern: #"\|\s*(?:sudo\s+)?(?:sh|bash|zsh|dash|ksh|fish|python3?|node|bun|deno|ruby|perl|osascript|source|eval|xargs|env)\b"#)
    private static let messageFlag = try! NSRegularExpression(
        pattern: #"(?:^|\s)(?:-m|--message|--body|-b|--title|-t|--notes|-n)(?:=|\s+)("(?:[^"\\]|\\.)*"|'[^']*')"#)

    public static func shell(_ command: String) -> String {
        var units = Array(command.utf16)
        let ns = command as NSString
        func blank(_ range: NSRange) {
            for k in range.location..<NSMaxRange(range) where units[k] != 10 { units[k] = 32 }
        }
        /// The simple command around `location`: from the last ;, &, |, (, or
        /// newline before it, to the end of its line.
        func segment(at location: Int) -> (head: String, line: String) {
            var start = location
            while start > 0, !";&|(\n".utf16.contains(units[start - 1]) { start -= 1 }
            var end = location
            while end < units.count, units[end] != 10 { end += 1 }
            let text = ns.substring(with: NSRange(location: start, length: location - start))
            let words = text.split(whereSeparator: { $0 == " " || $0 == "\t" })
                .map(String.init).filter { !$0.contains("=") || $0.hasPrefix("-") }
            let line = ns.substring(with: NSRange(location: location, length: end - location))
            return (words.first.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "", line)
        }

        // Heredoc bodies fed to cat/tee (written to a file, not run).
        for match in heredoc.matches(in: command, range: NSRange(location: 0, length: ns.length)) {
            let (head, line) = segment(at: match.range.location)
            guard head == "cat" || head == "tee" else { continue }
            if runsInput.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil { continue }
            let quoted = match.range(at: 1).length > 0
            let delimiter = ns.substring(with: match.range(at: 2))
            let bodyStart = ns.range(of: "\n", range: NSRange(location: NSMaxRange(match.range), length: ns.length - NSMaxRange(match.range)))
            guard bodyStart.location != NSNotFound else { continue }
            var cursor = NSMaxRange(bodyStart)
            var bodyEnd = ns.length
            while cursor < ns.length {
                let lineRange = ns.lineRange(for: NSRange(location: cursor, length: 0))
                let text = ns.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)
                if text == delimiter { bodyEnd = lineRange.location; break }
                cursor = NSMaxRange(lineRange)
            }
            let body = NSRange(location: NSMaxRange(bodyStart), length: bodyEnd - NSMaxRange(bodyStart))
            // Unquoted heredocs expand $( ) and backticks: those run.
            if !quoted {
                let text = ns.substring(with: body)
                if text.contains("$(") || text.contains("\u{60}") { continue }
            }
            blank(body)
        }

        // Messages handed to git and gh (-m, --body, --title, …).
        for match in messageFlag.matches(in: command, range: NSRange(location: 0, length: ns.length)) {
            let (head, _) = segment(at: match.range.location)
            guard head == "git" || head == "gh" else { continue }
            let value = match.range(at: 1)
            let text = ns.substring(with: value)
            if text.hasPrefix("\""), text.contains("$(") || text.contains("\u{60}") { continue }
            blank(NSRange(location: value.location + 1, length: value.length - 2))
        }
        return String(utf16CodeUnits: units, count: units.count)
    }
}
