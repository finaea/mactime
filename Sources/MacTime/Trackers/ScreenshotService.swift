import AppKit
import ScreenCaptureKit

/// Interval screenshots of every display via ScreenCaptureKit, full jpg + thumbnail
/// per display, per-day folders, retention pruning. Skips when the screen is locked
/// or the user is idle. Failures are logged and the next round tries again (ss_int
/// behavior — never crash out over a transient capture error after wake).
final class ScreenshotService {
    private let store: Store
    private var timer: Timer?
    private var lastCaptureAt: Date?
    private var capturing = false
    private var captureTask: Task<Void, Never>?
    /// The key can't come back without a relaunch, so say so once rather than
    /// every five seconds for as long as the app is open.
    private var loggedKeyUnavailable = false
    private let encodeQueue = DispatchQueue(label: "mactime.screenshot.encode", qos: .utility)

    /// Pausing has to reach the round already in flight, not just the next one:
    /// a capture started a moment earlier would otherwise still land on disk
    /// (and in the database) seconds after the user asked us to stop.
    var isPaused = false {
        didSet { if isPaused { captureTask?.cancel() } }
    }

    init(store: Store) {
        self.store = store
    }

    func start() {
        if Settings.screenshotsEnabled, !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
        // Fixed 5s heartbeat; the actual capture interval is read from Settings each
        // time, so changing it in Settings needs no timer rebuild.
        let t = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.tick()
        }
        t.tolerance = 2
        timer = t
        prune()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        captureTask?.cancel()
    }

    private func tick() {
        guard Settings.screenshotsEnabled, !isPaused, !capturing else { return }
        guard !Self.isScreenLocked else { return }
        guard IdleMonitor.secondsSinceLastInput() < Settings.idleThresholdSeconds else { return }
        let now = Date()
        if let last = lastCaptureAt, now.timeIntervalSince(last) < Settings.screenshotIntervalSeconds {
            return
        }
        lastCaptureAt = now
        // A capture that can't be sealed must not be taken. Writing it in the
        // clear is exactly the problem encryption exists to fix, so dropping
        // the round is the lesser harm — and it is checked here, below the
        // interval test, so the compositor is never asked for a 5K frame that
        // is only going to be thrown away. Retention below still runs: leaving
        // captures past their window because the key went missing would be a
        // second failure on top of the first.
        if Crypto.shared.isReady {
            capturing = true
            captureTask = Task { @MainActor in
                await self.captureRound(at: now)
                self.capturing = false
            }
        } else if !loggedKeyUnavailable {
            loggedKeyUnavailable = true
            NSLog("MacTime: not capturing — %@",
                  Crypto.shared.unavailableReason ?? "no data key")
        }

        // Prune once a day, on the first tick past midnight.
        let day = Format.dayKey.string(from: now)
        if day != lastPruneDay {
            lastPruneDay = day
            prune()
        }
    }

    static var isScreenLocked: Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (dict["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    /// Display holding the focused window — "the screen you're working on".
    /// Falls back to the pointer's display, then the main display, so this
    /// always names one of the captured displays even without Accessibility.
    @MainActor
    private static func activeDisplayID() -> CGDirectDisplayID {
        if AX.trusted, let app = NSWorkspace.shared.frontmostApplication,
           let frame = AX.focusedWindowFrame(pid: app.processIdentifier),
           let id = display(containing: CGPoint(x: frame.midX, y: frame.midY)) {
            return id
        }
        // CGEvent location is already top-left-origin global coords, matching
        // CGDisplayBounds — no flipping needed.
        if let cursor = CGEvent(source: nil)?.location,
           let id = display(containing: cursor) {
            return id
        }
        return CGMainDisplayID()
    }

    private static func display(containing point: CGPoint) -> CGDirectDisplayID? {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first { CGDisplayBounds($0).contains(point) }
    }

    @MainActor
    private func captureRound(at ts: Date) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard shouldKeepCapturing else { return }
            let day = Format.dayKey.string(from: ts)
            let dayDir = store.screenshotsDir.appendingPathComponent(day, isDirectory: true)
            try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
            let activeID = Self.activeDisplayID()

            for display in content.displays {
                guard shouldKeepCapturing else { return }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                let scale = CGFloat(filter.pointPixelScale)
                config.width = Int(filter.contentRect.width * scale)
                config.height = Int(filter.contentRect.height * scale)
                config.showsCursor = true
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                // `save` is the commit point — past it the encode queue writes
                // files and a row regardless — so this is the last chance to
                // honor a pause that arrived mid-round.
                guard shouldKeepCapturing else { return }
                save(image, displayID: Int(display.displayID), at: ts, day: day, dayDir: dayDir,
                     isActive: display.displayID == activeID)
            }
        } catch {
            NSLog("MacTime: screenshot round failed (will retry): %@", "\(error)")
        }
    }

    /// Re-read between the awaits of a round: pause cancels the task, and
    /// Settings can be switched off while a round is still in the air.
    @MainActor
    private var shouldKeepCapturing: Bool {
        !Task.isCancelled && !isPaused && Settings.screenshotsEnabled
    }

    private func save(_ image: CGImage, displayID: Int, at ts: Date, day: String, dayDir: URL,
                      isActive: Bool) {
        let quality = Settings.screenshotQuality
        let stamp = Format.time.string(from: ts).replacingOccurrences(of: ":", with: "-")
        let base = "\(stamp)_\(displayID)"
        let fullURL = dayDir.appendingPathComponent(base + ".jpg")
        let thumbURL = dayDir.appendingPathComponent(base + ".thumb.jpg")

        encodeQueue.async { [store] in
            guard let full = Self.jpegData(image, quality: quality),
                  let thumbImage = Self.scaled(image, toHeight: 120),
                  let thumb = Self.jpegData(thumbImage, quality: 0.7) else {
                NSLog("MacTime: jpeg encode failed for %@", base)
                return
            }
            // Sealed here, on the encode queue, alongside the JPEG encode that
            // already costs tens of ms — AES runs in hardware on this target, so
            // a full frame is about 0.3 ms of it. Nothing about encryption
            // touches the main thread, which is what keeps the hover-scrub path
            // in DayView where it was.
            //
            // `tick` already refused the round without a key; this is the one
            // that matters, because it is the last point before bytes hit the
            // disk. There is no plaintext branch on purpose.
            let crypto = Crypto.shared
            guard let fullOut = try? crypto.seal(full), let thumbOut = try? crypto.seal(thumb) else {
                NSLog("MacTime: screenshot dropped, not written in the clear — %@",
                      crypto.unavailableReason ?? "encryption failed")
                return
            }
            do {
                // Atomically, so a crash or a kill mid-write can't leave a
                // truncated file behind. It mattered less when these were
                // JPEGs, which merely drew short; a half-written sealed capture
                // fails authentication and is simply lost.
                try fullOut.write(to: fullURL, options: .atomic)
                try thumbOut.write(to: thumbURL, options: .atomic)
            } catch {
                NSLog("MacTime: screenshot write failed: %@", "\(error)")
                return
            }
            DispatchQueue.main.async {
                store.insertScreenshot(takenAt: ts, day: day, displayID: displayID,
                                       path: fullURL.path, thumbPath: thumbURL.path,
                                       isActive: isActive)
            }
        }
    }

    private static func jpegData(_ image: CGImage, quality: Double) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality as NSNumber])
    }

    private static func scaled(_ image: CGImage, toHeight height: Int) -> CGImage? {
        let w = image.width, h = image.height
        guard h > 0 else { return nil }
        let outH = height
        let outW = max(1, w * outH / h)
        guard let ctx = CGContext(data: nil, width: outW, height: outH,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: outW, height: outH))
        return ctx.makeImage()
    }

    // ------------------------------------------------------------- retention

    private var lastPruneDay: String?
    private var pruning = false

    /// Delete captures older than the retention window.
    ///
    /// The cutoff is a *timestamp*. This used to compare day-folder names
    /// against a day key lexically, which only holds while the formatter keeps
    /// spelling days the same way — and it didn't: unpinned, `Format.dayKey`
    /// followed the user's region, so a machine that moved to a Buddhist
    /// calendar or Arabic-indic digits either destroyed history early
    /// (`"2026-…" < "2569-…"`) or, worse, matched nothing ever again and kept
    /// every screenshot forever while Settings still promised "Keep for 14
    /// days". `taken_at` is unix seconds and says the same thing everywhere.
    ///
    /// Runs off the main thread (unlinking a day is hundreds of files) and only
    /// one at a time — `start()` and the midnight tick can otherwise overlap
    /// while a sweep is still in flight.
    func prune() {
        guard !pruning else { return }
        let days = max(1, Settings.screenshotRetentionDays)
        let cal = Calendar.current
        guard let cutoff = cal.date(byAdding: .day, value: -(days - 1),
                                    to: cal.startOfDay(for: Date())) else { return }
        pruning = true
        Task { @MainActor [weak self, store] in
            await Erase.data(from: nil, to: cutoff, in: store)
            self?.pruning = false
        }
    }
}
