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
    private let encodeQueue = DispatchQueue(label: "mactime.screenshot.encode", qos: .utility)

    var isPaused = false

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
        capturing = true
        Task { @MainActor in
            await self.captureRound(at: now)
            self.capturing = false
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

    @MainActor
    private func captureRound(at ts: Date) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let day = Format.dayKey.string(from: ts)
            let dayDir = store.screenshotsDir.appendingPathComponent(day, isDirectory: true)
            try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)

            for display in content.displays {
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                let scale = CGFloat(filter.pointPixelScale)
                config.width = Int(filter.contentRect.width * scale)
                config.height = Int(filter.contentRect.height * scale)
                config.showsCursor = true
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                save(image, displayID: Int(display.displayID), at: ts, day: day, dayDir: dayDir)
            }
        } catch {
            NSLog("MacTime: screenshot round failed (will retry): %@", "\(error)")
        }
    }

    private func save(_ image: CGImage, displayID: Int, at ts: Date, day: String, dayDir: URL) {
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
            do {
                try full.write(to: fullURL)
                try thumb.write(to: thumbURL)
            } catch {
                NSLog("MacTime: screenshot write failed: %@", "\(error)")
                return
            }
            DispatchQueue.main.async {
                store.insertScreenshot(takenAt: ts, day: day, displayID: displayID,
                                       path: fullURL.path, thumbPath: thumbURL.path)
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

    /// Delete day folders (and their rows) older than the retention window.
    /// Folder names are yyyy-MM-dd, so string comparison is date comparison.
    func prune() {
        let days = max(1, Settings.screenshotRetentionDays)
        guard let cutoffDate = Calendar.current.date(byAdding: .day, value: -(days - 1),
                                                     to: Calendar.current.startOfDay(for: Date())) else { return }
        let cutoff = Format.dayKey.string(from: cutoffDate)
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: store.screenshotsDir,
                                                        includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.lastPathComponent < cutoff {
            try? fm.removeItem(at: entry)
        }
        store.deleteScreenshotRows(before: cutoff)
    }
}
