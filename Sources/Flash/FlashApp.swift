import SwiftUI
import AppKit
import ServiceManagement
import Combine

@main
struct FlashApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}

/// No SwiftUI window ever appears (`LSUIElement` in Info.plist), so the menu
/// bar item built here is the entire visible surface of the app.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private let statusMenuItem = NSMenuItem()
    private let watchToggleItem = NSMenuItem()
    private var cancellables = Set<AnyCancellable>()
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Singleton: if another Flash is already running, defer to it and die.
        // `make install` also pkills any prior instance before copying the
        // new build in, so this mainly guards against double-clicking the
        // .app while a launch-at-login instance is already up.
        if let bundleID = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0 != NSRunningApplication.current }
            if !others.isEmpty {
                Log.write("[app] another instance already running — exiting")
                NSApp.terminate(nil)
                return
            }
        }

        // Menu bar status item.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "bolt.shield.fill",
            accessibilityDescription: "Flash"
        )

        let menu = NSMenu()
        statusMenuItem.title = "Watching for auth prompts…"
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())

        watchToggleItem.action = #selector(toggleWatching)
        watchToggleItem.target = self
        menu.addItem(watchToggleItem)

        let test = NSMenuItem(title: "Test Flash", action: #selector(testFlash), keyEquivalent: "")
        test.target = self
        menu.addItem(test)

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Flash", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        Log.write("[app] status item installed in menu bar (v\(version), build \(build))")

        // Icon tint + menu text follow watcher + flash state. `receive(on:
        // RunLoop.main)` is what makes the `updateStatus` call below safe —
        // it guarantees this sink only ever fires already on the main run
        // loop, which is what lets it call a @MainActor method synchronously.
        WatchManager.shared.$isRunning
            .combineLatest(FlashController.shared.$iconState)
            .receive(on: RunLoop.main)
            .sink { [weak self] running, state in
                self?.updateStatus(running: running, state: state)
            }
            .store(in: &cancellables)

        // Start the engines if the user left them on.
        if WatchManager.shared.enabledPreference {
            WatchManager.shared.start()
        }
    }

    @MainActor
    private func updateStatus(running: Bool, state: FlashController.IconState) {
        watchToggleItem.title = running ? "Pause Watching" : "Resume Watching"

        guard running else {
            statusMenuItem.title = "Watching paused"
            statusItem.button?.contentTintColor = nil
            return
        }
        switch state {
        case .idle:
            statusMenuItem.title = "Watching for auth prompts…"
            statusItem.button?.contentTintColor = nil
        case .alerting:
            statusMenuItem.title = "⚡ Your key wants a touch!"
            statusItem.button?.contentTintColor = .systemOrange
        case .success:
            statusMenuItem.title = "✅ Touch confirmed"
            statusItem.button?.contentTintColor = .systemGreen
        }
    }

    @objc private func toggleWatching() {
        WatchManager.shared.toggle()
    }

    @objc private func testFlash() {
        Task { @MainActor in FlashController.shared.testPulse() }
    }

    @objc private func openSettings() {
        // Deliberately not using the private `showSettingsWindow:` selector
        // SwiftUI's `Settings` scene relies on — it depends on the scene
        // having registered on the responder chain, which .accessory apps
        // (no Dock icon, never "activate" a window on launch) don't
        // reliably reach. Owning the window ourselves always works.
        if settingsWindow == nil {
            // Explicit NSHostingView + a contentRect derived from its own
            // fittingSize, set directly as contentView. The
            // contentViewController route rendered blank — overriding
            // styleMask right after that convenience initializer likely
            // fought its own auto-sizing rather than adding to it.
            let hostingView = NSHostingView(rootView: SettingsView())
            let size = hostingView.fittingSize
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Flash Settings"
            window.contentView = hostingView
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

struct SettingsView: View {

    @AppStorage("flashColor") private var flashColor: FlashColor = .amber
    @AppStorage("reminderInterval") private var reminderInterval: ReminderInterval = .off
    @AppStorage("flashCount") private var flashCount: Int = 4
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Picker("Flash color", selection: $flashColor) {
                ForEach(FlashColor.allCases) { preset in
                    HStack {
                        Circle()
                            .fill(Color(preset.color))
                            .frame(width: 10, height: 10)
                        Text(preset.label)
                    }
                    .tag(preset)
                }
            }

            Picker("Remind again if ignored", selection: $reminderInterval) {
                ForEach(ReminderInterval.allCases) { interval in
                    Text(interval.label).tag(interval)
                }
            }

            Stepper("Flashes per alert: \(flashCount)", value: $flashCount, in: 2...6)

            Toggle("Launch at login", isOn: $launchAtLogin)
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
        .formStyle(.grouped)
        .frame(width: 340)
        .padding()
    }
}
