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
    private let db: Database

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dataDir = appSupport.appendingPathComponent("MacTime", isDirectory: true)
        screenshotsDir = dataDir.appendingPathComponent("Screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: screenshotsDir, withIntermediateDirectories: true)
        db = Database(path: dataDir.appendingPathComponent("MacTime.db").path)
        migrate()
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

    /// Delete rows for day keys strictly before `dayKey`. Files are the caller's job.
    func deleteScreenshotRows(before dayKey: String) {
        db.run("DELETE FROM screenshots WHERE day < ?", bind: [dayKey])
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
}
