import Foundation

/// The rules retention and the day-key migration decide by, kept free of
/// AppKit, SwiftUI and SQLite so they can be compiled and exercised on their
/// own — see tools/run-tests.sh.
///
/// All of it exists because day keys are *names*, written by a formatter that
/// used to follow the user's region (see `Format.dayKey`). A store can hold
/// three spellings of the same day at once — `2026-09-15`, `2569-09-15`,
/// `٢٠٢٦-٠٩-١٥` — so nothing here may treat a key as a value to compare.
/// `taken_at` is a unix timestamp and is the only thing that is.
enum DayKey {

    // ------------------------------------------------------------- migration

    /// Rows whose stored `day` disagrees with their own `taken_at`.
    ///
    /// The whole of the migration's decision, so it can be checked without a
    /// database: hand it what the table holds, get back what to write. Returns
    /// nothing at all for a store that was always written under a Latin
    /// Gregorian region, which is the case that must stay a no-op.
    static func repairs(in rows: [(id: Int64, takenAt: Date, day: String)]) -> [(id: Int64, day: String)] {
        rows.compactMap { row in
            let correct = Format.dayKey.string(from: row.takenAt)
            return row.day == correct ? nil : (row.id, correct)
        }
    }

    // ------------------------------------------------------------- retention

    /// What a sweep of `Screenshots/` should do with one entry.
    enum Sweep: Equatable {
        case keep
        case removeEmpty      // a day folder whose captures are gone
        case removeCovered    // a day folder lying wholly inside the erased range
    }

    /// Decide an entry's fate, given the range being erased — a nil bound is
    /// unbounded, so nil/nil is "delete everything".
    ///
    /// Deliberately conservative. The sweep this replaces compared
    /// `entry.lastPathComponent < cutoff`, which would have deleted a stray
    /// `.DS_Store` without noticing, so anything not recognisably one of our
    /// day folders is left strictly alone.
    ///
    /// The two removal cases do different work:
    ///
    /// - `removeEmpty` needs no date at all, which is how a folder spelled the
    ///   old per-region way (`٢٠٢٦-٠٩-١٥`, `2569-09-15`) finally goes: the
    ///   captures inside it were deleted by `taken_at`, wherever they sat, so
    ///   it is empty by the time this runs. Without it those folders would sit
    ///   there forever — the accumulate-silently failure, surviving its own fix.
    ///   It is therefore the one verdict that ignores `from` and `to`
    ///   entirely, and the reason this can act outside the range it was handed:
    ///   a retention sweep at a fourteen-day cutoff also tidies away an empty
    ///   folder dated yesterday. Deliberate — an empty folder has no captures
    ///   to be inside a range or outside it, and the alternative is leaving it
    ///   until some later sweep's cutoff happens to pass its date. Today's is
    ///   the only one spared, for the reason below.
    /// - `removeCovered` is the only thing that can reach a JPEG with no row
    ///   (a file write that landed while its insert didn't), so it needs a
    ///   datable name and takes the whole folder. It fires only when the day it
    ///   names lies *wholly* inside the range: erasing one day must not take
    ///   the evening of its neighbour with it.
    ///
    /// Today's folder is never removed as empty — `captureRound` creates it and
    /// the encode queue fills it a moment later, so empty is its normal state
    /// for a beat, and deleting it there loses that round's write.
    static func sweep(entry name: String, isDirectory: Bool, isEmpty: Bool,
                      from: Date?, to: Date?, todayKey: String,
                      calendar cal: Calendar = .current) -> Sweep {
        guard isDirectory, looksLikeDayFolder(name) else { return .keep }
        if isEmpty { return name == todayKey ? .keep : .removeEmpty }
        if from == nil, to == nil { return .removeCovered }
        guard let start = startOfDay(forKey: name, calendar: cal),
              let end = cal.date(byAdding: .day, value: 1, to: start) else { return .keep }
        let atOrAfterStart = from.map { start >= $0 } ?? true
        let endsWithin = to.map { end <= $0 } ?? true
        return atOrAfterStart && endsWithin ? .removeCovered : .keep
    }

    /// Does `name` have a day folder's shape — four digits, two, two — in *any*
    /// numbering system?
    ///
    /// Looser than `startOfDay(forKey:)` on purpose, and only ever used to
    /// decide whether an *empty* directory is ours to tidy away. Folders
    /// written before the formatter was pinned carry Arabic-indic digits or a
    /// Buddhist year; both are ours, and leaving them behind forever is how the
    /// "screenshots accumulate silently" failure survives the fix.
    static func looksLikeDayFolder(_ name: String) -> Bool {
        let parts = name.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return false }
        return zip(parts, [4, 2, 2]).allSatisfy { part, width in
            part.count == width && part.allSatisfy(\.isNumber)
        }
    }

    /// Midnight opening the day `key` names, or nil when it isn't a key this
    /// app would write today. Read by hand so the calendar — and with it the
    /// time zone — is injectable, and because `Int()` reads ASCII digits only,
    /// which is exactly the strictness this wants.
    static func startOfDay(forKey key: String, calendar cal: Calendar = .current) -> Date? {
        let parts = key.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isASCII) }),
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              let date = cal.date(from: DateComponents(year: y, month: m, day: d))
        else { return nil }
        return cal.startOfDay(for: date)
    }
}
