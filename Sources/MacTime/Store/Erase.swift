import Foundation

extension Notification.Name {
    /// Posted after captures or spans have been deleted, so the open Day and
    /// Statistics views reload instead of drawing rows that no longer exist.
    static let mactimeDataErased = Notification.Name("MacTimeDataErased")
}

/// Deleting captures and activity for a time range — Settings' "Delete data"
/// actions and the retention sweep, which are the same operation with a
/// different range.
///
/// The one place that removes *both* halves of a capture. `Store` deletes rows;
/// the JPEGs, the day folders and the freed database pages are handled here.
enum Erase {
    struct Summary {
        let screenshots: Int
        let spans: Int
        /// Unlink failures. Non-zero means files survived their rows — worth
        /// saying out loud in an erase, rather than reporting a clean wipe.
        let failedFiles: Int
    }

    /// Erase everything in [from, to); a nil bound is unbounded, so nil/nil is
    /// "delete all data".
    ///
    /// Unlinks each capture's files before deleting its row, so a crash in
    /// between leaves rows that still name whatever survived and re-running
    /// finishes the job. The other order strands those files with nothing left
    /// pointing at them — an orphan no later sweep can find, which is the
    /// unbounded-retention failure this whole change exists to close.
    ///
    /// Only the database work is main-thread; unlinking a day is hundreds of
    /// files and an erase-everything is tens of thousands.
    @MainActor
    @discardableResult
    static func data(from: Date?, to: Date?, in store: Store) async -> Summary {
        let dir = store.screenshotsDir
        let everything = from == nil && to == nil
        // Read here: `Format.dayKey` is shared mutable state and the sweep runs
        // off the main thread.
        let todayKey = Format.dayKey.string(from: Date())
        let diagnostics = store.dataDir.appendingPathComponent("diagnostics.txt")

        var screenshots = 0, failed = 0
        // Collect, unlink, then delete exactly what was collected — and go
        // round for whatever landed in between, because capture doesn't stop
        // while this runs. Bounded rather than run to a fixed point for the
        // same reason: a capture that arrives after the last pass belongs to
        // the next erase, not to an infinite loop.
        for _ in 0..<3 {
            let rows = store.screenshotRows(from: from, to: to)
            if rows.isEmpty { break }
            let files = rows.map { (path: $0.path, thumb: $0.thumbPath) }
            failed += await Task.detached(priority: .utility) {
                var failed = 0
                for file in files {
                    for path in [file.path, file.thumb] where !path.isEmpty {
                        if !remove(path) { failed += 1 }
                    }
                }
                return failed
            }.value
            screenshots += store.deleteScreenshots(ids: rows.map { $0.id })
        }
        let spans = store.deleteSpans(from: from, to: to)

        await Task.detached(priority: .utility) {
            sweepFolders(in: dir, from: from, to: to, todayKey: todayKey)
            // Written unconditionally 3s after every launch and it carries the
            // frontmost window's title, so "delete everything" has to take it
            // too — erasure that leaves a window title in plain text isn't.
            if everything { try? FileManager.default.removeItem(at: diagnostics) }
        }.value

        let summary = Summary(screenshots: screenshots, spans: spans, failedFiles: failed)
        // Nothing deleted is the ordinary case for the daily retention sweep,
        // and none of the tail is free: VACUUM rewrites the whole file, and the
        // other two throw away work the open views are using.
        guard screenshots + spans > 0 else { return summary }
        store.compact()
        // The cache is keyed by path, and a path is a timestamp — a later
        // capture in the same second reuses it — so stale entries aren't merely
        // wasted memory, they would draw deleted history.
        ImageCache.clear()
        NotificationCenter.default.post(name: .mactimeDataErased, object: nil)
        return summary
    }

    /// Remove the day folders the file pass left behind. `DayKey.sweep` holds
    /// the rules and the reasoning; this is the filesystem around it.
    private static func sweepFolders(in dir: URL, from: Date?, to: Date?, todayKey: String) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])
        else { return }
        for entry in entries {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let contents = isDir ? (try? fm.contentsOfDirectory(atPath: entry.path)) ?? [] : []
            let verdict = DayKey.sweep(entry: entry.lastPathComponent, isDirectory: isDir,
                                       isEmpty: contents.isEmpty, from: from, to: to,
                                       todayKey: todayKey)
            guard verdict != .keep else { continue }
            do {
                try fm.removeItem(at: entry)
            } catch {
                NSLog("MacTime: could not remove screenshot folder %@: %@",
                      entry.lastPathComponent, "\(error)")
            }
        }
    }

    private static func remove(_ path: String) -> Bool {
        let fm = FileManager.default
        do {
            try fm.removeItem(atPath: path)
            return true
        } catch {
            // Already gone counts as removed: a capture the user deleted in
            // Finder, or a re-run finishing an interrupted erase.
            return !fm.fileExists(atPath: path)
        }
    }
}
