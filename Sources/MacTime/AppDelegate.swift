import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var pauseMenuItem: NSMenuItem?

    private(set) var store: Store!
    private(set) var activity: ActivityService!
    private(set) var screenshots: ScreenshotService!

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.registerDefaults()
        // Menu-bar-only at launch. macOS dropped the login item "Hide" checkbox in
        // Ventura and still offers no supported way to tell a login launch from a
        // manual one, so we never auto-open: the window appears only on an explicit
        // user action (tray item, or a reopen), which flips us back to .regular.
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = Self.makeMainMenu()

        store = Store()
        activity = ActivityService(store: store)
        screenshots = ScreenshotService(store: store)
        activity.start()
        screenshots.start()

        setupStatusItem()
        writeDiagnostics()
    }

    /// Permission ground truth, written where ssh can read it — the unified log
    /// hasn't been surfacing NSLog reliably and TCC's db isn't readable.
    private func writeDiagnostics() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [store] in
            let ownTitle = AX.focusedWindowTitle(pid: ProcessInfo.processInfo.processIdentifier)
            let front = NSWorkspace.shared.frontmostApplication
            let frontTitle = front.map { AX.focusedWindowTitle(pid: $0.processIdentifier) ?? "<nil>" } ?? "<no front app>"
            let status = """
            time: \(Date())
            axTrusted: \(AX.trusted)
            screenRecording: \(CGPreflightScreenCaptureAccess())
            ownWindowTitle: \(ownTitle ?? "<nil>")
            frontApp: \(front?.localizedName ?? "<none>") title: \(frontTitle)
            """
            try? status.write(to: store!.dataDir.appendingPathComponent("diagnostics.txt"),
                              atomically: true, encoding: .utf8)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        activity.stop()
        screenshots.stop()
        store.close()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // requirement: stay running; the status item keeps it reachable
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // ------------------------------------------------------------- status item

    /// The app icon's motif at menu-bar size: four curved screenshot brackets
    /// with a stopwatch centered. Template image so macOS tints it for the
    /// current menu bar appearance.
    static func makeStatusIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.setLineCap(.round)

            // corner brackets
            let frame = rect.insetBy(dx: 1, dy: 1)
            let r: CGFloat = 3.6, arm: CGFloat = 2.2
            ctx.setLineWidth(1.6)
            let corners: [(CGPoint, CGFloat)] = [
                (CGPoint(x: frame.minX + r, y: frame.maxY - r), .pi / 2),
                (CGPoint(x: frame.maxX - r, y: frame.maxY - r), 0),
                (CGPoint(x: frame.maxX - r, y: frame.minY + r), -.pi / 2),
                (CGPoint(x: frame.minX + r, y: frame.minY + r), .pi),
            ]
            for (center, start) in corners {
                let a0 = start, a1 = start + .pi / 2
                let p0 = CGPoint(x: center.x + r * cos(a0), y: center.y + r * sin(a0))
                let p1 = CGPoint(x: center.x + r * cos(a1), y: center.y + r * sin(a1))
                let t0 = CGPoint(x: -sin(a0), y: cos(a0))
                let t1 = CGPoint(x: -sin(a1), y: cos(a1))
                let path = CGMutablePath()
                path.move(to: CGPoint(x: p0.x - t0.x * arm, y: p0.y - t0.y * arm))
                path.addArc(center: center, radius: r, startAngle: a0, endAngle: a1, clockwise: false)
                path.move(to: p1)
                path.addLine(to: CGPoint(x: p1.x + t1.x * arm, y: p1.y + t1.y * arm))
                ctx.addPath(path)
                ctx.strokePath()
            }

            // stopwatch: body, crown, hand at ~1 o'clock
            let c = CGPoint(x: rect.midX, y: rect.midY - 0.6)
            let R: CGFloat = 3.7
            ctx.setLineWidth(1.3)
            ctx.strokeEllipse(in: CGRect(x: c.x - R, y: c.y - R, width: 2 * R, height: 2 * R))
            ctx.fill(CGRect(x: c.x - 0.7, y: c.y + R - 0.3, width: 1.4, height: 1.5))
            ctx.fill(CGRect(x: c.x - 1.5, y: c.y + R + 1.0, width: 3.0, height: 1.2))
            let handAngle: CGFloat = .pi / 3
            ctx.setLineWidth(1.1)
            let hand = CGMutablePath()
            hand.move(to: c)
            hand.addLine(to: CGPoint(x: c.x + (R - 1.2) * cos(handAngle),
                                     y: c.y + (R - 1.2) * sin(handAngle)))
            ctx.addPath(hand)
            ctx.strokePath()
            return true
        }
        image.isTemplate = true
        return image
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Self.makeStatusIcon()

        let menu = NSMenu()
        menu.addItem(withTitle: "Open MacTime", action: #selector(openMain), keyEquivalent: "o")
        menu.addItem(.separator())
        let pause = NSMenuItem(title: "Pause Tracking", action: #selector(togglePause), keyEquivalent: "")
        menu.addItem(pause)
        pauseMenuItem = pause
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit MacTime", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) {
            item.target = self
        }
        statusItem.menu = menu
    }

    @objc private func openMain() { showMainWindow() }

    @objc private func togglePause() {
        let paused = !activity.isPaused
        activity.isPaused = paused
        screenshots.isPaused = paused
        pauseMenuItem?.title = paused ? "Resume Tracking" : "Pause Tracking"
        statusItem.button?.image = paused
            ? NSImage(systemSymbolName: "pause.circle", accessibilityDescription: "MacTime paused")
            : Self.makeStatusIcon()
    }

    // ------------------------------------------------------------- windows

    func showMainWindow() {
        if mainWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            window.title = "MacTime"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: MainView(store: store))
            window.center()
            window.setFrameAutosaveName("MacTimeMain")
            observeClose(window)
            mainWindow = window
        }
        NSApp.setActivationPolicy(.regular)
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Dock icon only while a window is open: closing the last window drops the
    /// app to accessory (menu-bar-only) — trackers keep running either way.
    private func observeClose(_ window: NSWindow) {
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let anyVisible = (self.mainWindow?.isVisible ?? false)
                    || (self.settingsWindow?.isVisible ?? false)
                if !anyVisible { NSApp.setActivationPolicy(.accessory) }
            }
        }
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 560),
                styleMask: [.titled, .closable],
                backing: .buffered, defer: false)
            window.title = "MacTime Settings"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(store: store))
            window.center()
            observeClose(window)
            settingsWindow = window
        }
        NSApp.setActivationPolicy(.regular)
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // ------------------------------------------------------------- main menu

    /// Minimal main menu so Cmd+Q/W/C/V work; SPM apps get none for free.
    private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About MacTime",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide MacTime", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit MacTime", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        let windowItem = NSMenuItem()
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        return main
    }
}
