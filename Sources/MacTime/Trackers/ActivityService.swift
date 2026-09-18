import AppKit

/// Samples the foreground app every few seconds and collapses identical samples
/// into spans (heartbeat model). Idle and sleep get their own span kinds:
///  - idle spans are backdated to when input actually stopped
///  - sleep is detected on wake (and via missed ticks) and backfilled
/// Power-off can't be recorded by a process that isn't running — it shows up as
/// a gap with no spans at all.
final class ActivityService {
    private let store: Store
    private var timer: Timer?
    private var tickCount = 0
    private var lastTickAt: Date?

    /// Backed by `Settings` rather than held here, so a pause survives a quit,
    /// a crash and a reboot — see `Settings.Key.paused`. Both trackers read the
    /// same stored value, so neither can be left out of step with the other.
    var isPaused: Bool {
        get { Settings.paused }
        set {
            Settings.setPaused(newValue)
            if newValue {
                closeCurrent(at: Date())
            } else {
                // Resuming is the moment to ask for what a paused launch
                // deliberately didn't.
                requestPermissionIfNeeded()
            }
        }
    }

    /// Whether we should be recording at all. Ticks check this, but so do the
    /// sleep notifications — they write history without going through a tick,
    /// and "paused" has to mean paused for the night too, not just while awake.
    private var isTracking: Bool { Settings.trackingEnabled && !isPaused }

    private struct Sample: Equatable {
        var bundleId: String
        var appName: String
        var title: String?
        var url: String?
        var kind: SpanKind

        static func == (a: Sample, b: Sample) -> Bool {
            a.bundleId == b.bundleId && a.title == b.title && a.url == b.url && a.kind == b.kind
        }
    }

    private struct OpenSpan {
        let id: Int64
        var sample: Sample
        let start: Date
    }

    private var current: OpenSpan?

    static let sampleInterval: TimeInterval = 3
    private static let persistEveryNTicks = 5 // heartbeat the open span's end every ~15s

    init(store: Store) {
        self.store = store
    }

    /// Split out of `start()` because a launch that comes up paused must not
    /// prompt — being asked for Accessibility on the way back in, for tracking
    /// that is not going to happen, reads as the app ignoring the pause.
    func requestPermissionIfNeeded() {
        if !AX.trusted { AX.promptForTrust() }
    }

    func start() {
        if !isPaused { requestPermissionIfNeeded() }
        let t = Timer.scheduledTimer(withTimeInterval: Self.sampleInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        t.tolerance = 1
        timer = t

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        closeCurrent(at: Date())
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // ------------------------------------------------------------- sleep/wake

    private var sleptAt: Date?

    @objc private func willSleep(_ note: Notification) {
        let now = Date()
        closeCurrent(at: now)
        // Arm the backfill only if we were recording when the lid closed.
        // Pausing before closing it (or switching tracking off) otherwise still
        // laid the whole night down as a Sleep span on wake.
        sleptAt = isTracking ? now : nil
    }

    @objc private func didWake(_ note: Notification) {
        let now = Date()
        if var from = sleptAt, isTracking {
            // Dark-wake ticks record sleep spans while sleptAt is still set
            // (no didWake fires for them), so backfill only from where the
            // last recorded span left off — starting at lid close would lay a
            // second copy of the whole night on top of them.
            if let prev = store.lastSpanEnd(), prev > from { from = prev }
            if now.timeIntervalSince(from) > 5 {
                _ = store.insertSpan(start: from, end: now, bundleId: "", appName: "Sleep",
                                     title: nil, url: nil, kind: .sleep)
            }
        }
        sleptAt = nil
        lastTickAt = nil
    }

    // ------------------------------------------------------------- sampling

    private func tick() {
        let now = Date()
        defer { lastTickAt = now }

        // An erase is sweeping a range that may well be today's, and capture
        // carrying on underneath it is how a span outlives the delete that was
        // meant to take it. Closing the open span first matters as much as
        // skipping the sample: its row is about to be deleted, and a span left
        // open across the erase would have its end written back to a row that
        // no longer exists.
        guard isTracking, !CaptureSuspension.isSuspended else {
            closeCurrent(at: now)
            return
        }

        // Missed ticks well past the timer interval mean the machine was asleep or
        // suspended without a willSleep we saw. Close the open span at the last
        // heartbeat and backfill the hole as sleep.
        if let last = lastTickAt, now.timeIntervalSince(last) > Self.sampleInterval * 10 {
            closeCurrent(at: last)
            _ = store.insertSpan(start: last, end: now, bundleId: "", appName: "Sleep",
                                 title: nil, url: nil, kind: .sleep)
        }

        let sample = makeSample(at: now)

        if let cur = current, cur.sample == sample {
            tickCount += 1
            if tickCount % Self.persistEveryNTicks == 0 {
                store.updateSpanEnd(id: cur.id, end: now)
            }
            return
        }

        // Transition. Idle onset is backdated to when input actually stopped.
        var boundary = now
        if sample.kind == .idle, current?.sample.kind != .idle {
            boundary = now.addingTimeInterval(-IdleMonitor.secondsSinceLastInput())
            if let cur = current, boundary < cur.start { boundary = cur.start }
            // Never backdate into spans a previous run already wrote — the idle
            // clock keeps counting across an app restart, and an unclamped
            // backdate would overlap them and double-count Away time.
            if current == nil, let prev = store.lastSpanEnd(), boundary < prev {
                boundary = prev
            }
        }
        closeCurrent(at: boundary)
        let id = store.insertSpan(start: boundary, end: now, bundleId: sample.bundleId,
                                  appName: sample.appName, title: sample.title,
                                  url: sample.url, kind: sample.kind)
        current = OpenSpan(id: id, sample: sample, start: boundary)
        tickCount = 0
    }

    private func closeCurrent(at end: Date) {
        guard let cur = current else { return }
        store.updateSpanEnd(id: cur.id, end: max(end, cur.start))
        current = nil
    }

    /// Re-ask the browser for its URL at least this often, whatever the window
    /// title says. Slower than the sample interval on purpose — every refresh is
    /// an Apple Events round-trip — but not so slow that a long read on one page
    /// gets filed under the one before it.
    private static let urlRefreshInterval: TimeInterval = 15
    private var lastURLAt: Date?

    private func makeSample(at now: Date) -> Sample {
        // Dark wake: macOS woke itself for maintenance, with no user session.
        // Tested before the idle clock, which sees only "no input" and would
        // file the whole night as Away. Asking the power state directly — rather
        // than inferring it from the display being dark — keeps a screen that
        // merely slept while you kept working out of this branch.
        if PowerState.isDarkWake {
            return Sample(bundleId: "", appName: "Sleep", title: nil, url: nil, kind: .sleep)
        }
        if IdleMonitor.secondsSinceLastInput() >= Settings.idleThresholdSeconds {
            return Sample(bundleId: "", appName: "Away", title: nil, url: nil, kind: .idle)
        }
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return Sample(bundleId: "", appName: "Unknown", title: nil, url: nil, kind: .active)
        }
        let bundleId = app.bundleIdentifier ?? "pid.\(app.processIdentifier)"
        let name = app.localizedName ?? bundleId

        // The name above is kept whatever happens — an excluded app still has to
        // add up in the day's totals. Everything that says what was on screen
        // goes through the policy instead, and for an excluded app the block
        // below never runs at all: its title is not read, its browser is not
        // asked, and there is nothing to decide against storing.
        let detail = CapturePolicy.detail(for: bundleId,
                                          excludedBundleIDs: Settings.excludedBundleIDs,
                                          fullURLs: Settings.captureFullURLs) {
            let title = AX.trusted ? AX.focusedWindowTitle(pid: app.processIdentifier) : nil
            guard Settings.browserTrackingEnabled, BrowserService.isBrowser(bundleId) else {
                return (title, nil)
            }
            // Same app + same window title as the open span → probably the same
            // tab; reuse its URL instead of an Apple Events round-trip every 3s.
            // Only "probably", though: a title is not a URL identifier, and
            // single page apps (or a site whose pages are all "Inbox") navigate
            // without ever renaming the window. So the reuse expires — otherwise
            // every later span stays pinned to the first URL of the session.
            let fresh = lastURLAt.map { now.timeIntervalSince($0) < Self.urlRefreshInterval } ?? false
            if fresh, let cur = current, cur.sample.bundleId == bundleId, cur.sample.title == title {
                return (title, cur.sample.url)
            }
            lastURLAt = now
            return (title, BrowserService.activeURL(bundleId: bundleId, pid: app.processIdentifier))
        }
        return Sample(bundleId: bundleId, appName: name, title: detail.title, url: detail.url, kind: .active)
    }
}
