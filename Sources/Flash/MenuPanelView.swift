import SwiftUI

/// What a left-click on the menu-bar shield opens. It replaces the old plain
/// NSMenu: live status with an on/off switch, today's touches, a quick style
/// switcher and test buttons, then Settings and Quit as menu-style rows.
///
///   ┌──────────────────────────────┐
///   │ (◉) Watching          [on ]  │  status tracks the menu-bar icon
///   │     Waiting for a prompt     │
///   ├──────────────────────────────┤
///   │ 3 touches today │ 4m since … │
///   ├──────────────────────────────┤
///   │ ALERT STYLE           Comet  │
///   │ [⇉] [◌] [⌖] [∿] [⚡]          │
///   │ [▶ Test flash] [✓ Test succ] │
///   ├──────────────────────────────┤
///   │ RECENT                 Clear │  commits / pushes / prompts,
///   │ ↑ Pushed origin/main  Claude │  who did it when hooks know
///   ├──────────────────────────────┤
///   │ ⚙ Settings…              ⌘,  │
///   │ ⏻ Quit Flash             ⌘Q  │
///   └──────────────────────────────┘
// @MainActor explicitly: helper properties read @MainActor state, and only
// `body` is main-actor by default on pre-macOS-15 SDKs.
@MainActor
struct MenuPanelView: View {

    @ObservedObject var flash: FlashController
    @ObservedObject var watch: WatchManager
    @ObservedObject var activity: ActivityLog
    let openSettings: () -> Void
    let quit: () -> Void

    @AppStorage("alertStyle") private var alertStyle: AlertStyle = .comet
    @AppStorage("flashColor") private var flashColor: FlashColor = .amber

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusHeader
                .padding(14)
            Divider()
            stats
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            Divider()
            quickStyle
                .padding(14)
            Divider()
            recentActivity
                .padding(14)
            Divider()
            VStack(spacing: 2) {
                MenuRow(title: "Settings…", symbol: "gearshape", hint: "⌘,",
                        shortcut: KeyboardShortcut(",", modifiers: .command), action: openSettings)
                MenuRow(title: "Quit Flash", symbol: "power", hint: "⌘Q",
                        shortcut: KeyboardShortcut("q", modifiers: .command), action: quit)
            }
            .padding(6)
        }
        .frame(width: 300)
    }

    // MARK: Status

    private struct Status {
        let title: String
        let subtitle: String
        let symbol: String
        let color: Color
    }

    /// Mirrors the menu-bar icon's states, so the panel never disagrees
    /// with the shield you just clicked.
    private var status: Status {
        guard watch.isRunning else {
            return Status(title: "Paused", subtitle: "No alerts until you switch it back on",
                          symbol: "pause.fill", color: .secondary)
        }
        switch flash.iconState {
        case .idle:
            return Status(title: "Watching", subtitle: "Waiting for your next auth prompt",
                          symbol: "bolt.shield.fill", color: .accentColor)
        case .alerting:
            return Status(title: "Touch your key", subtitle: "Something is waiting on you",
                          symbol: "hand.tap.fill", color: .orange)
        case .success:
            return Status(title: "Touch confirmed", subtitle: "You're through",
                          symbol: "checkmark.seal.fill", color: .green)
        }
    }

    private var statusHeader: some View {
        let s = status
        return HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(s.color.opacity(0.18))
                Image(systemName: s.symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(s.color)
                    .symbolEffect(.pulse, isActive: watch.isRunning && flash.iconState == .alerting)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(s.title)
                    .font(.headline)
                Text(s.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Toggle("Watching", isOn: Binding(
                get: { watch.isRunning },
                set: { _ in watch.toggle() }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .help(watch.isRunning ? "Pause watching" : "Resume watching")
        }
    }

    // MARK: Stats

    private var stats: some View {
        HStack(spacing: 14) {
            StatBlock(
                value: Text("\(flash.touchesToday)"),
                label: flash.touchesToday == 1 ? "touch today" : "touches today"
            )
            Divider()
                .frame(height: 28)
            if let last = flash.lastAlertAt {
                // .relative ticks live while the panel is open.
                StatBlock(value: Text(last, style: .relative), label: "since last alert")
            } else {
                StatBlock(value: Text("—"), label: "no alerts yet")
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Quick style

    private var quickStyle: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("ALERT STYLE")
                    .font(.caption.weight(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(alertStyle.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                ForEach(AlertStyle.allCases) { style in
                    Button {
                        alertStyle = style
                    } label: {
                        StyleTile(style: style, selected: style == alertStyle,
                                  tint: Swatch.fill(for: flashColor), compact: true)
                    }
                    .buttonStyle(.plain)
                    .help(style.label)
                }
            }

            HStack(spacing: 8) {
                Button {
                    Task { @MainActor in FlashController.shared.testPulse() }
                } label: {
                    Label("Test flash", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    Task { @MainActor in FlashController.shared.testSuccess() }
                } label: {
                    Label("Test success", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

// MARK: - Recent activity

extension MenuPanelView {

    /// Oversight, not alerting: what agents (and you) did with your repos,
    /// plus which prompts fired. Five newest; the log keeps 50.
    var recentActivity: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("RECENT")
                    .font(.caption.weight(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                Spacer()
                if !activity.events.isEmpty {
                    Button("Clear") { activity.clear() }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if activity.events.isEmpty {
                Text("Commits, pushes and prompts from your watched folders show up here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(activity.events.prefix(5)) { event in
                    ActivityRow(event: event)
                }
            }
        }
    }
}

private struct ActivityRow: View {
    let event: ActivityEvent

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 16)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 1) {
                Text(event.summary)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if event.actor != .unknown {
                ActorChip(actor: event.actor)
            }
        }
    }

    private var symbol: String {
        switch event.kind {
        case .commit: return "checkmark.circle.fill"
        case .push: return "arrow.up.circle.fill"
        case .prompt: return "key.fill"
        }
    }

    private var tint: Color {
        switch event.kind {
        case .commit: return .secondary
        case .push: return .accentColor
        case .prompt: return .orange
        }
    }

    /// "flash · main · 4m ago"
    private var detail: String {
        let when = event.date.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))
        let place: [String] = [event.repo, event.kind == .commit ? event.ref : nil].compactMap { $0 }
        return (place + [when]).joined(separator: " · ")
    }
}

private struct ActorChip: View {
    let actor: Actor

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: actor.isAgent ? "sparkles" : "person.fill")
                .font(.system(size: 9, weight: .bold))
            Text(actor.label)
                .font(.caption2.weight(.medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(actor.isAgent ? Color.purple : Color.secondary)
        .background(
            Capsule().fill((actor.isAgent ? Color.purple : Color.primary).opacity(0.12))
        )
    }
}

// MARK: - Building blocks

private struct StatBlock: View {
    let value: Text
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            value
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Native-menu-feeling row: accent highlight on hover, shortcut hint on
/// the right, and the shortcut actually bound while the panel is key.
private struct MenuRow: View {
    let title: String
    let symbol: String
    let hint: String
    let shortcut: KeyboardShortcut?
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .frame(width: 18)
                Text(title)
                Spacer()
                Text(hint)
                    .font(.callout)
                    .opacity(0.6)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .foregroundStyle(hovering ? Color.white : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering ? Color.accentColor : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(shortcut)
        .onHover { hovering = $0 }
    }
}
