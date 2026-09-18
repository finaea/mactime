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
        offerSuggestedExclusions()
    }

    // --------------------------------------------------- first-run exclusions

    /// Offered once, on the first launch where any of the suggested apps turns
    /// out to be installed. Asked here rather than left to whenever the user
    /// next opens Settings, because the captures an exclusion would have kept
    /// out of the archive are the ones taken before they got there.
    ///
    /// Delayed, because launch is already asking for Accessibility and Screen
    /// Recording, and a third dialog stacked on the system's two is how people
    /// end up dismissing all three without reading any of them.
    ///
    /// Nothing is excluded without a click, and both buttons are answers —
    /// "No thanks" is a decision, and it stops the asking too. Coming up with
    /// nothing to suggest is *not* an answer, so that leaves the question open:
    /// a password manager installed next month still gets offered.
    private func offerSuggestedExclusions() {
        guard !Settings.excludedAppsReviewed else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            let suggestions = ExcludedApps.suggestions(alreadyExcluded: Settings.excludedBundleIDs)
            guard !suggestions.isEmpty else { return }

            let names = suggestions.map(\.name).formatted(.list(type: .and))
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "Leave \(names) out of MacTime's screenshots?"
            alert.informativeText = """
                MacTime can cut these apps' windows out of every screenshot and never record \
                their window titles or web addresses. Whatever sits behind one is still \
                captured, and they still count towards your daily totals.

                This doesn't change anything already recorded, and you can edit the list any \
                time in Settings ▸ Excluded apps.
                """
            alert.addButton(withTitle: "Exclude These")
            alert.addButton(withTitle: "No Thanks")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                let merged = Settings.excludedBundleIDs.union(suggestions.map(\.bundleID))
                Settings.setExcludedBundleIDs(Array(merged))
            }
            Settings.setExcludedAppsReviewed(true)
        }
    }

    /// Permission ground truth, written where ssh can read it — the unified log
    /// hasn't been surfacing NSLog reliably and TCC's db isn't readable.
    private func writeDiagnostics() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [store] in
            let ownTitle = AX.focusedWindowTitle(pid: ProcessInfo.processInfo.processIdentifier)
            let front = NSWorkspace.shared.frontmostApplication
            let frontTitle = front.map { Self.diagnosticsTitle(for: $0) } ?? "<no front app>"
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

    /// The frontmost app's window title, when it is ours to write down.
    ///
    /// This file stays (it is permission ground truth, and M5 — dropping it —
    /// is descoped), but it was writing that title in plaintext three seconds
    /// after every launch, next to the now-encrypted database, consulting
    /// neither the exclusion list nor the pause state. Settings promises an
    /// excluded app's window titles are "never recorded"; a pause that now
    /// survives a restart has to mean a paused launch records nothing either.
    /// This one path made both statements false, and `Erase` already deletes
    /// this file on "Everything" for exactly the reason it should not have been
    /// written: erasure that leaves a window title in plain text isn't.
    ///
    /// The app's *name* still goes in — an excluded app is not a secret, it
    /// just stops saying what was on screen — and the reasons are spelled out
    /// rather than collapsed to one marker, because telling "Accessibility gave
    /// us nothing" apart from "we chose not to write it" is the whole job of
    /// this file.
    ///
    /// Routed through `CapturePolicy` instead of repeating its membership test,
    /// so there is one exclusion rule and not a second that can drift from it —
    /// and so an excluded app's title is never even read.
    private static func diagnosticsTitle(for app: NSRunningApplication) -> String {
        guard Settings.trackingEnabled else { return "<not recorded — tracking off>" }
        guard !Settings.paused else { return "<not recorded — paused>" }
        let bundleID = app.bundleIdentifier ?? "pid.\(app.processIdentifier)"
        guard !Settings.excludedBundleIDs.contains(bundleID) else {
            return "<not recorded — excluded app>"
        }
        return CapturePolicy.detail(for: bundleID,
                                    excludedBundleIDs: Settings.excludedBundleIDs,
                                    fullURLs: false) {
            (AX.trusted ? AX.focusedWindowTitle(pid: app.processIdentifier) : nil, nil)
        }.title ?? "<nil>"
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
        // Pause outlives the process now, so the menu bar has to be able to
        // say so at launch and not only after a click. An app that comes up
        // paused while still showing the recording icon is telling the user
        // the one thing it must never get wrong.
        renderPauseState()
    }

    @objc private func openMain() { showMainWindow() }

    @objc private func togglePause() {
        let paused = !activity.isPaused
        // Both, deliberately: they share the stored value, but each has its own
        // work to do on the way — closing the open span, cancelling the round
        // in flight, and asking for the permissions a paused launch withheld.
        activity.isPaused = paused
        screenshots.isPaused = paused
        renderPauseState()
    }

    private func renderPauseState() {
        let paused = activity.isPaused
        pauseMenuItem?.title = paused ? "Resume Tracking" : "Pause Tracking"
        statusItem.button?.image = paused
            ? NSImage(systemSymbolName: "pause.circle", accessibilityDescription: "MacTime paused")
            : Self.makeStatusIcon()
    }

    // ------------------------------------------------------------- windows

    /// True while the lock's prompt is up, so hammering the menu item can't
    /// stack a second one behind the first.
    private var authenticating = false

    /// Whether the app is already open, which is also what decides whether the
    /// lock asks. App-wide and not per-window on purpose: getting past the lock
    /// admits you to MacTime, so crossing from the window to Settings is not a
    /// second opening — and gating them separately would have made Settings the
    /// bypass anyway (open it, switch the lock off, open the window).
    private var hasVisibleWindow: Bool {
        (mainWindow?.isVisible ?? false) || (settingsWindow?.isVisible ?? false)
    }

    /// Every path that opens a window runs through here. Nothing about
    /// recording is downstream of it: a failed or cancelled prompt leaves the
    /// user tracked exactly as they asked to be, and only stops them looking.
    private func unlocked(_ present: @escaping () -> Void) {
        guard !authenticating else { return }
        AppLock.gate(
            enabled: Settings.requireAuthentication,
            alreadyVisible: hasVisibleWindow,
            authenticate: { [weak self] done in
                self?.authenticating = true
                AppLock.authenticate(reason: "open your activity history") { authenticated in
                    self?.authenticating = false
                    done(authenticated)
                }
            },
            present: present)
    }

    func showMainWindow() {
        unlocked { [weak self] in self?.presentMainWindow() }
    }

    private func presentMainWindow() {
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
                if !self.hasVisibleWindow { NSApp.setActivationPolicy(.accessory) }
            }
        }
    }

    @objc func openSettings() {
        unlocked { [weak self] in self?.presentSettingsWindow() }
    }

    private func presentSettingsWindow() {
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
