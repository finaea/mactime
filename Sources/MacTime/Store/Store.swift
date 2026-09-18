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
    /// given a directory but no `Crypto` is a throwaway, so it gets a throwaway
    /// key rather than reaching for the login keychain. A check run must never
    /// read the key the real store is sealed with, and — worse — must never be
    /// the thing that creates it.
    ///
    /// That is only the *default*, though. `crypto` is a parameter, so a check
    /// that needs a particular key with a particular directory passes one —
    /// which is also how a check reopens a store: a fresh throwaway key cannot
    /// read what the last one wrote, so the same `Crypto` has to come back in.
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
        // launch whatever the tracking settings say — which is also why the
        // export sweep lives here.
        if directory == nil {
            Task.detached(priority: .utility) { Store.sweepExports() }
            Rewrap.start(in: self)
        }
    }

    /// Where the viewer leaves decrypted copies of captures for Preview and
    /// anything else outside MacTime. Plaintext by necessity — Preview cannot
    /// read a sealed capture — and therefore swept at every launch.
    static let exportDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("MacTime", isDirectory: true)

    /// Throw away everything the viewer decrypted for another app.
    ///
    /// "The system clears the temporary directory between boots" is not a bound
    /// worth leaning on. A Mac left running for a fortnight would accumulate a
    /// plaintext copy of every capture its user thought worth opening — which
    /// is to say the interesting ones — in a directory that is not
    /// TCC-protected and that any process running as them reads freely. That is
    /// the finding this whole change exists to close, reopened for the worst
    /// possible subset of it. The 0600 mode those copies carry keeps out other
    /// *accounts*, and other accounts were never the attacker here.
    ///
    /// At launch rather than at quit, because an app that is force-quit or
    /// crashes never runs a terminate handler and this has to hold then too.
    /// The exposure that buys is one session instead of one boot.
    static func sweepExports(_ dir: URL = exportDir) {
        try? FileManager.default.removeItem(at: dir)
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
    //
    // `window_title` and `url` are sealed; `start`, `end`, `kind` and
    // `app_bundle_id` are not, which keeps `appTotals` and `dayStats` one SQL
    // statement each. The trade is worth saying out loud rather than burying:
    // someone reading the database file still learns which apps were used when.
    // They learn nothing about what the windows were called or which pages were
    // open, and those are the fields that read like `Q3 Layoff List.xlsx` or
    // carry a password-reset token in a query string.
    //
    // The column holds both formats for as long as `Rewrap` takes to work
    // through the rows written before this shipped. SQLite's type tag is what
    // separates them — see `unsealed`.

    /// Text for a column, sealed. Empty is stored as NULL rather than as 32
    /// bytes of ciphertext wrapping nothing; every reader already treats the
    /// two the same.
    ///
    /// Without a key this returns nil, so the span keeps its app, its times and
    /// its kind and loses only its title — the day still adds up, and the one
    /// field this change exists to protect does not land in the clear because
    /// the keychain happened to be unreachable.
    private func sealedText(_ text: String?) -> Data? {
        guard let text, !text.isEmpty else { return nil }
        return try? crypto.seal(Data(text.utf8))
    }

    func insertSpan(start: Date, end: Date, bundleId: String, appName: String,
                    title: String?, url: String?, kind: SpanKind) -> Int64 {
        db.run("""
        INSERT INTO activity_spans (start, end, app_bundle_id, app_name, window_title, url, kind)
        VALUES (?,?,?,?,?,?,?)
        """, bind: [start.timeIntervalSince1970, end.timeIntervalSince1970,
                    bundleId, appName, sealedText(title), sealedText(url), kind.rawValue])
        return db.lastInsertId
    }

    /// One title or URL column, whichever format the row happens to be in.
    ///
    /// A blob that won't open comes back as `Self.locked`, never as nil. nil
    /// reads as "nothing was recorded here", and telling someone their history
    /// is empty when it is merely unreadable is the one thing this must not do.
    private func unsealed(_ s: OpaquePointer, _ col: Int32) -> String? {
        switch Database.value(s, col) {
        case .null:
            return nil
        case .blob(let blob):
            guard let plain = try? crypto.open(blob),
                  let text = String(data: plain, encoding: .utf8) else { return Self.locked }
            return text
        case .text(let text):
            // Written before encryption and not yet rewritten by `Rewrap`.
            return text
        }
    }

    /// Stands in for a title or URL that is on disk but can't be read — a
    /// missing key, or a row that failed authentication.
    static let locked = "(encrypted — key unavailable)"

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
                title: self.unsealed(s, 5),
                url: self.unsealed(s, 6),
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
    ///
    /// Grouped in Swift rather than in SQL, which is the one query encrypting
    /// these columns costs. Every value is sealed under a fresh random nonce —
    /// it has to be, or identical titles would be identifiable as identical
    /// straight out of the file — so two visits to the same page hold different
    /// bytes and `GROUP BY window_title, url` would file each one on its own
    /// row. Decrypt first, then group.
    ///
    /// Affordable because of where it sits: one app, one range, so this walks
    /// the spans of a single app rather than the table. A day of *every* app's
    /// spans decrypts in about 1 ms. `appTotals` and `dayStats` never touch
    /// these columns and stay pure SQL.
    func titleTotals(from: Date, to: Date, bundleId: String) -> [TitleTotal] {
        var acc: [String: TitleTotal] = [:]
        db.run("""
        SELECT window_title, url, MIN(end, ?2) - MAX(start, ?1) AS secs
        FROM activity_spans
        WHERE end > ?1 AND start < ?2 AND kind = 'active' AND app_bundle_id = ?3
        """, bind: [from.timeIntervalSince1970, to.timeIntervalSince1970, bundleId]) { s in
            let title = self.unsealed(s, 0) ?? ""
            let url = self.unsealed(s, 1)
            let secs = Database.double(s, 2)
            // Separator no title can contain, so a title ending where a URL
            // begins can't collide with a different split of the same text.
            let key = title + "\u{1}" + (url ?? "")
            if let existing = acc[key] {
                acc[key] = TitleTotal(title: title, url: url, seconds: existing.seconds + secs)
            } else {
                acc[key] = TitleTotal(title: title, url: url, seconds: secs)
            }
        }
        // Ties broken by name: a dictionary has no order, and the table this
        // feeds would otherwise reshuffle equal rows between reloads.
        return acc.values.sorted {
            $0.seconds == $1.seconds ? $0.id < $1.id : $0.seconds > $1.seconds
        }
    }

    /// Seal one batch of the titles and URLs written before encryption, and say
    /// how many rows it rewrote. Zero means there are none left — which is also
    /// what it returns without a key, so the caller's loop ends rather than
    /// spinning.
    ///
    /// `typeof()` is the whole of the resume story: a row still holding TEXT
    /// hasn't been done, one holding a BLOB or NULL has. Nothing records how far
    /// a previous run got, so an interrupted pass costs only its last batch.
    ///
    /// Batched because `Store` is main-thread-only and a store at the ninety-day
    /// setting holds tens of thousands of these; the caller yields between
    /// batches so the window stays live.
    func sealPlaintextSpans(limit: Int = 500) -> Int {
        guard crypto.isReady else { return 0 }
        var rows: [(id: Int64, title: String?, url: String?)] = []
        db.run("""
        SELECT id, window_title, url FROM activity_spans
        WHERE typeof(window_title) = 'text' OR typeof(url) = 'text' LIMIT ?
        """, bind: [limit]) { s in
            rows.append((Database.int64(s, 0), Database.text(s, 1), Database.text(s, 2)))
        }
        guard !rows.isEmpty else { return 0 }

        // Sealed before the transaction opens, because this writes over the
        // only copy: a row whose title can't be sealed has to keep the title it
        // has rather than have it replaced with NULL. `sealedText` can only
        // fail without a key, which is checked above — but the cost of being
        // wrong here is silently deleting someone's history, so it is checked
        // again rather than assumed.
        var updates: [(id: Int64, title: Data?, url: Data?)] = []
        for row in rows {
            let title = sealedText(row.title), url = sealedText(row.url)
            guard (row.title?.isEmpty != false || title != nil),
                  (row.url?.isEmpty != false || url != nil) else { return 0 }
            updates.append((row.id, title, url))
        }

        db.exec("BEGIN;")
        for update in updates {
            db.run("UPDATE activity_spans SET window_title = ?, url = ? WHERE id = ?",
                   bind: [update.title, update.url, update.id])
        }
        db.exec("COMMIT;")
        return updates.count
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
