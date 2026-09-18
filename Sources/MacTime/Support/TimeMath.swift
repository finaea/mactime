import Foundation

/// Date math the charts and the statistics range header depend on, kept free of
/// AppKit and SwiftUI so it can be compiled and exercised on its own — see
/// tools/run-tests.sh.

/// Wall-clock hour of `date` within `dayKey`'s day, with the day's closing
/// midnight as hour 24.
///
/// Two things it has to get right. `dayStats()` clamps a span that crosses
/// midnight to the following midnight and files that instant under the day it
/// came from, so measuring from the timestamp's *own* start of day would read
/// it as hour 0 of the next day and stretch a 23:55–00:00 sliver into a
/// full-height bar. And the chart's Y axis is labelled in wall-clock hours, so
/// the answer has to be the hour on the clock — elapsed seconds since midnight
/// drift an hour either way on the 23- and 25-hour days, drawing every bar off
/// its own gridline, and on a fall-back day they saturate the 24 ceiling from
/// 23:00 onward and flatten that same sliver to nothing.
func hourOfDay(_ date: Date, dayKey: String, calendar cal: Calendar = .current) -> Double {
    let dayStart = startOfDay(forKey: dayKey, calendar: cal) ?? cal.startOfDay(for: date)
    guard let nextMidnight = cal.date(byAdding: .day, value: 1, to: dayStart) else { return 0 }
    if date >= nextMidnight { return 24 }
    if date <= dayStart { return 0 }
    let c = cal.dateComponents([.hour, .minute, .second], from: date)
    return Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60 + Double(c.second ?? 0) / 3600
}

/// Midnight opening `dayKey` (yyyy-MM-dd) in `cal`'s timezone.
///
/// Read by hand first, because that is what makes the calendar — and with it the
/// timezone — injectable, and a pinned calendar is the only way to write a check
/// for a DST day at all. `Format.dayKey` is pinned to `en_US_POSIX` now, so that
/// hand parse covers everything the app writes; the formatter fallback stays for
/// anything that reaches here spelled some other way, because losing the parse
/// silently falls back to the timestamp's own day and draws the midnight-crossing
/// bar wrong for exactly those callers.
private func startOfDay(forKey dayKey: String, calendar cal: Calendar) -> Date? {
    DayKey.startOfDay(forKey: dayKey, calendar: cal)
        ?? Format.dayKey.date(from: dayKey).map { cal.startOfDay(for: $0) }
}

/// From/To math for the statistics range header.
enum StatsRange {
    enum Preset: String, CaseIterable {
        case today = "Today"
        case yesterday = "Yesterday"
        case thisWeek = "This week"
        case previousWeek = "Previous week"
        case thisMonth = "This month"
        case previousMonth = "Previous month"
        case yearToDate = "Year to date"
        case allTime = "All time"
        case custom = "Custom"
    }

    /// The From/To a preset stands for. `.custom` has no canonical range — it is
    /// whatever the pickers currently hold — so it answers nil.
    static func dates(for preset: Preset, today now: Date, firstSpanStart: Date?,
                      calendar cal: Calendar = .current) -> (from: Date, to: Date)? {
        let today = cal.startOfDay(for: now)
        switch preset {
        case .today:
            return (today, today)
        case .yesterday:
            let y = cal.date(byAdding: .day, value: -1, to: today)!
            return (y, y)
        case .thisWeek:
            let interval = cal.dateInterval(of: .weekOfYear, for: today)!
            return (interval.start, min(today, interval.end.addingTimeInterval(-1)))
        case .previousWeek:
            let thisWeek = cal.dateInterval(of: .weekOfYear, for: today)!
            return (cal.date(byAdding: .weekOfYear, value: -1, to: thisWeek.start)!,
                    thisWeek.start.addingTimeInterval(-1))
        case .thisMonth:
            let interval = cal.dateInterval(of: .month, for: today)!
            return (interval.start, min(today, interval.end.addingTimeInterval(-1)))
        case .previousMonth:
            let thisMonth = cal.dateInterval(of: .month, for: today)!
            return (cal.date(byAdding: .month, value: -1, to: thisMonth.start)!,
                    thisMonth.start.addingTimeInterval(-1))
        case .yearToDate:
            return (cal.dateInterval(of: .year, for: today)!.start, today)
        case .allTime:
            return (firstSpanStart ?? today, today)
        case .custom:
            return nil
        }
    }

    /// What Next/Previous steps by.
    ///
    /// Deliberately not `Preset`. The two answer different questions, and one
    /// value can't hold both: stepping off "This month" makes the range Custom —
    /// it genuinely isn't this month any more, and the picker should say so —
    /// but it should still walk month by month rather than by whatever number of
    /// days that month happened to have. Keyed off `Preset`, only the first
    /// click after choosing a preset stepped by the right unit.
    enum Step {
        case day, week, month, length
    }

    /// What a change reported by the From/To pickers leaves the selection as.
    ///
    /// Both pickers fire for the view's *own* assignments — choosing a preset
    /// and stepping both move the same two dates the user drags — and they run
    /// after the new values are committed, so nothing about who moved them
    /// survives to be read. Both questions are therefore answered from values:
    ///
    /// - the range no longer standing for its preset is what demotes the picker
    ///   to Custom (a range that still matches was assigned by the preset, not
    ///   typed by the user);
    /// - the range no longer being the one the view last assigned is what makes
    ///   it the user's own, and a range of the user's own walks by its length
    ///   rather than by the unit some earlier preset chose. Once stepping has
    ///   already turned the picker Custom, this is the only thing left that can
    ///   tell the next Next/Previous from a hand edit.
    ///
    /// `lastAssigned` of nil means the view has assigned nothing yet, so
    /// whatever is in the pickers is treated as the user's.
    static func afterDateChange(preset: Preset, step: Step, from: Date, to: Date,
                                lastAssigned: (from: Date, to: Date)?, today: Date,
                                firstSpanStart: Date?,
                                calendar cal: Calendar = .current) -> (preset: Preset, step: Step) {
        let isOurs = lastAssigned.map { $0.from == from && $0.to == to } ?? false
        let stillThePreset = matches(preset: preset, from: from, to: to, today: today,
                                     firstSpanStart: firstSpanStart, calendar: cal)
        return (stillThePreset ? preset : .custom, isOurs ? step : .length)
    }

    /// The unit a preset walks in.
    static func step(for preset: Preset) -> Step {
        switch preset {
        case .today, .yesterday: return .day
        case .thisWeek, .previousWeek: return .week
        case .thisMonth, .previousMonth: return .month
        case .yearToDate, .allTime, .custom: return .length
        }
    }

    /// Whether From/To still hold exactly what `preset` stands for.
    ///
    /// Choosing a preset writes the same `fromDate`/`toDate` the user edits by
    /// hand, so the pickers' change handlers can't tell the two apart on their
    /// own — and a blunt "any change means Custom" demotes every preset the
    /// instant it is picked. Recomputing the preset's range is what separates
    /// them.
    static func matches(preset: Preset, from: Date, to: Date, today: Date,
                        firstSpanStart: Date?, calendar cal: Calendar = .current) -> Bool {
        guard let range = dates(for: preset, today: today, firstSpanStart: firstSpanStart,
                                calendar: cal) else { return preset == .custom }
        return range.from == from && range.to == to
    }

    /// The next/previous range.
    static func shifted(step: Step, from: Date, to: Date, by direction: Int,
                        calendar cal: Calendar = .current) -> (from: Date, to: Date) {
        switch step {
        case .day:
            let f = cal.date(byAdding: .day, value: direction, to: from)!
            return (f, f)
        case .week:
            let f = cal.date(byAdding: .weekOfYear, value: direction, to: from)!
            return (f, cal.date(byAdding: .day, value: 6, to: f)!)
        case .month:
            let f = cal.date(byAdding: .month, value: direction, to: from)!
            return (f, cal.dateInterval(of: .month, for: f)!.end.addingTimeInterval(-1))
        case .length:
            let days = inclusiveDayCount(from: from, to: to, calendar: cal)
            return (cal.date(byAdding: .day, value: direction * days, to: from)!,
                    cal.date(byAdding: .day, value: direction * days, to: to)!)
        }
    }

    /// Days a From/To range covers. Both ends are inclusive — the To picker
    /// shows the last *included* day — so Mon–Sun is seven days even though its
    /// date difference is six. Stepping by the difference would re-show the
    /// range's own last day as the next range's first.
    static func inclusiveDayCount(from: Date, to: Date,
                                  calendar cal: Calendar = .current) -> Int {
        let diff = cal.dateComponents([.day], from: cal.startOfDay(for: from),
                                      to: cal.startOfDay(for: to)).day ?? 0
        return max(1, diff + 1)
    }
}
