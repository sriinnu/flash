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
// Whole class on the main actor: it's all AppKit/UI work, and only the
// NSApplicationDelegate witnesses get that isolation implicitly — plain
// @objc actions like openSettings() don't.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    /// Left-click: the rich panel. Right-click: `quickMenu`, a plain NSMenu
    /// for muscle memory and for when a popover is the wrong tool.
    private let popover = NSPopover()
    private let quickMenu = NSMenu()
    private let quickToggleItem = NSMenuItem()
    private var cancellables = Set<AnyCancellable>()
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Sriinnu: the app was quitting right after Test Flash with nothing
        // in the log. If an Obj-C exception (CoreAnimation / AppKit) is what
        // kills it, this at least leaves its name, reason and stack behind.
        NSSetUncaughtExceptionHandler { exception in
            Log.write("[crash] uncaught \(exception.name.rawValue): \(exception.reason ?? "no reason")")
            Log.write("[crash] stack:\n" + exception.callStackSymbols.joined(separator: "\n"))
        }

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

        // Menu bar status item. No `statusItem.menu` — a set menu swallows
        // the button's action, and the action is what opens the popover.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "bolt.shield.fill", accessibilityDescription: "Flash")
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let hosting = NSHostingController(rootView: MenuPanelView(
            flash: FlashController.shared,
            watch: WatchManager.shared,
            activity: ActivityLog.shared,
            openSettings: { [weak self] in
                self?.popover.performClose(nil)
                self?.openSettings()
            },
            quit: { NSApp.terminate(nil) }
        ))
        // Popover follows the SwiftUI view's size as its content changes.
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = true

        buildQuickMenu()
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

        // Exists from first launch so flash-notify can tell Flash is installed,
        // even while watching is paused.
        EventInbox.ensureDirectory()
        if FlashSettings.shared.routeSSHPrompts {
            SSHPromptRouting.apply(enabled: true)   // launchd forgot it at reboot
        }

        // Start the engines if the user left them on.
        if WatchManager.shared.enabledPreference {
            WatchManager.shared.start()
        }
    }

    private func buildQuickMenu() {
        quickToggleItem.action = #selector(toggleWatching)
        quickToggleItem.target = self
        quickMenu.addItem(quickToggleItem)

        let test = NSMenuItem(title: "Test Flash", action: #selector(testFlash), keyEquivalent: "")
        test.target = self
        quickMenu.addItem(test)

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        quickMenu.addItem(settings)

        quickMenu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Flash", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        quickMenu.addItem(quit)
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            // Attach, pop synchronously, detach — so the next left-click
            // still reaches this action instead of the menu.
            popover.performClose(nil)
            statusItem.menu = quickMenu
            sender.performClick(nil)
            statusItem.menu = nil
            return
        }

        if popover.isShown {
            popover.performClose(sender)
            return
        }
        FlashController.shared.refreshStats()
        // Accessory apps aren't active by default; without this the popover
        // can't become key, so ⌘, / ⌘Q and click-outside-to-close misbehave.
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func updateStatus(running: Bool, state: FlashController.IconState) {
        quickToggleItem.title = running ? "Pause Watching" : "Resume Watching"
        // Paused reads as a dimmed shield — visible at a glance, no popover needed.
        statusItem.button?.appearsDisabled = !running

        guard running else {
            statusItem.button?.toolTip = "Flash — paused"
            statusItem.button?.contentTintColor = nil
            return
        }
        switch state {
        case .idle:
            statusItem.button?.toolTip = "Flash — watching"
            statusItem.button?.contentTintColor = nil
        case .alerting:
            statusItem.button?.toolTip = "Flash — your key wants a touch"
            statusItem.button?.contentTintColor = .systemOrange
        case .success:
            statusItem.button?.toolTip = "Flash — touch confirmed"
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
