import SwiftUI
import AppKit
import ServiceManagement

/// Flash's only real window: native-style tabs, fixed size.
///
///   ┌ [Alerts] [Detection] [About] ┐
///   │ Alerts:    style · color · behavior
///   │ Detection: prompts · ssh · activity + folders
///   │ About:     header · launch at login · credits
///   └──────────────────────────────┘
///
/// Sriinnu: one long scrolling page outgrew laptop screens, and sizing a
/// window from SwiftUI's measured height kept losing that fight. So the view
/// fixes its own size (`windowSize`, capped to the screen), every tab
/// scrolls inside it as a safety net, and whoever hosts it (our NSWindow or
/// SwiftUI's Settings scene) just gets a known frame.
@MainActor
struct SettingsView: View {

    // Literal URL — can't fail to parse, so the force-unwrap is safe.
    static let repoURL = URL(string: "https://github.com/sriinnu/flash")!

    static var marketingVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    /// "0.3 (20260924…)" — marketing version plus the build stamp `make bundle`
    /// writes, so a screenshot of Settings says exactly which build it was.
    static var versionString: String {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        return build.map { "\(marketingVersion) (\($0))" } ?? marketingVersion
    }

    @AppStorage("flashColor") private var flashColor: FlashColor = .amber
    @AppStorage("alertStyle") private var alertStyle: AlertStyle = .comet
    @AppStorage("successRipple") private var successRipple: Bool = true
    @AppStorage("reminderInterval") private var reminderInterval: ReminderInterval = .off
    @AppStorage("flashCount") private var flashCount: Int = 4
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage("watchAuthPrompts") private var watchAuthPrompts: Bool = true
    @AppStorage("activityLog") private var activityLog: Bool = true
    @AppStorage("routeSSHPrompts") private var routeSSHPrompts: Bool = false
    @State private var watchRoots: [String] = FlashSettings.shared.watchRoots
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Tab: String {
        case alerts, detection, about
    }

    @AppStorage("settingsTab") private var tab: Tab = .alerts

    /// Tallest tab (Alerts) is ~500pt; capped so a small screen still fits.
    static var windowSize: NSSize {
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.height ?? 800
        return NSSize(width: 460, height: min(560, visible - 80))
    }

    var body: some View {
        TabView(selection: $tab) {
            page {
                styleCard
                colorCard
                behaviorCard
            }
            .tabItem { Label("Alerts", systemImage: "bolt.fill") }
            .tag(Tab.alerts)

            page {
                detectionCard
            }
            .tabItem { Label("Detection", systemImage: "eye") }
            .tag(Tab.detection)

            page {
                header
                systemCard
                footer
            }
            .tabItem { Label("About", systemImage: "info.circle") }
            .tag(Tab.about)
        }
        .padding(12)
        .frame(width: Self.windowSize.width, height: Self.windowSize.height)
    }

    private func page<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            VStack(spacing: 12) {
                content()
            }
            .padding(8)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text("Flash")
                    .font(.title2.weight(.semibold))
                Text("Never miss a key touch again.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("v\(Self.marketingVersion)")
                .font(.caption.monospacedDigit())
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 2)
    }

    // MARK: Alert style

    private var styleCard: some View {
        Card(title: "Alert style") {
            HStack(spacing: 8) {
                ForEach(AlertStyle.allCases) { style in
                    Button {
                        alertStyle = style
                    } label: {
                        StyleTile(style: style, selected: style == alertStyle, tint: tint)
                    }
                    .buttonStyle(.plain)
                    .help(style.label)
                }
            }

            HStack(alignment: .center, spacing: 12) {
                Text(alertStyle.blurb)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                // Plays whatever is picked right now — @AppStorage has already
                // written it through, so the controller reads the new style.
                Button {
                    Task { @MainActor in FlashController.shared.testPulse() }
                } label: {
                    Label("Preview", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
            }

            if reduceMotion {
                Label("Reduce Motion is on, so every alert plays as Classic flash.",
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Color

    private var colorCard: some View {
        Card(title: "Color") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 32, maximum: 36), spacing: 8)], spacing: 8) {
                ForEach(FlashColor.allCases) { preset in
                    Button {
                        flashColor = preset
                    } label: {
                        Swatch(preset: preset, selected: preset == flashColor)
                    }
                    .buttonStyle(.plain)
                    .help(preset.label)
                }
            }
            Text(flashColor.label)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Behavior

    private var behaviorCard: some View {
        Card(title: "Behavior") {
            Row(title: "Remind if ignored", subtitle: "Reminders always use Classic flash") {
                Picker("Remind if ignored", selection: $reminderInterval) {
                    ForEach(ReminderInterval.allCases) { interval in
                        Text(interval.label).tag(interval)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }

            Divider()

            Row(title: "Classic flashes", subtitle: "Pulses per Classic alert") {
                HStack(spacing: 6) {
                    Text("\(flashCount)")
                        .monospacedDigit()
                        .frame(minWidth: 16, alignment: .trailing)
                    Stepper("Classic flashes", value: $flashCount, in: 2...6)
                        .labelsHidden()
                }
            }

            Divider()

            Row(title: "Success ripple", subtitle: "Green rings when the touch lands") {
                HStack(spacing: 10) {
                    Button("Test") {
                        Task { @MainActor in FlashController.shared.testSuccess() }
                    }
                    .controlSize(.small)
                    Toggle("Success ripple", isOn: $successRipple)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }
        }
    }

    // MARK: Detection

    private var detectionCard: some View {
        Card(title: "Detection") {
            Row(title: "Auth prompts", subtitle: "Keychain, password, Touch ID and GPG PIN dialogs") {
                Toggle("Auth prompts", isOn: $watchAuthPrompts)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .onChange(of: watchAuthPrompts) { _, _ in WatchManager.shared.reloadWatchers() }
            }

            Divider()

            Row(title: "SSH prompts via Flash", subtitle: "Passphrases, PINs and key touches become dialogs, even from agents. Relaunch apps after changing") {
                Toggle("SSH prompts via Flash", isOn: $routeSSHPrompts)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .onChange(of: routeSSHPrompts) { _, on in SSHPromptRouting.apply(enabled: on) }
            }

            Divider()

            Row(title: "Activity log", subtitle: "Commits and pushes in the menu-bar panel. Never flashes") {
                Toggle("Activity log", isOn: $activityLog)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .onChange(of: activityLog) { _, _ in WatchManager.shared.reloadWatchers() }
            }

            if activityLog {
                VStack(alignment: .leading, spacing: 6) {
                    if watchRoots.isEmpty {
                        Text("No folders watched yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(watchRoots, id: \.self) { root in
                        HStack(spacing: 6) {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                            Text((root as NSString).abbreviatingWithTildeInPath)
                                .font(.callout.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button {
                                saveRoots(watchRoots.filter { $0 != root })
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Stop watching this folder")
                        }
                    }
                    Button {
                        addRoots()
                    } label: {
                        Label("Add folder…", systemImage: "plus")
                    }
                    .controlSize(.small)
                }
                .padding(.leading, 2)
            }
        }
    }

    /// Folder picker, straight AppKit. Multi-select, since code tends to
    /// live in two or three places.
    private func addRoots() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Watch"
        panel.message = "Pick folders that contain your git repos."
        guard panel.runModal() == .OK else { return }
        saveRoots(watchRoots + panel.urls.map(\.path))
    }

    private func saveRoots(_ roots: [String]) {
        FlashSettings.shared.watchRoots = roots
        watchRoots = FlashSettings.shared.watchRoots   // read back normalized
        WatchManager.shared.reloadWatchers()
    }

    // MARK: System

    private var systemCard: some View {
        Card(title: "System") {
            Row(title: "Launch at login") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 6) {
            Text("Made by Sriinnu")
            Text("·")
            Link("github.com/sriinnu/flash", destination: Self.repoURL)
            Spacer()
            Text(Self.versionString)
                .monospacedDigit()
                .textSelection(.enabled)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }

    /// The picked color's gradient, reused to tint the selected style tile
    /// so the panel previews both choices at once.
    private var tint: AnyShapeStyle {
        Swatch.fill(for: flashColor)
    }
}

// MARK: - Building blocks

/// Titled rounded panel — the one container every section uses.
private struct Card<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

/// Label (+ optional hint) on the left, control on the right.
private struct Row<Control: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        // Wrap, don't truncate: hints are the point.
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 12)
            control
        }
    }
}

/// Also used, compact (icon only), in the menu-bar panel.
struct StyleTile: View {
    let style: AlertStyle
    let selected: Bool
    let tint: AnyShapeStyle
    var compact = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        VStack(spacing: 6) {
            Image(systemName: style.symbol)
                .font(.system(size: 19, weight: .medium))
                .frame(height: 24)
                .foregroundStyle(selected ? tint : AnyShapeStyle(HierarchicalShapeStyle.secondary))
            if !compact {
                Text(style.shortLabel)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(selected ? .primary : .secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, compact ? 7 : 10)
        .background(shape.fill(Color.primary.opacity(selected ? 0.08 : 0.03)))
        .overlay(
            shape.strokeBorder(
                selected ? tint : AnyShapeStyle(Color.primary.opacity(0.08)),
                lineWidth: selected ? 2 : 1
            )
        )
        .contentShape(shape)
    }
}

struct Swatch: View {
    let preset: FlashColor
    let selected: Bool

    var body: some View {
        Circle()
            .fill(Self.fill(for: preset))
            .frame(width: 26, height: 26)
            .overlay {
                if preset == .random {
                    Image(systemName: "shuffle")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .padding(3)
            .overlay(
                Circle().strokeBorder(selected ? Color.primary.opacity(0.75) : .clear, lineWidth: 2)
            )
            .contentShape(Circle())
    }

    /// Presets show their real two-tone gradient; Random gets a hue wheel,
    /// since its actual colors are only rolled at alert time.
    static func fill(for preset: FlashColor) -> AnyShapeStyle {
        if preset == .random {
            return AnyShapeStyle(AngularGradient(
                colors: [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .red],
                center: .center
            ))
        }
        return AnyShapeStyle(LinearGradient(
            colors: preset.gradient.map { Color(nsColor: $0) },
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        ))
    }
}

// UI-only metadata — kept out of Settings.swift so the model stays AppKit/SF-free.
extension AlertStyle {
    var symbol: String {
        switch self {
        case .comet: return "arrow.triangle.merge"
        case .marquee: return "circle.dashed"
        case .targetLock: return "scope"
        case .heartbeat: return "waveform.path.ecg"
        case .classic: return "bolt.fill"
        }
    }

    var shortLabel: String {
        switch self {
        case .comet: return "Comet"
        case .marquee: return "Marquee"
        case .targetLock: return "Target"
        case .heartbeat: return "Heartbeat"
        case .classic: return "Classic"
        }
    }
}
