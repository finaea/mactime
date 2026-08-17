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

    var isPaused = false {
        didSet { if isPaused { closeCurrent(at: Date()) } }
    }

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

    func start() {
        if !AX.trusted { AX.promptForTrust() }
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
        sleptAt = now
    }

    @objc private func didWake(_ note: Notification) {
        let now = Date()
        if let from = sleptAt, now.timeIntervalSince(from) > 5 {
            _ = store.insertSpan(start: from, end: now, bundleId: "", appName: "Sleep",
                                 title: nil, url: nil, kind: .sleep)
        }
        sleptAt = nil
        lastTickAt = nil
    }

    // ------------------------------------------------------------- sampling

    private func tick() {
        let now = Date()
        defer { lastTickAt = now }

        guard Settings.trackingEnabled, !isPaused else {
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

        let sample = makeSample()

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

    private func makeSample() -> Sample {
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
        let title = AX.trusted ? AX.focusedWindowTitle(pid: app.processIdentifier) : nil

        var url: String?
        if Settings.browserTrackingEnabled, BrowserService.isBrowser(bundleId) {
            // Same app + same window title as the open span → the tab hasn't changed;
            // reuse its URL instead of another Apple Events round-trip every 3s.
            if let cur = current, cur.sample.bundleId == bundleId, cur.sample.title == title {
                url = cur.sample.url
            } else {
                url = BrowserService.activeURL(bundleId: bundleId, pid: app.processIdentifier)
            }
        }
        return Sample(bundleId: bundleId, appName: name, title: title, url: url, kind: .active)
    }
}
