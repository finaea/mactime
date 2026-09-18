import CryptoKit
import Foundation

enum SpanKind: String {
    case active   // user at the machine, app in front
    case idle     // no input past the idle threshold ("Away")
    case sleep    // machine was asleep — backfilled on wake
}

struct ActivitySpan: Identifiable, Equatable {
    let id: Int64
    let start: Date
    let end: Date
    let bundleId: String
    let appName: String
    let title: String?
    let url: String?
    let kind: SpanKind
    var duration: TimeInterval { end.timeIntervalSince(start) }
}

struct ScreenshotRecord: Identifiable, Equatable {
    let id: Int64
    let takenAt: Date
    let displayID: Int
    let path: String
    let thumbPath: String
    /// Held the focused window when the round was captured. Rows written before
    /// this column existed are all false; readers fall back to the first display.
    var isActive: Bool = false
}

struct AppTotal: Identifiable {
    var id: String { bundleId }
    let bundleId: String
    let appName: String
    let seconds: TimeInterval
}

struct TitleTotal: Identifiable {
    var id: String { title + (url ?? "") }
    let title: String
    let url: String?
    let seconds: TimeInterval
}

struct DayStat: Identifiable {
    var id: String { dayKey }
    let dayKey: String           // yyyy-MM-dd, local
    let firstActive: Date?
    let lastActive: Date?
    let activeSeconds: TimeInterval
    let idleSeconds: TimeInterval
    let sleepSeconds: TimeInterval
}

/// All persistence. Main-thread only (matches the trackers and UI).
final class Store {
    let dataDir: URL
    let screenshotsDir: URL
    let crypto: Crypto
    private let db: Database

    /// `directory` is only ever passed by the checks in Tests/, which need a
    /// store they can create, fill and throw away — the app always takes the
    /// default. Retention and erasure delete files, so exercising them against
    /// `~/Library/Application Support/MacTime` is not an option.
    ///
    /// `crypto` follows the same rule, and its default leans on it: a store
    /// given a directory is a throwaway, so it gets a throwaway key rather than
    /// reaching for the login keychain. A check run must never read the key the
    /// real store is sealed with, and — worse — must never be the thing that
    /// creates it. The consequence for the checks is that reopening the same
    /// directory needs the same `Crypto` passed back in; a fresh one cannot
    /// read what the last one wrote, which is the property being relied on.
    init(directory: URL? = nil, crypto: Crypto? = nil) {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dataDir = directory ?? appSupport.appendingPathComponent("MacTime", isDirectory: true)
        screenshotsDir = dataDir.appendingPathComponent("Screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: screenshotsDir, withIntermediateDirectories: true)
        self.crypto = crypto ?? (directory == nil
            ? Crypto.forLoginKeychain(dataDir: dataDir)
            : Crypto(key: SymmetricKey(size: .bits256)))
        // The read path reaches places a store reference doesn't — a thumbnail
        // cell holds a path and nothing else — so the resolved key is published
        // process-wide here, at the one point that runs exactly once per launch.
        Crypto.install(self.crypto)
        db = Database(path: dataDir.appendingPathComponent("MacTime.db").path)
        migrate()

        // Captures written before this shipped are plaintext, and up to a
        // ninety-day retention window of them can be sitting there. Sealing
        // them is background work that must not hold up launch, so it is
        // started and forgotten. Hung off `init` rather than off a service's
        // `start()` because this is the one place guaranteed to run once per
        // launch whatever the tracking settings say.
        if directory == nil { Rewrap.start(in: self) }
    }

    func close() { db.close() }

    private func migrate() {
        db.exec("""
        CREATE TABLE IF NOT EXISTS activity_spans (
            id INTEGER PRIMARY KEY,
            start REAL NOT NULL,
            end REAL NOT NULL,
            app_bundle_id TEXT NOT NULL DEFAULT '',
            app_name TEXT NOT NULL DEFAULT '',
            window_title TEXT,
            url TEXT,
            kind TEXT NOT NULL DEFAULT 'active'
        );
        CREATE INDEX IF NOT EXISTS idx_spans_start ON activity_spans(start);
        CREATE INDEX IF NOT EXISTS idx_spans_end ON activity_spans(end);
        CREATE TABLE IF NOT EXISTS screenshots (
            id INTEGER PRIMARY KEY,
            taken_at REAL NOT NULL,
            day TEXT NOT NULL,
            display_id INTEGER NOT NULL DEFAULT 0,
            path TEXT NOT NULL,
            thumb_path TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_shots_taken ON screenshots(taken_at);
        CREATE INDEX IF NOT EXISTS idx_shots_day ON screenshots(day);
        """)

        // Added after 1.0: which display held the focused window at capture
        // time. ALTER fails harmlessly once the column exists, and rows written
        // before this shipped keep 0 — the readers fall back to the first
        // display of the group, which is what they did before anyway.
        if !columnExists(table: "screenshots", column: "is_active") {
            db.exec("ALTER TABLE screenshots ADD COLUMN is_active INTEGER NOT NULL DEFAULT 0;")
        }

        if db.userVersion < 1 {
            repairDayKeys()
            db.userVersion = 1
        }
    }

    /// Rewrite `screenshots.day` values the old unpinned `Format.dayKey` wrote.
    ///
    /// Before it was pinned the formatter followed the user's region, so a
    /// Buddhist-calendar or Arabic-indic machine filled this column with
    /// `2569-09-15` / `٢٠٢٦-٠٩-١٥`. Nothing reads `day` for retention any more
    /// — that moved onto `taken_at` — but leaving two spellings in one column
    /// is a trap for anything written against it later, and the column is the
    /// only human-readable index this table has.
    ///
    /// `taken_at` is a unix timestamp, so it is the same number in every
    /// region: it, not the old string, decides. On a store that was always
    /// Latin-Gregorian every row already agrees and this writes nothing, which
    /// is the case that has to stay free. Runs once, gated on `user_version`.
    private func repairDayKeys() {
        var rows: [(id: Int64, takenAt: Date, day: String)] = []
        db.run("SELECT id, taken_at, day FROM screenshots") { s in
            rows.append((Database.int64(s, 0),
                         Date(timeIntervalSince1970: Database.double(s, 1)),
                         Database.text(s, 2) ?? ""))
        }
        let repairs = DayKey.repairs(in: rows)
        guard !repairs.isEmpty else { return }
        db.exec("BEGIN;")
        for repair in repairs {
            db.run("UPDATE screenshots SET day = ? WHERE id = ?", bind: [repair.day, repair.id])
        }
        db.exec("COMMIT;")
        NSLog("MacTime: re-spelled %d screenshot day keys under the pinned formatter",
              repairs.count)
    }

    private func columnExists(table: String, column: String) -> Bool {
        var found = false
        db.run("PRAGMA table_info(\(table));") { s in
            if Database.text(s, 1) == column { found = true }
        }
        return found
    }

    // ------------------------------------------------------------- spans

    func insertSpan(start: Date, end: Date, bundleId: String, appName: String,
                    title: String?, url: String?, kind: SpanKind) -> Int64 {
        db.run("""
        INSERT INTO activity_spans (start, end, app_bundle_id, app_name, window_title, url, kind)
        VALUES (?,?,?,?,?,?,?)
        """, bind: [start.timeIntervalSince1970, end.timeIntervalSince1970,
                    bundleId, appName, title, url, kind.rawValue])
        return db.lastInsertId
    }

    func updateSpanEnd(id: Int64, end: Date) {
        db.run("UPDATE activity_spans SET end = ? WHERE id = ?",
               bind: [end.timeIntervalSince1970, id])
    }

    /// Spans overlapping [from, to), ordered by start.
    func spans(from: Date, to: Date) -> [ActivitySpan] {
        var out: [ActivitySpan] = []
        db.run("""
        SELECT id, start, end, app_bundle_id, app_name, window_title, url, kind
        FROM activity_spans WHERE end > ? AND start < ? ORDER BY start
        """, bind: [from.timeIntervalSince1970, to.timeIntervalSince1970]) { s in
            out.append(ActivitySpan(
                id: Database.int64(s, 0),
                start: Date(timeIntervalSince1970: Database.double(s, 1)),
                end: Date(timeIntervalSince1970: Database.double(s, 2)),
                bundleId: Database.text(s, 3) ?? "",
                appName: Database.text(s, 4) ?? "",
                title: Database.text(s, 5),
                url: Database.text(s, 6),
                kind: SpanKind(rawValue: Database.text(s, 7) ?? "active") ?? .active))
        }
        return out
    }

    /// End timestamp of the most recent span, if any. Used at launch to spot downtime.
    func lastSpanEnd() -> Date? {
        var t: Double?
        db.run("SELECT MAX(end) FROM activity_spans") { s in
            let v = Database.double(s, 0)
            if v > 0 { t = v }
        }
        return t.map { Date(timeIntervalSince1970: $0) }
    }

    /// Per-app active seconds within [from, to), overlap-clamped, largest first.
    func appTotals(from: Date, to: Date) -> [AppTotal] {
        var out: [AppTotal] = []
        db.run("""
        SELECT app_bundle_id, app_name,
               SUM(MIN(end, ?2) - MAX(start, ?1)) AS secs
        FROM activity_spans
        WHERE end > ?1 AND start < ?2 AND kind = 'active'
        GROUP BY app_bundle_id ORDER BY secs DESC
        """, bind: [from.timeIntervalSince1970, to.timeIntervalSince1970]) { s in
            out.append(AppTotal(bundleId: Database.text(s, 0) ?? "",
                                appName: Database.text(s, 1) ?? "",
                                seconds: Database.double(s, 2)))
        }
        return out
    }

    /// Per-title (and URL) active seconds for one app within [from, to).
    func titleTotals(from: Date, to: Date, bundleId: String) -> [TitleTotal] {
        var out: [TitleTotal] = []
        db.run("""
        SELECT COALESCE(window_title, ''), url,
               SUM(MIN(end, ?2) - MAX(start, ?1)) AS secs
        FROM activity_spans
        WHERE end > ?1 AND start < ?2 AND kind = 'active' AND app_bundle_id = ?3
        GROUP BY window_title, url ORDER BY secs DESC
        """, bind: [from.timeIntervalSince1970, to.timeIntervalSince1970, bundleId]) { s in
            out.append(TitleTotal(title: Database.text(s, 0) ?? "",
                                  url: Database.text(s, 1),
                                  seconds: Database.double(s, 2)))
        }
        return out
    }

    /// Start of the earliest span — the "all time" range's left edge.
    func firstSpanStart() -> Date? {
        var t: Double?
        db.run("SELECT MIN(start) FROM activity_spans") { s in
            let v = Database.double(s, 0)
            if v > 0 { t = v }
        }
        return t.map { Date(timeIntervalSince1970: $0) }
    }

    /// Per-day rollup for Day duration / Attendance / Computer usage charts:
    /// first + last active moment and per-kind totals, one row per local day.
    /// Spans are split at local midnight and clamped to [from, to), so each day
    /// gets only its overlap — a weekend-long sleep span lands on every day it
    /// covers instead of dumping 48h on the day the lid closed.
    func dayStats(from: Date, to: Date) -> [DayStat] {
        struct Row { let start: Date; let end: Date; let kind: SpanKind }
        var rows: [Row] = []
        db.run("""
        SELECT start, end, kind FROM activity_spans
        WHERE end > ?1 AND start < ?2 ORDER BY start
        """, bind: [from.timeIntervalSince1970, to.timeIntervalSince1970]) { s in
            rows.append(Row(
                start: Date(timeIntervalSince1970: Database.double(s, 0)),
                end: Date(timeIntervalSince1970: Database.double(s, 1)),
                kind: SpanKind(rawValue: Database.text(s, 2) ?? "active") ?? .active))
        }

        struct Acc {
            var first: Date?
            var last: Date?
            var active: TimeInterval = 0
            var idle: TimeInterval = 0
            var sleep: TimeInterval = 0
        }
        let cal = Calendar.current
        var byDay: [String: Acc] = [:]
        for row in rows {
            var cursor = max(row.start, from)
            let clampedEnd = min(row.end, to)
            while cursor < clampedEnd {
                let nextMidnight = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: cursor))!
                let sliceEnd = min(clampedEnd, nextMidnight)
                let key = Format.dayKey.string(from: cursor)
                var acc = byDay[key, default: Acc()]
                switch row.kind {
                case .active:
                    acc.active += sliceEnd.timeIntervalSince(cursor)
                    if acc.first.map({ cursor < $0 }) ?? true { acc.first = cursor }
                    if acc.last.map({ sliceEnd > $0 }) ?? true { acc.last = sliceEnd }
                case .idle:
                    acc.idle += sliceEnd.timeIntervalSince(cursor)
                case .sleep:
                    acc.sleep += sliceEnd.timeIntervalSince(cursor)
                }
                byDay[key] = acc
                cursor = sliceEnd
            }
        }
        return byDay.keys.sorted().map { key in
            let acc = byDay[key]!
            return DayStat(dayKey: key, firstActive: acc.first, lastActive: acc.last,
                           activeSeconds: acc.active, idleSeconds: acc.idle,
                           sleepSeconds: acc.sleep)
        }
    }

    // ------------------------------------------------------------- screenshots

    /// `day` mirrors the folder the files landed in. It is provenance only —
    /// nothing queries it, because a day key is a name and names were once
    /// spelled per-region (see `Format.dayKey`). Anything selecting a time
    /// range uses `taken_at`.
    func insertScreenshot(takenAt: Date, day: String, displayID: Int, path: String,
                          thumbPath: String, isActive: Bool) {
        db.run("""
        INSERT INTO screenshots (taken_at, day, display_id, path, thumb_path, is_active)
        VALUES (?,?,?,?,?,?)
        """, bind: [takenAt.timeIntervalSince1970, day, displayID, path, thumbPath,
                    isActive ? 1 : 0])
    }

    func screenshots(from: Date, to: Date) -> [ScreenshotRecord] {
        var out: [ScreenshotRecord] = []
        db.run("""
        SELECT id, taken_at, display_id, path, thumb_path, is_active
        FROM screenshots WHERE taken_at >= ? AND taken_at < ? ORDER BY taken_at, display_id
        """, bind: [from.timeIntervalSince1970, to.timeIntervalSince1970]) { s in
            out.append(ScreenshotRecord(
                id: Database.int64(s, 0),
                takenAt: Date(timeIntervalSince1970: Database.double(s, 1)),
                displayID: Int(Database.int64(s, 2)),
                path: Database.text(s, 3) ?? "",
                thumbPath: Database.text(s, 4) ?? "",
                isActive: Database.int64(s, 5) == 1))
        }
        return out
    }

    /// Delete one screenshot row (viewer's Delete action). Files are the caller's job.
    func deleteScreenshot(id: Int64) {
        db.run("DELETE FROM screenshots WHERE id = ?", bind: [id])
    }

    /// Total bytes + count for the settings screen.
    func screenshotCount() -> Int {
        var n = 0
        db.run("SELECT COUNT(*) FROM screenshots") { s in n = Int(Database.int64(s, 0)) }
        return n
    }

    // ------------------------------------------------------------- erasure
    //
    // Retention and "delete my data" both live on these. Every one of them
    // takes timestamps, never a day key: `screenshots.day` and the folder names
    // it mirrors are *names*, written by a formatter that used to follow the
    // user's region, and comparing them is what let retention silently stop
    // pruning (see `Format.dayKey`). `taken_at` and `start` are unix seconds
    // and mean the same thing in every region.
    //
    // A nil bound is unbounded — bound as an infinity rather than built into
    // the SQL, so these stay single constant statements with no interpolation.

    private static func lower(_ d: Date?) -> Double { d?.timeIntervalSince1970 ?? -.greatestFiniteMagnitude }
    private static func upper(_ d: Date?) -> Double { d?.timeIntervalSince1970 ?? .greatestFiniteMagnitude }

    /// Captures in [from, to), with the files each one owns.
    func screenshotRows(from: Date?, to: Date?) -> [(id: Int64, path: String, thumbPath: String)] {
        var out: [(Int64, String, String)] = []
        db.run("SELECT id, path, thumb_path FROM screenshots WHERE taken_at >= ? AND taken_at < ?",
               bind: [Self.lower(from), Self.upper(to)]) { s in
            out.append((Database.int64(s, 0), Database.text(s, 1) ?? "", Database.text(s, 2) ?? ""))
        }
        return out
    }

    /// Delete exactly these capture rows. Files are the caller's job.
    ///
    /// By id rather than by range because the caller unlinks the files first,
    /// and capture keeps running while it does: deleting by range would also
    /// take a row inserted since the read, leaving its JPEG on disk with
    /// nothing left pointing at it — an orphan retention can no longer find.
    @discardableResult
    func deleteScreenshots(ids: [Int64]) -> Int {
        var deleted = 0
        // Chunked to stay clear of SQLite's bound-variable limit. The statement
        // is built from a count, never from anything a user typed.
        for chunk in stride(from: 0, to: ids.count, by: 500).map({
            Array(ids[$0..<min($0 + 500, ids.count)])
        }) {
            let holes = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            db.run("DELETE FROM screenshots WHERE id IN (\(holes))", bind: chunk)
            deleted += db.changes
        }
        return deleted
    }

    /// Delete every activity span *overlapping* [from, to).
    ///
    /// Overlap, not containment: a span carries one title and one URL for its
    /// whole length, so a span that reaches into an erased range describes the
    /// erased range too. Erring the other way would leave "delete this day"
    /// holding the titles of that day inside a span that started the evening
    /// before, which is not erasure. The cost is that erasing one day can take
    /// a span with it that also covered its neighbour — the honest trade for a
    /// feature whose whole job is that the data is gone.
    @discardableResult
    func deleteSpans(from: Date?, to: Date?) -> Int {
        db.run("DELETE FROM activity_spans WHERE end > ? AND start < ?",
               bind: [Self.lower(from), Self.upper(to)])
        return db.changes
    }

    /// What an erase would take, for the confirmation prompt.
    func counts(from: Date?, to: Date?) -> (screenshots: Int, spans: Int) {
        var shots = 0, spans = 0
        db.run("SELECT COUNT(*) FROM screenshots WHERE taken_at >= ? AND taken_at < ?",
               bind: [Self.lower(from), Self.upper(to)]) { s in shots = Int(Database.int64(s, 0)) }
        db.run("SELECT COUNT(*) FROM activity_spans WHERE end > ? AND start < ?",
               bind: [Self.lower(from), Self.upper(to)]) { s in spans = Int(Database.int64(s, 0)) }
        return (shots, spans)
    }

    /// Give back the pages a delete freed, instead of leaving the deleted rows
    /// legible in the file's free list — which is the whole point of an erase.
    ///
    /// The checkpoint either side is not optional: the database runs in WAL
    /// mode, so recent activity lives in `MacTime.db-wal` rather than in the
    /// file VACUUM rewrites. Truncating the WAL first folds it in; VACUUM's own
    /// rewrite then lands right back in a fresh WAL, so the second truncate is
    /// what actually leaves the bytes only in the compacted main file. (`-shm`
    /// is a scratch index for the WAL and holds no row data; it is rebuilt.)
    ///
    /// Cheap enough for the main thread — this database is a few MB even at
    /// 90-day retention; the slow half of an erase is unlinking the JPEGs.
    func compact() {
        db.exec("PRAGMA wal_checkpoint(TRUNCATE);")
        db.exec("VACUUM;")
        db.exec("PRAGMA wal_checkpoint(TRUNCATE);")
    }
}
