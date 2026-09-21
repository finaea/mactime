import Foundation
import SQLite3

/// The queries export and import need, kept out of `Store` proper because they
/// exist for one feature and read in batches nothing else wants.
///
/// Everything here streams. `activity_spans` is never pruned — retention passes
/// `.capturesOnly` — so a long-lived store holds years of rows, and a method
/// that returned all of them would put the size of the archive into memory.
extension Store {

    // ------------------------------------------------------------- reading

    /// Day folders that actually have captures, oldest first.
    ///
    /// From the table rather than the filesystem: a row is what makes a capture
    /// part of the history, and a stray folder is not something to back up.
    func captureDays() -> [String] {
        var out: [String] = []
        withDatabase { db in
            db.run("SELECT DISTINCT day FROM screenshots ORDER BY taken_at") { s in
                if let day = Database.text(s, 0), !day.isEmpty { out.append(day) }
            }
        }
        return out
    }

    /// Every capture recorded on one day, with the file each one owns.
    func capturesForExport(day: String) -> [(takenAt: Date, displayID: Int, isActive: Bool, path: String)] {
        var out: [(Date, Int, Bool, String)] = []
        withDatabase { db in
            db.run("""
            SELECT taken_at, display_id, is_active, path FROM screenshots
            WHERE day = ? ORDER BY taken_at, display_id
            """, bind: [day]) { s in
                out.append((Date(timeIntervalSince1970: Database.double(s, 0)),
                            Int(Database.int64(s, 1)),
                            Database.int64(s, 2) == 1,
                            Database.text(s, 3) ?? ""))
            }
        }
        return out
    }

    /// A page of spans, decrypted, ordered by id so the caller can walk the
    /// whole table with the last id it saw.
    func spansForExport(after id: Int64, limit: Int) -> [(id: Int64, record: Archive.SpanRecord)] {
        var out: [(Int64, Archive.SpanRecord)] = []
        withDatabase { db in
            db.run("""
            SELECT id, start, end, app_bundle_id, app_name, window_title, url, kind
            FROM activity_spans WHERE id > ? ORDER BY id LIMIT ?
            """, bind: [id, limit]) { s in
                out.append((Database.int64(s, 0), Archive.SpanRecord(
                    start: Date(timeIntervalSince1970: Database.double(s, 1)),
                    end: Date(timeIntervalSince1970: Database.double(s, 2)),
                    bundleId: Database.text(s, 3) ?? "",
                    appName: Database.text(s, 4) ?? "",
                    title: self.exportText(s, 5),
                    url: self.exportText(s, 6),
                    kind: Database.text(s, 7) ?? SpanKind.active.rawValue)))
            }
        }
        return out
    }

    /// A title or URL on its way out of the app.
    ///
    /// Unlike the viewer's reader this returns nil rather than `Store.locked`
    /// for a value that will not open. The viewer shows a placeholder because a
    /// person is reading it and "empty" would be a lie; an archive is read by a
    /// program, and writing the placeholder string into it would turn an
    /// unreadable field into a literal window title called
    /// "(encrypted — key unavailable)" on the next import.
    private func exportText(_ s: OpaquePointer, _ col: Int32) -> String? {
        switch Database.value(s, col) {
        case .null: return nil
        case .text(let text): return text
        case .blob(let blob):
            guard let plain = try? crypto.open(blob) else { return nil }
            return String(data: plain, encoding: .utf8)
        }
    }

    func spanCount() -> Int {
        var n = 0
        withDatabase { db in
            db.run("SELECT COUNT(*) FROM activity_spans") { s in n = Int(Database.int64(s, 0)) }
        }
        return n
    }

    // ------------------------------------------------------------- writing

    /// Wrap bulk inserts in one transaction.
    ///
    /// Not an optimisation to skip: SQLite commits every statement on its own
    /// otherwise, and an import can carry a million spans. The `rollback` on a
    /// thrown error matters more — a staging database left holding half an
    /// import is a database that must not be swapped in.
    func inTransaction<T>(_ work: () throws -> T) rethrows -> T {
        withDatabase { $0.exec("BEGIN;") }
        do {
            let result = try work()
            withDatabase { $0.exec("COMMIT;") }
            return result
        } catch {
            withDatabase { $0.exec("ROLLBACK;") }
            throw error
        }
    }
}
