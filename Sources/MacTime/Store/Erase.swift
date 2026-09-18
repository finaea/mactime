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
    /// What an erase is allowed to take.
    ///
    /// Retention and the user's "Delete data" are the same operation over a
    /// different range — but deliberately *not* over the same tables. Deleting
    /// the activity history on a schedule is finding H1, which the user
    /// descoped; it must not arrive as a side effect of reusing this function
    /// for the daily sweep. It is a required argument and not a defaulted one
    /// precisely because that is how it got in: the call site said nothing, and
    /// nothing made it say.
    enum Contents {
        /// Captures and the activity history — window titles and URLs with them.
        /// What "Delete data" in Settings means.
        case capturesAndActivity
        /// Screenshots only. What the "Keep for" picker means, and all it has
        /// ever claimed to mean: it lives under Screenshots and says nothing
        /// about window titles, so it does not get to delete them.
        case capturesOnly
    }

    struct Summary {
        let screenshots: Int
        let spans: Int
        /// Unlink failures. Non-zero means files survived their rows — worth
        /// saying out loud in an erase, rather than reporting a clean wipe.
        let failedFiles: Int
    }

    /// Erase `contents` in [from, to); a nil bound is unbounded, so nil/nil is
    /// "delete all data".
    ///
    /// Unlinks each capture's files before deleting its row, and deletes only
    /// the rows whose files actually went. The ordering survives a crash — the
    /// rows left still name whatever survived, so re-running finishes the job —
    /// and the `removed` list survives the case the ordering alone does not: a
    /// single file that refuses to unlink. Deleting its row anyway would strand
    /// the file with nothing left pointing at it, where no later sweep or erase
    /// could ever reach it. A row that outlives its file is harmless and
    /// self-healing; the reverse is the orphan this ordering exists to prevent.
    ///
    /// Only the database work is main-thread; unlinking a day is hundreds of
    /// files and an erase-everything is tens of thousands.
    @MainActor
    @discardableResult
    static func data(from: Date?, to: Date?, in store: Store,
                     contents: Contents) async -> Summary {
        // Hold capture off for the whole erase. `defer` and not a pair of calls
        // at top and bottom: there are early returns below, and a hold that
        // leaks is a tracker that has quietly stopped recording with nothing
        // anywhere saying so — a worse bug than the one this is closing.
        CaptureSuspension.begin()
        defer { CaptureSuspension.end() }

        let dir = store.screenshotsDir
        // An erase that is leaving the activity history behind is not
        // "everything", whatever its range says, so it does not get to take the
        // things below that only a full wipe may take.
        let everything = from == nil && to == nil && contents == .capturesAndActivity
        // Read here: `Format.dayKey` is shared mutable state and the sweep runs
        // off the main thread.
        let todayKey = Format.dayKey.string(from: Date())
        let diagnostics = store.dataDir.appendingPathComponent("diagnostics.txt")
        let keyCheck = store.dataDir.appendingPathComponent(Crypto.checkFileName)

        var screenshots = 0, failed = 0
        // Collect, unlink, then delete exactly what went — and go round for
        // whatever landed in between. The suspension above stops new rounds and
        // turns back any round that hasn't reached its commit point, which
        // leaves one case: a capture already past that point, with its bytes on
        // the encode queue and its row not yet inserted. So the loop stays. It
        // is bounded rather than run to a fixed point because a capture
        // arriving after the last pass belongs to the next erase, not to an
        // infinite loop.
        //
        // Each capture is attempted at most once. The later passes are for
        // captures that arrived while we worked, never for retrying a file that
        // would not unlink: its row is still there, so it would come back
        // through `screenshotRows` every pass and be counted as a fresh failure
        // each time — one stuck file reported to the user as three.
        var attempted = Set<Int64>()
        for _ in 0..<3 {
            let rows = store.screenshotRows(from: from, to: to).filter { !attempted.contains($0.id) }
            if rows.isEmpty { break }
            attempted.formUnion(rows.map { $0.id })
            let files = rows.map { (id: $0.id, path: $0.path, thumb: $0.thumbPath) }
            let swept = await Task.detached(priority: .utility) {
                var removed: [Int64] = []
                var failed = 0
                for file in files {
                    var gone = true
                    for path in [file.path, file.thumb] where !path.isEmpty {
                        if !remove(path) {
                            failed += 1
                            gone = false
                        }
                    }
                    if gone { removed.append(file.id) }
                }
                return (removed: removed, failed: failed)
            }.value
            failed += swept.failed
            screenshots += store.deleteScreenshots(ids: swept.removed)
        }
        // Retention deletes captures and stops. See `Contents`.
        let spans = contents == .capturesAndActivity ? store.deleteSpans(from: from, to: to) : 0

        await Task.detached(priority: .utility) {
            sweepFolders(in: dir, from: from, to: to, todayKey: todayKey)
            // Written unconditionally 3s after every launch and it carries the
            // frontmost window's title, so "delete everything" has to take it
            // too — erasure that leaves a window title in plain text isn't.
            if everything {
                try? FileManager.default.removeItem(at: diagnostics)
                // The key-check file is what stops the app minting a new key
                // over data sealed with one it can't reach (`Crypto.resolve`).
                // Once everything sealed with that key is gone the interlock
                // has nothing left to protect, and leaving it would strand a
                // user whose key went missing with an app that will never
                // record again. This is the release valve: erase everything,
                // relaunch, get a fresh key.
                try? FileManager.default.removeItem(at: keyCheck)
            }
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
