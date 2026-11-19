import SwiftUI
import AppKit
import FlashCore

/// Flash.log, live, inside the app: what each engine said, newest at the
/// bottom like a terminal. Filter by engine tag or text; Follow keeps the
/// view pinned to the end as lines arrive.
@MainActor
struct LogsView: View {

    static let windowSize = NSSize(width: 760, height: 520)

    @ObservedObject var viewer: LogViewer

    @State private var query = ""
    @State private var follow = true

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            Divider()
            content
            Divider()
            footer
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
        .frame(minWidth: 560, idealWidth: Self.windowSize.width, maxWidth: .infinity,
               minHeight: 320, idealHeight: Self.windowSize.height, maxHeight: .infinity)
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker("Engine", selection: $viewer.scope) {
                Text("All engines").tag(LogScope.all)
                Text("Audit: secrets, keychain, ssh").tag(LogScope.audit)
                Divider()
                ForEach(tags, id: \.self) { Text($0).tag(LogScope.tag($0)) }
            }
            .help("Audit: agent secret access, keychain dialogs and who asked, hook inbox, ssh")
            .labelsHidden()
            .fixedSize()

            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter", text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
            .frame(maxWidth: 260)

            Spacer()

            Toggle("Follow", isOn: $follow)
                .toggleStyle(.checkbox)
                .help("Keep the newest line in view")
            Button {
                let text = shown.map(\.raw).joined(separator: "\n")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .help("Copy the lines shown")
            .disabled(shown.isEmpty)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([Log.url])
            } label: {
                Image(systemName: "folder")
            }
            .help("Show Flash.log in Finder")
            .disabled(viewer.missing)
        }
    }

    // MARK: Lines

    @ViewBuilder
    private var content: some View {
        if viewer.missing {
            placeholder("No Flash.log yet. It appears with the first thing Flash logs.")
        } else if shown.isEmpty {
            placeholder(viewer.lines.isEmpty ? "Flash.log is empty." : "No lines match.")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(shown) { LogRow(line: $0) }
                    }
                    .padding(.vertical, 4)
                }
                .onAppear { scrollToEnd(proxy) }
                .onChange(of: shown.last?.id) { _, _ in if follow { scrollToEnd(proxy) } }
                .onChange(of: follow) { _, on in if on { scrollToEnd(proxy) } }
                .modifier(PauseFollowOnScroll(follow: $follow))
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        guard let last = shown.last?.id else { return }
        proxy.scrollTo(last, anchor: .bottom)
    }

    private var footer: some View {
        HStack {
            Text(shown.count == viewer.lines.count
                 ? "\(viewer.lines.count) lines"
                 : "\(shown.count) of \(viewer.lines.count) lines")
            Spacer()
            Text((Log.url.path as NSString).abbreviatingWithTildeInPath + " · last 7 days")
                .textSelection(.enabled)
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    // MARK: Filtering

    /// The engines in the file, plus one a URL asked for that hasn't
    /// logged yet (so the picker can show it).
    private var tags: [String] {
        var all = Set(viewer.lines.compactMap(\.tag))
        if case .tag(let wanted) = viewer.scope { all.insert(wanted) }
        return all.sorted()
    }

    private var shown: [LogLine] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        let scope = viewer.scope
        guard scope != .all || !needle.isEmpty else { return viewer.lines }
        return viewer.lines.filter { line in
            scope.includes(line.tag)
                && (needle.isEmpty || line.message.localizedCaseInsensitiveContains(needle)
                    || (line.tag?.localizedCaseInsensitiveContains(needle) ?? false))
        }
    }
}

private struct LogRow: View {
    let line: LogLine

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(time)
                .foregroundStyle(.secondary)
                .frame(width: 116, alignment: .trailing)
            Text(line.tag ?? "")
                .foregroundStyle(LogRow.color(for: line.tag))
                .frame(width: 84, alignment: .leading)
                .lineLimit(1)
            Text(line.message)
                .foregroundStyle(isProblem ? Color.red : Color.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 12)
        .padding(.vertical, 1.5)
    }

    /// Today: "18:39:50". Older: "Nov 18 18:39:50". Stamps are UTC on disk,
    /// local here.
    private var time: String {
        guard let date = line.date else { return "" }
        return Calendar.current.isDateInToday(date)
            ? LogRow.today.string(from: date)
            : LogRow.older.string(from: date)
    }

    /// Engines whose lines quote someone else's text (a command an agent
    /// ran, a hook's summary, a dialog's asker): "error" in there is the
    /// quote, not Flash failing.
    private static let quoting: Set<String> = ["agent", "inbox", "auth", "activity"]

    private var isProblem: Bool {
        if line.tag == "crash" { return true }
        if let tag = line.tag, LogRow.quoting.contains(tag) { return false }
        let lower = line.message.lowercased()
        return lower.contains("error") || lower.contains("failed") || lower.contains("couldn't")
    }

    private static let today: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static let older: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMd HH:mm:ss")
        return formatter
    }()

    /// Fixed colours for the engines that talk most; the rest stay quiet.
    static func color(for tag: String?) -> Color {
        switch tag {
        case "crash": return .red
        case "sign", "sniffer": return .orange
        case "controller": return .purple
        case "overlay": return .blue
        case "agent": return .pink
        case "auth", "ssh": return .teal
        case "activity", "inbox": return .green
        default: return .secondary
        }
    }
}

/// Turns Follow off while you scroll back through the log, and on again
/// when you scroll to the end, so new lines don't yank the view away.
/// Needs macOS 15's scroll phases; on 14 Follow stays a manual checkbox.
private struct PauseFollowOnScroll: ViewModifier {
    @Binding var follow: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.modifier(ScrollPhaseFollow(follow: $follow))
        } else {
            content
        }
    }
}

@available(macOS 15, *)
private struct ScrollPhaseFollow: ViewModifier {
    @Binding var follow: Bool
    @State private var atEnd = true

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.visibleRect.maxY >= geometry.contentSize.height - 24
            } action: { _, now in
                atEnd = now
            }
            .onScrollPhaseChange { old, new in
                // Only your scrolling counts; Follow's own scrollTo doesn't
                // pass through these phases.
                if new == .tracking || new == .interacting {
                    if !atEnd { follow = false }
                } else if new == .idle, old == .interacting || old == .decelerating || old == .tracking {
                    follow = atEnd
                }
            }
    }
}
