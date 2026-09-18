import CryptoKit
import Foundation

// Checks for the pure date math in Sources/MacTime/Support/TimeMath.swift.
//
// `swift test` builds the app target too, and this Command Line Tools install
// lacks the SwiftUI macro plugin needed by @State. These are plain checks in a
// standalone executable so `tools/run-tests.sh` can compile just this file and
// the two sources it exercises.

var checks = 0
var failures: [String] = []

func check(_ name: String, _ passed: Bool, _ detail: @autoclosure () -> String = "") {
    checks += 1
    guard !passed else { return }
    let d = detail()
    failures.append(d.isEmpty ? name : "\(name) — \(d)")
}

/// Fixed calendar so the range math doesn't depend on the machine's locale.
/// Weeks start Sunday, matching the attendance grid's assumption.
let cal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Europe/London")!
    c.firstWeekday = 1
    return c
}()

func day(_ y: Int, _ m: Int, _ d: Int, _ hh: Int = 0, _ mm: Int = 0) -> Date {
    cal.date(from: DateComponents(year: y, month: m, day: d, hour: hh, minute: mm))!
}

// Wednesday 2026-09-16, so "this week" is Sun 13th → today and has days on
// both sides of it.
let today = day(2026, 9, 16)

// ----------------------------------------------------------- inclusive length

check("single day counts as one",
      StatsRange.inclusiveDayCount(from: day(2026, 9, 16), to: day(2026, 9, 16), calendar: cal) == 1)

check("Mon–Sun counts as seven, not six",
      StatsRange.inclusiveDayCount(from: day(2026, 9, 14), to: day(2026, 9, 20), calendar: cal) == 7,
      "got \(StatsRange.inclusiveDayCount(from: day(2026, 9, 14), to: day(2026, 9, 20), calendar: cal))")

check("time of day doesn't change the count",
      StatsRange.inclusiveDayCount(from: day(2026, 9, 14, 23, 30), to: day(2026, 9, 20, 0, 5),
                                   calendar: cal) == 7)

// --------------------------------------------------------------------- shift

// The bug this guards: a seven-day range has a six-day date difference, so
// shifting by the difference re-showed the old range's last day.
do {
    let from = day(2026, 9, 14), to = day(2026, 9, 20)
    let next = StatsRange.shifted(step: StatsRange.step(for: .custom), from: from, to: to, by: 1, calendar: cal)
    check("custom next lands the day after the old range ends",
          next.from == day(2026, 9, 21), "got \(next.from)")
    check("custom next keeps the range seven days long",
          next.to == day(2026, 9, 27), "got \(next.to)")

    let prev = StatsRange.shifted(step: StatsRange.step(for: .custom), from: from, to: to, by: -1, calendar: cal)
    check("custom previous ends the day before the old range starts",
          prev.to == day(2026, 9, 13), "got \(prev.to)")
    check("custom previous round-trips",
          StatsRange.shifted(step: StatsRange.step(for: .custom), from: prev.from, to: prev.to, by: 1,
                             calendar: cal) == (from, to))
}

do {
    let week = StatsRange.dates(for: .thisWeek, today: today, firstSpanStart: nil, calendar: cal)!
    let next = StatsRange.shifted(step: StatsRange.step(for: .thisWeek), from: week.from, to: week.to, by: 1,
                                  calendar: cal)
    check("week next starts a week later", next.from == day(2026, 9, 20), "got \(next.from)")
    check("week next covers seven days",
          StatsRange.inclusiveDayCount(from: next.from, to: next.to, calendar: cal) == 7)
}

do {
    let next = StatsRange.shifted(step: StatsRange.step(for: .today), from: today, to: today, by: 1, calendar: cal)
    check("day next moves both ends together", next.from == day(2026, 9, 17) && next.to == next.from)
}

do {
    let month = StatsRange.dates(for: .thisMonth, today: today, firstSpanStart: nil, calendar: cal)!
    let next = StatsRange.shifted(step: StatsRange.step(for: .thisMonth), from: month.from, to: month.to, by: 1,
                                  calendar: cal)
    check("month next starts on the first", next.from == day(2026, 10, 1), "got \(next.from)")
    check("month next ends just before the month after",
          next.to == day(2026, 11, 1).addingTimeInterval(-1), "got \(next.to)")
}

// "Previous X" shares its shift branch with "this X" (both step by the same
// unit) — check the shared branch actually behaves for the "previous" side too.
do {
    let yest = StatsRange.dates(for: .yesterday, today: today, firstSpanStart: nil, calendar: cal)!
    let next = StatsRange.shifted(step: StatsRange.step(for: .yesterday), from: yest.from, to: yest.to, by: 1, calendar: cal)
    check("yesterday next lands on today", next == (today, today), "got \(next)")
}

do {
    let prevWeek = StatsRange.dates(for: .previousWeek, today: today, firstSpanStart: nil, calendar: cal)!
    let next = StatsRange.shifted(step: StatsRange.step(for: .previousWeek), from: prevWeek.from, to: prevWeek.to, by: 1,
                                  calendar: cal)
    check("previous week next steps forward seven days",
          next.from == cal.date(byAdding: .day, value: 7, to: prevWeek.from)!,
          "got \(next.from)")
    check("previous week next covers seven days",
          StatsRange.inclusiveDayCount(from: next.from, to: next.to, calendar: cal) == 7)
}

do {
    let prevMonth = StatsRange.dates(for: .previousMonth, today: today, firstSpanStart: nil, calendar: cal)!
    let next = StatsRange.shifted(step: StatsRange.step(for: .previousMonth), from: prevMonth.from, to: prevMonth.to, by: 1,
                                  calendar: cal)
    check("previous month next lands on the following month's first day",
          cal.component(.month, from: next.from) == cal.component(.month, from: prevMonth.from) + 1)
}

// .yearToDate and .allTime fall into the "anything else" branch: step by the
// range's own inclusive length rather than a calendar unit.
do {
    let ytd = StatsRange.dates(for: .yearToDate, today: today, firstSpanStart: nil, calendar: cal)!
    let days = StatsRange.inclusiveDayCount(from: ytd.from, to: ytd.to, calendar: cal)
    let next = StatsRange.shifted(step: StatsRange.step(for: .yearToDate), from: ytd.from, to: ytd.to, by: 1, calendar: cal)
    check("year-to-date next starts the day after the old range ends",
          next.from == cal.date(byAdding: .day, value: 1, to: ytd.to)!, "got \(next.from)")
    check("year-to-date next keeps the same length",
          StatsRange.inclusiveDayCount(from: next.from, to: next.to, calendar: cal) == days)
}

do {
    let all = StatsRange.dates(for: .allTime, today: today, firstSpanStart: day(2026, 9, 1), calendar: cal)!
    let next = StatsRange.shifted(step: StatsRange.step(for: .allTime), from: all.from, to: all.to, by: -1, calendar: cal)
    check("all time previous ends the day before the old range starts",
          next.to == cal.date(byAdding: .day, value: -1, to: all.from)!, "got \(next.to)")
}

// Month shifting has two traps a plain "wrap 12→13" or day-based add would
// hit: rolling the year, and landing on the target month's own last day
// rather than carrying over the source month's day count.
do {
    let dec = StatsRange.dates(for: .thisMonth, today: day(2026, 12, 15), firstSpanStart: nil, calendar: cal)!
    let next = StatsRange.shifted(step: StatsRange.step(for: .thisMonth), from: dec.from, to: dec.to, by: 1, calendar: cal)
    check("month next across a year boundary rolls the year",
          next.from == day(2027, 1, 1), "got \(next.from)")
}

do {
    // January is 31 days; February (2026, not a leap year) is 28. `to` must
    // land on Feb's last day, not carry Jan's day count forward.
    let jan = StatsRange.dates(for: .thisMonth, today: day(2026, 1, 15), firstSpanStart: nil, calendar: cal)!
    let next = StatsRange.shifted(step: StatsRange.step(for: .thisMonth), from: jan.from, to: jan.to, by: 1, calendar: cal)
    check("month next across a month-length change ends on the shorter month's own last day",
          next.to == day(2026, 3, 1).addingTimeInterval(-1), "got \(next.to)")
}

// The bug this guards: stepping makes the range Custom, so keying the step off
// the *preset* meant only the first click after choosing one walked by its unit
// — every click after it fell into the by-length branch. Days and weeks are a
// fixed number of days so they hid it; months are not, and from the second
// click the range straddled two months and never found a boundary again.
// Walking "This month" forward four times has to stay on month boundaries.
do {
    var range = StatsRange.dates(for: .thisMonth, today: today, firstSpanStart: nil, calendar: cal)!
    let step = StatsRange.step(for: .thisMonth)   // set once, as the view does
    var starts: [Date] = []
    var ends: [Date] = []
    for _ in 1...4 {
        range = StatsRange.shifted(step: step, from: range.from, to: range.to, by: 1, calendar: cal)
        starts.append(range.from)
        ends.append(range.to)
    }
    check("four Next clicks stay on the first of the month",
          starts == [day(2026, 10, 1), day(2026, 11, 1), day(2026, 12, 1), day(2027, 1, 1)],
          "got \(starts)")
    check("four Next clicks stay on each month's own last day",
          ends == [day(2026, 11, 1), day(2026, 12, 1), day(2027, 1, 1), day(2027, 2, 1)]
            .map { $0.addingTimeInterval(-1) },
          "got \(ends)")

    // …and back again: Previous has to undo Next exactly.
    for _ in 1...4 {
        range = StatsRange.shifted(step: step, from: range.from, to: range.to, by: -1, calendar: cal)
    }
    // Back to September — the month it started in. `to` is now the whole month
    // rather than the 1st–16th "This month" opened with, which is the point of
    // stepping.
    check("four Previous clicks undo the four Next clicks",
          range.from == day(2026, 9, 1), "got \(range.from)")
    check("and leave the whole month behind them",
          range.to == day(2026, 10, 1).addingTimeInterval(-1), "got \(range.to)")
}

do {
    // Weeks and days were already correct, but they run the same path now.
    var range = StatsRange.dates(for: .thisWeek, today: today, firstSpanStart: nil, calendar: cal)!
    let step = StatsRange.step(for: .thisWeek)
    for _ in 1...3 {
        range = StatsRange.shifted(step: step, from: range.from, to: range.to, by: 1, calendar: cal)
    }
    check("three week clicks land three Sundays on", range.from == day(2026, 10, 4), "got \(range.from)")
    check("three week clicks still cover seven days",
          StatsRange.inclusiveDayCount(from: range.from, to: range.to, calendar: cal) == 7)
}

check("only the month presets walk in months",
      StatsRange.Preset.allCases.filter { StatsRange.step(for: $0) == .month }
        == [.thisMonth, .previousMonth])
check("presets with no natural unit walk by length",
      StatsRange.step(for: .yearToDate) == .length && StatsRange.step(for: .allTime) == .length
        && StatsRange.step(for: .custom) == .length)

// ------------------------------------------------------------ preset identity

// The bug this guards: choosing a preset writes the same dates the user edits,
// so the pickers' change handler demoted every preset to Custom immediately.
for preset in StatsRange.Preset.allCases where preset != .custom {
    let range = StatsRange.dates(for: preset, today: today, firstSpanStart: day(2025, 1, 1),
                                 calendar: cal)!
    check("\(preset.rawValue) still recognises its own range",
          StatsRange.matches(preset: preset, from: range.from, to: range.to, today: today,
                             firstSpanStart: day(2025, 1, 1), calendar: cal))

    let nudged = cal.date(byAdding: .day, value: -1, to: range.from)!
    check("\(preset.rawValue) notices an edited From",
          !StatsRange.matches(preset: preset, from: nudged, to: range.to, today: today,
                              firstSpanStart: day(2025, 1, 1), calendar: cal))

    // The comparison checks both ends independently — an edit that only
    // touches To (dragging the end of a range) has to demote the preset too.
    let nudgedTo = cal.date(byAdding: .day, value: 1, to: range.to)!
    check("\(preset.rawValue) notices an edited To",
          !StatsRange.matches(preset: preset, from: range.from, to: nudgedTo, today: today,
                              firstSpanStart: day(2025, 1, 1), calendar: cal))
}

// All time is the one preset whose range depends on external state (the
// store's first span) rather than just `today` — exercise both sides of that.
check("all time falls back to today when there's no history yet",
      StatsRange.dates(for: .allTime, today: today, firstSpanStart: nil, calendar: cal)! == (today, today))
check("all time starts at the first recorded span",
      StatsRange.dates(for: .allTime, today: today, firstSpanStart: day(2020, 3, 1), calendar: cal)!
        == (day(2020, 3, 1), today))

check("custom has no canonical range",
      StatsRange.dates(for: .custom, today: today, firstSpanStart: nil, calendar: cal) == nil)
check("custom matches whatever it holds",
      StatsRange.matches(preset: .custom, from: day(2020, 3, 1), to: day(2020, 3, 4), today: today,
                         firstSpanStart: nil, calendar: cal))

// ------------------------------------------------- what a picker change means
//
// `afterDateChange` answers both questions the two `onChange` handlers have to
// answer, from values alone — they fire for the view's own assignments as well
// as the user's edits, and run after the new dates are already committed, so
// there is nothing else left to read. Walked here as the real UI sequences.
do {
    let month = StatsRange.dates(for: .thisMonth, today: today, firstSpanStart: nil, calendar: cal)!
    let monthStep = StatsRange.step(for: .thisMonth)

    // Choosing a preset: its own assignment must not demote it or lose its unit.
    let chosen = StatsRange.afterDateChange(
        preset: .thisMonth, step: monthStep, from: month.from, to: month.to,
        lastAssigned: month, today: today, firstSpanStart: nil, calendar: cal)
    check("a preset's own range keeps the preset", chosen.preset == .thisMonth)
    check("a preset's own range keeps its unit", chosen.step == .month)

    // Stepping: the picker becomes Custom (shift sets that itself), and the
    // range it assigned has to keep walking by month.
    let stepped = StatsRange.shifted(step: monthStep, from: month.from, to: month.to, by: 1,
                                     calendar: cal)
    let afterStep = StatsRange.afterDateChange(
        preset: .custom, step: monthStep, from: stepped.from, to: stepped.to,
        lastAssigned: stepped, today: today, firstSpanStart: nil, calendar: cal)
    check("a stepped range stays Custom", afterStep.preset == .custom)
    check("a stepped range keeps walking by month", afterStep.step == .month)

    // Hand-editing while a preset is selected: demote and step by length.
    let editedFrom = cal.date(byAdding: .day, value: 3, to: month.from)!
    let afterEdit = StatsRange.afterDateChange(
        preset: .thisMonth, step: monthStep, from: editedFrom, to: month.to,
        lastAssigned: month, today: today, firstSpanStart: nil, calendar: cal)
    check("editing a preset's range demotes it to Custom", afterEdit.preset == .custom)
    check("editing a preset's range steps by length", afterEdit.step == .length)

    // The one this closes: hand-editing *after* a step. `preset` is already
    // Custom, so `matches` says nothing — only the range differing from the one
    // the view assigned reveals the edit. Both ends have to count.
    let editedAfterStep = StatsRange.afterDateChange(
        preset: .custom, step: monthStep,
        from: stepped.from, to: cal.date(byAdding: .day, value: -5, to: stepped.to)!,
        lastAssigned: stepped, today: today, firstSpanStart: nil, calendar: cal)
    check("editing To after a step drops the month unit", editedAfterStep.step == .length)

    let editedFromAfterStep = StatsRange.afterDateChange(
        preset: .custom, step: monthStep,
        from: cal.date(byAdding: .day, value: 5, to: stepped.from)!, to: stepped.to,
        lastAssigned: stepped, today: today, firstSpanStart: nil, calendar: cal)
    check("editing From after a step drops the month unit", editedFromAfterStep.step == .length)

    // Nothing assigned yet: whatever is in the pickers is the user's.
    let unassigned = StatsRange.afterDateChange(
        preset: .custom, step: monthStep, from: month.from, to: month.to,
        lastAssigned: nil, today: today, firstSpanStart: nil, calendar: cal)
    check("with nothing assigned the range is treated as the user's",
          unassigned.step == .length)

    // Stepping repeatedly: every click reassigns, so the unit survives all of
    // them — this is the sequence that used to decay after the first click.
    var range = month
    var step = monthStep
    for _ in 1...4 {
        range = StatsRange.shifted(step: step, from: range.from, to: range.to, by: 1, calendar: cal)
        let after = StatsRange.afterDateChange(
            preset: .custom, step: step, from: range.from, to: range.to,
            lastAssigned: range, today: today, firstSpanStart: nil, calendar: cal)
        step = after.step
    }
    check("four steps in a row all keep the month unit", step == .month)
    check("and they end on a month boundary", range.from == day(2027, 1, 1), "got \(range.from)")
}

check("this week ends today, not on Saturday",
      StatsRange.dates(for: .thisWeek, today: today, firstSpanStart: nil, calendar: cal)!.to == today)

// Boundary days: `today` landing exactly on a unit's own first day. The
// `min(today, interval.end - 1)` clamp has to resolve to `today` here too,
// not to the far end of a range that hasn't happened yet.
do {
    // 2026-09-13 is a Sunday — the calendar's own firstWeekday (1) — so "this
    // week" starting there is the firstWeekday edge, not just any week start.
    let sunday = day(2026, 9, 13)
    check("this week starting on its own first day (a Sunday) is just today",
          StatsRange.dates(for: .thisWeek, today: sunday, firstSpanStart: nil, calendar: cal)! == (sunday, sunday))
}

do {
    let firstOfMonth = day(2026, 9, 1)
    check("this month starting on the 1st is just today",
          StatsRange.dates(for: .thisMonth, today: firstOfMonth, firstSpanStart: nil, calendar: cal)!
            == (firstOfMonth, firstOfMonth))
}

do {
    let newYearsDay = day(2026, 1, 1)
    check("year to date on Jan 1 is just today",
          StatsRange.dates(for: .yearToDate, today: newYearsDay, firstSpanStart: nil, calendar: cal)!
            == (newYearsDay, newYearsDay))
}

// ----------------------------------------------------------------- chart hour

// Dates here go through Format.dayKey, which uses the machine's timezone, so
// derive the key from the date rather than hard-coding one.
do {
    let cur = Calendar.current
    let start = cur.startOfDay(for: Date(timeIntervalSince1970: 1_789_000_000))
    let key = Format.dayKey.string(from: start)
    let nextMidnight = cur.date(byAdding: .day, value: 1, to: start)!

    check("start of the day is hour 0", hourOfDay(start, dayKey: key) == 0)
    check("midday is hour 12", hourOfDay(start.addingTimeInterval(12 * 3600), dayKey: key) == 12)

    // dayStats() clamps a span crossing midnight to the next midnight and files
    // it under the day it began on. Read against its own day that instant is
    // hour 0, which drew a five-minute span as a near-full-height bar.
    check("the following midnight is hour 24 of the day it closes",
          hourOfDay(nextMidnight, dayKey: key) == 24,
          "got \(hourOfDay(nextMidnight, dayKey: key))")

    let barHeight = hourOfDay(nextMidnight, dayKey: key)
        - hourOfDay(nextMidnight.addingTimeInterval(-300), dayKey: key)
    check("a 23:55–00:00 span is five minutes tall",
          abs(barHeight - 5.0 / 60) < 1e-9, "got \(barHeight) hours")

    check("an instant past the day is clamped to 24",
          hourOfDay(nextMidnight.addingTimeInterval(3600), dayKey: key) == 24)
    check("an unparseable day key falls back to the date's own day",
          hourOfDay(start.addingTimeInterval(3600), dayKey: "not-a-day") == 1)
}

// DST, hermetically: `hourOfDay` takes a calendar, so the transition days can be
// stated outright rather than depending on where this machine happens to be.
// America/New_York has both kinds — 2026-03-08 is 23 hours, 2026-11-01 is 25.
//
// The bug this guards: measuring elapsed seconds since midnight instead of
// reading the clock. On those days the two disagree by an hour, so every bar
// landed a gridline off the wall-clock hour the Y axis is labelled with — and on
// the 25-hour day the 24 ceiling saturated from 23:00 on, flattening the very
// 23:55→00:00 sliver this whole helper exists to draw.
let ny: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "America/New_York")!
    return c
}()

/// Wall-clock instant in New York. `DateComponents` resolves the repeated hour
/// on a fall-back day to the first (still daylight-saving) occurrence.
func nyAt(_ y: Int, _ m: Int, _ d: Int, _ hh: Int, _ mm: Int = 0) -> Date {
    ny.date(from: DateComponents(year: y, month: m, day: d, hour: hh, minute: mm))!
}

for (label, key, y, m, d) in [("spring forward", "2026-03-08", 2026, 3, 8),
                              ("fall back", "2026-11-01", 2026, 11, 1)] {
    check("\(label): 09:00 reads as hour 9",
          hourOfDay(nyAt(y, m, d, 9), dayKey: key, calendar: ny) == 9,
          "got \(hourOfDay(nyAt(y, m, d, 9), dayKey: key, calendar: ny))")
    check("\(label): 14:00 reads as hour 14",
          hourOfDay(nyAt(y, m, d, 14), dayKey: key, calendar: ny) == 14,
          "got \(hourOfDay(nyAt(y, m, d, 14), dayKey: key, calendar: ny))")
    check("\(label): 23:00 reads as hour 23",
          hourOfDay(nyAt(y, m, d, 23), dayKey: key, calendar: ny) == 23,
          "got \(hourOfDay(nyAt(y, m, d, 23), dayKey: key, calendar: ny))")
    check("\(label): the day opens at hour 0",
          hourOfDay(nyAt(y, m, d, 0), dayKey: key, calendar: ny) == 0)

    // The day's own closing midnight, however many hours away it actually is.
    let closing = ny.date(byAdding: .day, value: 1, to: ny.startOfDay(for: nyAt(y, m, d, 12)))!
    check("\(label): the closing midnight is hour 24",
          hourOfDay(closing, dayKey: key, calendar: ny) == 24,
          "got \(hourOfDay(closing, dayKey: key, calendar: ny))")

    let bar = hourOfDay(closing, dayKey: key, calendar: ny)
        - hourOfDay(closing.addingTimeInterval(-300), dayKey: key, calendar: ny)
    check("\(label): a 23:55–00:00 span is still five minutes tall",
          abs(bar - 5.0 / 60) < 1e-9, "got \(bar) hours")
}

// The keys the app stores come out of `Format.dayKey`, which has no fixed
// locale, so under a non-Latin numbering system it writes digits the ASCII hand
// parser can't read (`ar_EG` gives ٢٠٢٦-٠٩-١٦). When that parse fails silently
// `hourOfDay` falls back to the timestamp's own day — the original bug, restored
// for exactly those users. The formatter that wrote the key has to be able to
// read it back. Locale is swapped on the shared formatter and put back after.
do {
    let cur = Calendar.current
    let start = cur.startOfDay(for: Date(timeIntervalSince1970: 1_789_000_000))
    let nextMidnight = cur.date(byAdding: .day, value: 1, to: start)!

    let savedLocale = Format.dayKey.locale
    let originalKey = Format.dayKey.string(from: start)

    Format.dayKey.locale = Locale(identifier: "ar_EG")
    let key = Format.dayKey.string(from: start)
    let isNonASCII = !key.allSatisfy { $0.isASCII }

    // Guard the guard: if this CLT's ICU data ever emits Latin digits for ar_EG
    // the checks below would pass without exercising anything.
    check("ar_EG really does write a non-ASCII day key", isNonASCII, "key was \(key)")

    check("a non-Latin-digit key still closes at hour 24",
          hourOfDay(nextMidnight, dayKey: key, calendar: cur) == 24,
          "key \(key) gave \(hourOfDay(nextMidnight, dayKey: key, calendar: cur))")

    let bar = hourOfDay(nextMidnight, dayKey: key, calendar: cur)
        - hourOfDay(nextMidnight.addingTimeInterval(-300), dayKey: key, calendar: cur)
    check("a non-Latin-digit key still draws a five-minute 23:55–00:00 bar",
          abs(bar - 5.0 / 60) < 1e-9, "got \(bar) hours")

    check("a non-Latin-digit key still opens at hour 0",
          hourOfDay(start, dayKey: key, calendar: cur) == 0)

    Format.dayKey.locale = savedLocale

    // …and the swap really was undone, or every later check runs on a formatter
    // this block left behind. Checked by what the formatter writes, not by what
    // its `locale` property reads back: on a host whose own locale uses a
    // non-Latin numbering system, "is it ASCII" is the wrong answer, and a
    // saved-then-reassigned `Locale` doesn't reliably compare equal to itself
    // either. What has to hold is that the formatter behaves as it did before.
    check("the shared formatter writes what it wrote before the swap",
          Format.dayKey.string(from: start) == originalKey,
          "was \(originalKey), now \(Format.dayKey.string(from: start))")
}

// The transition days really are 23 and 25 hours long — if they weren't, the
// checks above would pass for the wrong reason.
check("the spring-forward day is 23 hours long",
      ny.date(byAdding: .day, value: 1, to: nyAt(2026, 3, 8, 0))!
        .timeIntervalSince(nyAt(2026, 3, 8, 0)) == 23 * 3600)
check("the fall-back day is 25 hours long",
      ny.date(byAdding: .day, value: 1, to: nyAt(2026, 11, 1, 0))!
        .timeIntervalSince(nyAt(2026, 11, 1, 0)) == 25 * 3600)

// ============================================================================
// Retention & erasure — Format.dayKey's pin, the day-key migration, range
// deletion, folder sweeping, and Erase.data end to end.
// ============================================================================

// -------------------------------------------------- Format.dayKey's two pins
//
// Format.dayKey pins `.locale` and `.calendar` independently, and they don't
// buy the same protection. Picked well away from any midnight so it can't
// straddle a day boundary under any of the locales/timezones this block uses.
do {
    let probe = Date(timeIntervalSince1970: 1_789_000_000)

    // Guard the guard: an unpinned formatter — no calendar override at all —
    // really does write the region's calendar/digits on this ICU data, or the
    // checks below would pass without exercising anything.
    func unpinned(_ localeID: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: localeID)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }
    let thBuddhist = unpinned("th_TH").string(from: probe)
    check("an unpinned th_TH formatter really does write a Buddhist year",
          thBuddhist.hasPrefix("2569-"), "got \(thBuddhist)")
    let arDigits = unpinned("ar_EG").string(from: probe)
    check("an unpinned ar_EG formatter really does write non-ASCII digits",
          !arDigits.allSatisfy { $0.isASCII }, "got \(arDigits)")

    // The calendar pin: swapping only `.locale` on the shared, already-pinned
    // formatter can't bring the Buddhist calendar back, because `.calendar`
    // was set explicitly and independently of locale. This is what keeps a
    // day-key column that was already Latin-Gregorian from drifting the
    // moment a user's region changes, without anyone touching `.calendar`.
    //
    // It is *not* a guarantee against every hostile locale: numbering-system
    // digits (ar_EG) are a locale property the calendar pin doesn't reach —
    // that gap is exactly what the pre-existing ar_EG block below exercises,
    // which is why this block only re-covers th_TH.
    let savedLocale = Format.dayKey.locale
    let originalKey = Format.dayKey.string(from: probe)

    Format.dayKey.locale = Locale(identifier: "th_TH")
    let underThLocale = Format.dayKey.string(from: probe)
    check("swapping locale alone can't undo the pinned Gregorian calendar",
          underThLocale == originalKey, "was \(originalKey), got \(underThLocale)")
    check("and it still reads back in ASCII digits",
          underThLocale.allSatisfy { $0.isASCII }, "got \(underThLocale)")

    Format.dayKey.locale = savedLocale
    check("the shared formatter writes what it wrote before the th_TH swap",
          Format.dayKey.string(from: probe) == originalKey,
          "was \(originalKey), now \(Format.dayKey.string(from: probe))")
}

// ------------------------------------------------------- DayKey.repairs pure
//
// The whole of the migration's decision, checked without a database: given
// rows in whatever spelling, does it propose exactly the ones that disagree
// with their own taken_at, rewritten under the pinned formatter?
do {
    let takenAt = Date(timeIntervalSince1970: 1_789_000_000)
    let correct = Format.dayKey.string(from: takenAt)

    check("a row already spelled correctly needs no repair — the no-op case",
          DayKey.repairs(in: [(id: 1, takenAt: takenAt, day: correct)]).isEmpty)

    let badRows: [(id: Int64, takenAt: Date, day: String)] = [
        (1, takenAt, "2569-09-10"),       // th_TH Buddhist spelling
        (2, takenAt, "٢٠٢٦-٠٩-١١"),       // ar_EG Arabic-indic spelling
    ]
    let repairs = DayKey.repairs(in: badRows)
    check("both mis-spelled rows are proposed for repair",
          repairs.count == 2, "got \(repairs.count)")
    check("repairs rewrite to the pinned spelling derived from taken_at",
          repairs.allSatisfy { $0.day == correct }, "got \(repairs)")
    check("repairs keep the row ids they were given",
          Set(repairs.map { $0.id }) == Set([1, 2]))
}

// -------------------------------------------------- Store's migration, live
//
// `Store.init` calls `migrate()` on every open, and migrate()'s last step is
// `if db.userVersion < 1 { repairDayKeys(); db.userVersion = 1 }` — which
// stamps version 1 the very first time any store is opened, including a
// brand-new empty one. So seeding a fresh `Store` and simply reopening it
// proves nothing: the second open's `userVersion < 1` is already false and
// the migration never runs. A real pre-upgrade database predates the
// migration entirely and sits at `user_version = 0`; `rewind` puts a freshly
// seeded database back into exactly that state, undoing the stamp `migrate()`
// just wrote, so reopening it exercises the real first-upgrade path.
func makeTempStoreDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("mactime-tests-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

func rewindToPreMigration(_ dir: URL) {
    let db = Database(path: dir.appendingPathComponent("MacTime.db").path)
    db.userVersion = 0
    db.close()
}

func readDayColumn(_ dir: URL) -> [Int64: String] {
    let db = Database(path: dir.appendingPathComponent("MacTime.db").path)
    var out: [Int64: String] = [:]
    db.run("SELECT id, day FROM screenshots") { s in
        out[Database.int64(s, 0)] = Database.text(s, 1)
    }
    db.close()
    return out
}

func readUserVersion(_ dir: URL) -> Int {
    let db = Database(path: dir.appendingPathComponent("MacTime.db").path)
    let v = db.userVersion
    db.close()
    return v
}

do {
    let dir = makeTempStoreDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let takenAt1 = Date(timeIntervalSince1970: 1_789_000_000)
    let takenAt2 = takenAt1.addingTimeInterval(86_400)
    let correct1 = Format.dayKey.string(from: takenAt1)
    let correct2 = Format.dayKey.string(from: takenAt2)

    var store = Store(directory: dir)
    store.insertScreenshot(takenAt: takenAt1, day: "2569-09-10", displayID: 0,
                           path: "", thumbPath: "", isActive: false)
    store.insertScreenshot(takenAt: takenAt2, day: "٢٠٢٦-٠٩-١١", displayID: 0,
                           path: "", thumbPath: "", isActive: false)
    store.close()
    rewindToPreMigration(dir)   // this store now looks exactly like a pre-upgrade one

    let seeded = readDayColumn(dir)
    check("seed values really are non-Latin/non-Gregorian before the repair runs",
          Set(seeded.values) == Set(["2569-09-10", "٢٠٢٦-٠٩-١١"]), "got \(seeded)")

    store = Store(directory: dir)   // migrate() runs here, for the first real time
    store.close()

    let repaired = readDayColumn(dir)
    check("the migration re-spells both legacy day keys under the pinned formatter",
          Set(repaired.values) == Set([correct1, correct2]), "got \(repaired)")
    check("user_version reaches 1 once the migration has run",
          readUserVersion(dir) == 1)

    // Reopening an already-migrated store must not re-run the repair or touch
    // rows a second time.
    store = Store(directory: dir)
    store.close()
    check("reopening an already-migrated store changes nothing",
          readDayColumn(dir) == repaired, "got \(readDayColumn(dir))")
}

do {
    // The case that has to stay free: a store that was always Latin-Gregorian
    // is never touched, even when it genuinely goes through the pre-upgrade →
    // migrate path rather than just starting at version 1.
    let dir = makeTempStoreDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let takenAt = Date(timeIntervalSince1970: 1_789_000_000)
    let correct = Format.dayKey.string(from: takenAt)

    var store = Store(directory: dir)
    store.insertScreenshot(takenAt: takenAt, day: correct, displayID: 0,
                           path: "", thumbPath: "", isActive: false)
    store.close()
    rewindToPreMigration(dir)

    let before = readDayColumn(dir)
    store = Store(directory: dir)
    store.close()
    check("a store that was always Latin-Gregorian comes back byte-identical",
          readDayColumn(dir) == before, "got \(readDayColumn(dir)) vs \(before)")
}

// ------------------------------------------------ range deletion boundaries
//
// [from, to) is half-open for screenshots — a capture at `from` goes, one at
// `to` survives, one a second before `to` goes.
do {
    let dir = makeTempStoreDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = Store(directory: dir)
    defer { store.close() }

    let from = Date(timeIntervalSince1970: 1_789_000_000)
    let to = from.addingTimeInterval(3600)

    store.insertScreenshot(takenAt: from, day: "d", displayID: 0,
                           path: "at-from", thumbPath: "", isActive: false)
    store.insertScreenshot(takenAt: to, day: "d", displayID: 0,
                           path: "at-to", thumbPath: "", isActive: false)
    store.insertScreenshot(takenAt: to.addingTimeInterval(-1), day: "d", displayID: 0,
                           path: "one-second-before-to", thumbPath: "", isActive: false)

    let rows = store.screenshotRows(from: from, to: to)
    let paths = Set(rows.map { $0.path })
    check("a capture exactly at `from` is included",
          paths.contains("at-from"))
    check("a capture exactly at `to` is excluded — [from, to) is half-open",
          !paths.contains("at-to"))
    check("a capture one second before `to` is included",
          paths.contains("one-second-before-to"))
    check("exactly the two in-range rows are selected", rows.count == 2, "got \(rows.count)")
    check("counts() agrees with screenshotRows()",
          store.counts(from: from, to: to).screenshots == rows.count)

    let deleted = store.deleteScreenshots(ids: rows.map { $0.id })
    check("deleteScreenshots deletes exactly the rows it was given",
          deleted == 2, "got \(deleted)")

    let remainingAfterBounded = store.screenshotRows(from: nil, to: nil)
    check("the row at `to` survives the bounded delete",
          remainingAfterBounded.contains { $0.path == "at-to" })
    check("nothing else survives the bounded delete",
          remainingAfterBounded.count == 1, "got \(remainingAfterBounded.count)")

    // One-sided bounds.
    check("a `from`-only range reaches to the end of time",
          store.screenshotRows(from: to, to: nil).contains { $0.path == "at-to" })
    check("a `to`-only range reaches back to the beginning of time",
          store.screenshotRows(from: nil, to: to.addingTimeInterval(1))
            .contains { $0.path == "at-to" })

    // nil/nil: delete everything.
    let deletedAll = store.deleteScreenshots(ids: store.screenshotRows(from: nil, to: nil).map { $0.id })
    check("nil/nil selects and deletes what's left",
          deletedAll == 1, "got \(deletedAll)")
    check("nothing remains after an unbounded delete",
          store.screenshotRows(from: nil, to: nil).isEmpty)
}

// deleteSpans is overlap, not containment, and deliberately so — a span
// carries one title for its whole length, so a span reaching into an erased
// range describes the erased range too.
do {
    let dir = makeTempStoreDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = Store(directory: dir)
    defer { store.close() }

    let from = Date(timeIntervalSince1970: 1_789_000_000)
    let to = from.addingTimeInterval(3600)

    // Straddles the left edge: starts before `from`, ends inside the range —
    // must be taken.
    let straddleId = store.insertSpan(start: from.addingTimeInterval(-60), end: from.addingTimeInterval(60),
                                      bundleId: "a", appName: "A", title: nil, url: nil, kind: .active)
    // Ends exactly at `from`: `end > from` is false, so it merely touches and
    // must survive.
    let touchId = store.insertSpan(start: from.addingTimeInterval(-120), end: from,
                                   bundleId: "b", appName: "B", title: nil, url: nil, kind: .active)

    let deleted = store.deleteSpans(from: from, to: to)
    check("a span straddling the left edge is deleted (overlap, not containment)",
          deleted == 1, "got \(deleted)")

    let remaining = store.spans(from: Date(timeIntervalSince1970: 0),
                                to: Date(timeIntervalSince1970: 2_000_000_000))
    check("a span that only touches `from` (end == from) survives — `end > from` is strict",
          remaining.contains { $0.id == touchId })
    check("the straddling span is really gone",
          !remaining.contains { $0.id == straddleId })
}

// -------------------------------------------------------------- DayKey.sweep
do {
    let sweepCal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()
    let todayKey = "2026-09-16"
    let from = sweepCal.date(from: DateComponents(year: 2026, month: 9, day: 10))!
    let to = sweepCal.date(from: DateComponents(year: 2026, month: 9, day: 15))!

    check(".DS_Store — not a directory — is left alone whatever the range",
          DayKey.sweep(entry: ".DS_Store", isDirectory: false, isEmpty: true,
                       from: nil, to: nil, todayKey: todayKey, calendar: sweepCal) == .keep)

    check("a non-day-shaped directory is left alone whatever the range",
          DayKey.sweep(entry: "Thumbnails", isDirectory: true, isEmpty: true,
                       from: nil, to: nil, todayKey: todayKey, calendar: sweepCal) == .keep)

    check("an empty day folder is removed",
          DayKey.sweep(entry: "2026-09-12", isDirectory: true, isEmpty: true,
                       from: from, to: to, todayKey: todayKey, calendar: sweepCal) == .removeEmpty)

    check("today's folder is kept even when empty — capture just created it",
          DayKey.sweep(entry: todayKey, isDirectory: true, isEmpty: true,
                       from: nil, to: nil, todayKey: todayKey, calendar: sweepCal) == .keep)

    check("a non-empty folder wholly inside the range is removed",
          DayKey.sweep(entry: "2026-09-12", isDirectory: true, isEmpty: false,
                       from: from, to: to, todayKey: todayKey, calendar: sweepCal) == .removeCovered)

    check("a non-empty folder only partly overlapping the range is kept",
          DayKey.sweep(entry: "2026-09-14", isDirectory: true, isEmpty: false,
                       from: from,
                       to: sweepCal.date(from: DateComponents(year: 2026, month: 9, day: 14, hour: 12))!,
                       todayKey: todayKey, calendar: sweepCal) == .keep,
          "day 14 only half falls inside [from, to)")

    // Legacy spellings: looksLikeDayFolder accepts them (digits are digits in
    // any numbering system), but a bounded range needs startOfDay to prove
    // containment, and that reads ASCII only.
    for legacy in ["٢٠٢٦-٠٩-١٥", "2569-09-15"] {
        check("a non-empty legacy-spelled folder (\(legacy)) is kept for a bounded range",
              DayKey.sweep(entry: legacy, isDirectory: true, isEmpty: false,
                           from: from, to: to, todayKey: todayKey, calendar: sweepCal) == .keep)
        check("but removed outright when both bounds are nil (\(legacy))",
              DayKey.sweep(entry: legacy, isDirectory: true, isEmpty: false,
                           from: nil, to: nil, todayKey: todayKey, calendar: sweepCal) == .removeCovered)
    }
}

// ------------------------------------------------------- Erase.data, live
//
// The one place that removes both halves of a capture, against a real temp
// store with real files on disk.
await { () async -> Void in
    let dir = makeTempStoreDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = Store(directory: dir)

    let takenAt = Date(timeIntervalSince1970: 1_789_000_000)
    let dayKey = Format.dayKey.string(from: takenAt)
    let dayDir = store.screenshotsDir.appendingPathComponent(dayKey, isDirectory: true)
    try! FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)

    let fullURL = dayDir.appendingPathComponent("shot.jpg")
    let thumbURL = dayDir.appendingPathComponent("shot.thumb.jpg")
    try! Data([0xFF]).write(to: fullURL)
    try! Data([0xFE]).write(to: thumbURL)

    // Sits alongside the day folders, not inside one — proves the sweep only
    // ever touches entries that look like a day folder.
    let dsStore = store.screenshotsDir.appendingPathComponent(".DS_Store")
    try! Data().write(to: dsStore)

    store.insertScreenshot(takenAt: takenAt, day: dayKey, displayID: 0,
                           path: fullURL.path, thumbPath: thumbURL.path, isActive: false)
    _ = store.insertSpan(start: takenAt, end: takenAt.addingTimeInterval(60),
                         bundleId: "x", appName: "X", title: nil, url: nil, kind: .active)

    let summary = await Erase.data(from: nil, to: nil, in: store)

    check("erase-all reports the one screenshot it deleted",
          summary.screenshots == 1, "got \(summary.screenshots)")
    check("erase-all reports the one span it deleted",
          summary.spans == 1, "got \(summary.spans)")
    check("erase-all reports no unlink failures",
          summary.failedFiles == 0, "got \(summary.failedFiles)")

    check("the full-res file was unlinked",
          !FileManager.default.fileExists(atPath: fullURL.path))
    check("the thumbnail file was unlinked",
          !FileManager.default.fileExists(atPath: thumbURL.path))
    check("the emptied day folder was removed",
          !FileManager.default.fileExists(atPath: dayDir.path))
    check("a .DS_Store alongside the day folders is left untouched",
          FileManager.default.fileExists(atPath: dsStore.path))
    check("the screenshot row is gone",
          store.screenshotRows(from: nil, to: nil).isEmpty)
    check("the span row is gone",
          store.spans(from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 2_000_000_000)).isEmpty)

    store.close()
}()

// ============================================================================
// Encryption at rest — Crypto, Rewrap, and Store's encrypted columns.
//
// DataKeychain.swift is compiled by tools/run-tests.sh but never called here:
// every Crypto below is built from a throwaway `SymmetricKey`, and every
// `Store` below is opened with an explicit directory *and* an explicit
// `crypto:`, never the login keychain. A check run must not read — and must
// certainly not create — the key the user's real store is sealed with.
// ============================================================================

func randomKey() -> SymmetricKey { SymmetricKey(size: .bits256) }

/// Write a title/URL straight into `activity_spans` as TEXT, bypassing
/// `Store.insertSpan` (which always seals). This is how a pre-encryption row
/// is recreated for the migration checks below — opening a second connection
/// to the same file is exactly what `Rewrap` itself contends with while it's
/// running.
@discardableResult
func insertPlaintextSpan(dbPath: String, start: Date, end: Date, bundleId: String, appName: String,
                         title: String?, url: String?, kind: SpanKind) -> Int64 {
    let db = Database(path: dbPath)
    db.run("""
    INSERT INTO activity_spans (start, end, app_bundle_id, app_name, window_title, url, kind)
    VALUES (?,?,?,?,?,?,?)
    """, bind: [start.timeIntervalSince1970, end.timeIntervalSince1970,
                bundleId, appName, title, url, kind.rawValue])
    let id = db.lastInsertId
    db.close()
    return id
}

func containsBytes(_ haystack: Data, _ needle: String) -> Bool {
    haystack.range(of: Data(needle.utf8)) != nil
}

// -------------------------------------------------------- seal/open round-trip

do {
    let crypto = Crypto(key: randomKey())

    let large = Data((0..<200_000).map { UInt8($0 % 256) })
    check("a large payload round-trips through seal/open",
          (try? crypto.open(crypto.seal(large))) == large)

    let tiny = Data([0x2A])
    check("a one-byte payload round-trips through seal/open",
          (try? crypto.open(crypto.seal(tiny))) == tiny)

    let empty = Data()
    check("an empty payload round-trips through seal/open",
          (try? crypto.open(crypto.seal(empty))) == empty)
}

// ------------------------------------------------------------ tamper detection

do {
    let crypto = Crypto(key: randomKey())
    let sealed = try! crypto.seal(Data("hello, MacTime".utf8))
    // magic(4) + nonce(12) + ciphertext(14) + tag(16) = 46 bytes.

    func flip(_ data: Data, at offset: Int) -> Data {
        var copy = data
        copy[copy.startIndex + offset] ^= 0xFF
        return copy
    }

    enum Outcome: Equatable { case corrupt, notSealed, other }
    func open(_ crypto: Crypto, _ data: Data) -> Outcome {
        do { _ = try crypto.open(data); return .other }
        catch Crypto.Failure.corrupt { return .corrupt }
        catch Crypto.Failure.notSealed { return .notSealed }
        catch { return .other }
    }

    // The magic is also `isSealed`'s format check, so a flipped magic byte is
    // turned away as "not one of ours" (.notSealed) rather than "ours but
    // tampered" (.corrupt) — see the report back to the assigning agent. It
    // still never opens to garbage, which is the property that actually
    // matters here.
    check("flipping a byte in the magic is rejected rather than opened",
          open(crypto, flip(sealed, at: 0)) != .other,
          "got \(open(crypto, flip(sealed, at: 0)))")

    check("flipping a byte in the nonce is detected as corrupt",
          open(crypto, flip(sealed, at: 4)) == .corrupt)
    check("flipping a byte in the ciphertext body is detected as corrupt",
          open(crypto, flip(sealed, at: 4 + 12 + 1)) == .corrupt)
    check("flipping a byte in the trailing tag is detected as corrupt",
          open(crypto, flip(sealed, at: sealed.count - 1)) == .corrupt)
    check("a truncated sealed value is detected as corrupt, not silently shortened",
          open(crypto, sealed.dropLast(5)) == .corrupt)

    let otherKey = Crypto(key: randomKey())
    check("opening with a different key is detected as corrupt",
          open(otherKey, sealed) == .corrupt)
}

// -------------------------------------------------------------- nonce freshness

do {
    let crypto = Crypto(key: randomKey())
    let plaintext = Data("the same value, twice".utf8)
    let a = try! crypto.seal(plaintext)
    let b = try! crypto.seal(plaintext)
    check("sealing the same plaintext twice yields different bytes (fresh nonce per value)",
          a != b)
    check("both still open back to the original plaintext",
          (try? crypto.open(a)) == plaintext && (try? crypto.open(b)) == plaintext)
}

// -------------------------------------------------------- mixed-format read path

do {
    let crypto = Crypto(key: randomKey())
    let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: 0, count: 40)
    check("openIfSealed passes a plaintext JPEG through untouched",
          (try? crypto.openIfSealed(jpeg)) == jpeg)

    let secret = Data("secret".utf8)
    let sealed = try! crypto.seal(secret)
    check("openIfSealed decrypts a genuinely sealed value",
          (try? crypto.openIfSealed(sealed)) == secret)

    check("isSealed is false for a plaintext JPEG", !Crypto.isSealed(jpeg))
    check("isSealed is false for anything shorter than the 32-byte minimum",
          !Crypto.isSealed(Data(repeating: 0, count: 31)))
    check("isSealed is true for a genuinely sealed value", Crypto.isSealed(sealed))
}

// ----------------------------------------------------- Crypto.resolve, the matrix
//
// The highest-value coverage in this file: every branch of the policy that
// decides whether to mint a key, reuse one, or refuse to write anything —
// checked without a Keychain, which is exactly why `resolve` takes its key
// store as closures.

// 1. no key + no check file → mints a key, writes the check file.
do {
    let dir = makeTempStoreDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let checkFile = dir.appendingPathComponent(Crypto.checkFileName)
    var createCalled = false
    let crypto = Crypto.resolve(dataDir: dir, lookup: { .absent },
                                create: { createCalled = true; return .found(randomKey()) })
    check("no key + no check file: resolve mints a key", crypto.isReady)
    check("no key + no check file: create() is called", createCalled)
    check("no key + no check file: a check file is written",
          FileManager.default.fileExists(atPath: checkFile.path))
}

// 2. key present + matching check file → reuses it, creates nothing.
do {
    let dir = makeTempStoreDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let key = randomKey()
    _ = Crypto.resolve(dataDir: dir, lookup: { .absent }, create: { .found(key) }) // seeds the check file

    var createCalled = false
    let crypto = Crypto.resolve(dataDir: dir, lookup: { .found(key) },
                                create: { createCalled = true; return .found(key) })
    check("key present + matching check file: resolve reuses the key", crypto.isReady)
    check("key present + matching check file: create() is not called", !createCalled)
}

// 3. key present but it doesn't open the check file → unavailable, creates nothing.
do {
    let dir = makeTempStoreDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let keyA = randomKey()
    let keyB = randomKey()
    _ = Crypto.resolve(dataDir: dir, lookup: { .absent }, create: { .found(keyA) }) // check file sealed under keyA

    var createCalled = false
    let crypto = Crypto.resolve(dataDir: dir, lookup: { .found(keyB) },
                                create: { createCalled = true; return .found(keyB) })
    check("key present but wrong for the check file: resolve reports unavailable", !crypto.isReady)
    check("key present but wrong for the check file: create() is not called", !createCalled)
}

// 4. no key + check file present → unavailable, and create() is NOT called.
// The interlock: a key that is merely unreachable must never be papered over
// with a fresh one.
do {
    let dir = makeTempStoreDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    _ = Crypto.resolve(dataDir: dir, lookup: { .absent }, create: { .found(randomKey()) }) // writes the check file

    var createCalled = false
    let crypto = Crypto.resolve(dataDir: dir, lookup: { .absent },
                                create: { createCalled = true; return .found(randomKey()) })
    check("no key + check file present: resolve reports unavailable (the interlock)", !crypto.isReady)
    check("no key + check file present: create() is NOT called", !createCalled)
}

// 5. lookup failed (denied/locked) → unavailable, create() NOT called, reason carried through.
do {
    let dir = makeTempStoreDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    var createCalled = false
    let crypto = Crypto.resolve(dataDir: dir, lookup: { .failed("the keychain is locked") },
                                create: { createCalled = true; return .found(randomKey()) })
    check("lookup failed: resolve reports unavailable", !crypto.isReady)
    check("lookup failed: create() is NOT called", !createCalled)
    check("lookup failed: the reason is carried through unchanged",
          crypto.unavailableReason == "the keychain is locked", "got \(crypto.unavailableReason ?? "nil")")
}

// 6. check file removed → the interlock releases and a new key is minted.
// This is the recovery path `Erase` uses.
do {
    let dir = makeTempStoreDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let checkFile = dir.appendingPathComponent(Crypto.checkFileName)
    _ = Crypto.resolve(dataDir: dir, lookup: { .absent }, create: { .found(randomKey()) })
    try! FileManager.default.removeItem(at: checkFile)

    var createCalled = false
    let crypto = Crypto.resolve(dataDir: dir, lookup: { .absent },
                                create: { createCalled = true; return .found(randomKey()) })
    check("removing the check file releases the interlock", crypto.isReady)
    check("...and a new key is minted", createCalled)
}

// A few more branches worth pinning while the matrix is open.
do {
    let dir = makeTempStoreDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let checkFile = dir.appendingPathComponent(Crypto.checkFileName)
    let key = randomKey()
    let crypto = Crypto.resolve(dataDir: dir, lookup: { .found(key) }, create: { .absent })
    check("a found key with no check file yet is accepted, and a check file is written for it",
          crypto.isReady && FileManager.default.fileExists(atPath: checkFile.path))
}
do {
    let dir = makeTempStoreDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let crypto = Crypto.resolve(dataDir: dir, lookup: { .absent }, create: { .absent })
    check("create() itself coming back absent leaves the store unavailable", !crypto.isReady)
}
do {
    let dir = makeTempStoreDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let crypto = Crypto.resolve(dataDir: dir, lookup: { .absent }, create: { .failed("denied at the prompt") })
    check("create() failing carries its reason through",
          crypto.unavailableReason == "denied at the prompt")
}

// -------------------------------------------------------------- Rewrap.files
//
// pauseEvery: 1000, pauseNanoseconds: 0 throughout so these checks don't sleep.

await { () async -> Void in
    let dir = makeTempStoreDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let crypto = Crypto(key: randomKey())

    let plainBytes = Data([0xFF, 0xD8, 0xFF]) + Data(repeating: 0x11, count: 100)
    let plainURL = dir.appendingPathComponent("plain.jpg")
    try! plainBytes.write(to: plainURL)

    let sealedBytes = try! crypto.seal(Data(repeating: 0x22, count: 100))
    let sealedURL = dir.appendingPathComponent("sealed.jpg")
    try! sealedBytes.write(to: sealedURL)

    let nonJpgBytes = Data("not a screenshot".utf8)
    let nonJpgURL = dir.appendingPathComponent("note.txt")
    try! nonJpgBytes.write(to: nonJpgURL)

    // Comfortably in the future, so nothing here looks "written since launch".
    let cutoff = Date().addingTimeInterval(3600)
    let summary = await Rewrap.files(in: dir, using: crypto, writtenBefore: cutoff,
                                     pauseEvery: 1000, pauseNanoseconds: 0)

    check("Rewrap.files seals exactly the one plaintext capture", summary.sealed == 1, "got \(summary.sealed)")
    check("Rewrap.files reports no failures", summary.failed == 0, "got \(summary.failed)")
    check("the plaintext file is now sealed on disk",
          Crypto.isSealed(try! Data(contentsOf: plainURL)))
    check("the sealed file decrypts back to its original bytes",
          (try? crypto.open(Data(contentsOf: plainURL))) == plainBytes)
    check("an already-sealed file is left byte-identical",
          (try! Data(contentsOf: sealedURL)) == sealedBytes)
    check("a non-.jpg file is left completely untouched",
          (try! Data(contentsOf: nonJpgURL)) == nonJpgBytes)

    let secondPass = await Rewrap.files(in: dir, using: crypto, writtenBefore: cutoff,
                                        pauseEvery: 1000, pauseNanoseconds: 0)
    check("a second pass over an already-sealed directory seals nothing",
          secondPass.sealed == 0 && secondPass.failed == 0,
          "got \(secondPass.sealed) sealed, \(secondPass.failed) failed")
}()

await { () async -> Void in
    // Rewrap carries no progress file on purpose — what decides whether a file
    // still needs doing is the file itself. Simulating "interrupted partway"
    // is therefore nothing more than a directory holding a mix of sealed and
    // still-plaintext files; one pass over it has to finish the job.
    let dir = makeTempStoreDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let crypto = Crypto(key: randomKey())
    let cutoff = Date().addingTimeInterval(3600)

    var urls: [URL] = []
    for i in 0..<6 {
        let url = dir.appendingPathComponent("shot\(i).jpg")
        if i % 2 == 0 {
            try! (Data([0xFF, 0xD8, 0xFF]) + Data(repeating: UInt8(i), count: 20)).write(to: url)
        } else {
            try! crypto.seal(Data(repeating: UInt8(i), count: 20)).write(to: url)
        }
        urls.append(url)
    }

    let summary = await Rewrap.files(in: dir, using: crypto, writtenBefore: cutoff,
                                     pauseEvery: 1000, pauseNanoseconds: 0)
    check("resuming a mid-migration directory seals exactly the plaintext half",
          summary.sealed == 3, "got \(summary.sealed)")

    let allReadable = urls.allSatisfy { url in
        guard let raw = try? Data(contentsOf: url), Crypto.isSealed(raw),
              (try? crypto.open(raw)) != nil else { return false }
        return true
    }
    check("every file — the ones already sealed and the ones just resumed — is readable afterwards",
          allReadable)
}()

await { () async -> Void in
    let dir = makeTempStoreDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let crypto = Crypto(key: randomKey())
    // A cutoff in the past: the file below, written just now, is modified
    // at/after it and must be skipped rather than rewritten mid-arrival.
    let past = Date().addingTimeInterval(-3600)

    let recentBytes = Data([0xFF, 0xD8, 0xFF]) + Data(repeating: 0x33, count: 20)
    let recentURL = dir.appendingPathComponent("recent.jpg")
    try! recentBytes.write(to: recentURL)

    let summary = await Rewrap.files(in: dir, using: crypto, writtenBefore: past,
                                     pauseEvery: 1000, pauseNanoseconds: 0)
    check("a file modified at/after the writtenBefore cutoff is skipped",
          summary.sealed == 0, "got \(summary.sealed)")
    check("...and stays plaintext on disk",
          (try! Data(contentsOf: recentURL)) == recentBytes)
}()

// ------------------------------------------------------- Store.sealPlaintextSpans

await { () async -> Void in
    let dir = makeTempStoreDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let crypto = Crypto(key: randomKey())
    let store = Store(directory: dir, crypto: crypto)
    let dbPath = dir.appendingPathComponent("MacTime.db").path

    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    struct Seed { let id: Int64; let title: String?; let url: String? }
    let pairs: [(String?, String?)] = [
        ("Q3 Layoff List.xlsx", "https://docs.example.com/q3"),
        ("Reset your password", "https://example.com/reset?token=abc123"),
        ("Inbox (14)", nil),   // nil URL must stay nil
        (nil, nil),            // already fully NULL — nothing eligible here
        ("Inbox (14)", nil),   // same title as a row above, different span
        ("Dashboard", "https://example.com/dash"),
    ]
    var seeds: [Seed] = []
    for (i, pair) in pairs.enumerated() {
        let id = insertPlaintextSpan(dbPath: dbPath,
                                     start: t0.addingTimeInterval(Double(i) * 120),
                                     end: t0.addingTimeInterval(Double(i) * 120 + 60),
                                     bundleId: "app.test", appName: "Test App",
                                     title: pair.0, url: pair.1, kind: .active)
        seeds.append(Seed(id: id, title: pair.0, url: pair.1))
    }
    let eligible = pairs.filter { $0.0 != nil || $0.1 != nil }.count

    let firstBatch = store.sealPlaintextSpans(limit: 3)
    check("sealPlaintextSpans respects its limit", firstBatch == 3, "got \(firstBatch)")

    let rest = await Rewrap.spans(in: store, batch: 3, pauseNanoseconds: 0)
    check("Rewrap.spans resumes and finishes sealing every remaining plaintext row",
          firstBatch + rest == eligible, "sealed \(firstBatch + rest) of \(eligible) eligible rows")

    let secondPass = store.sealPlaintextSpans()
    check("a second full pass over an already-sealed table seals zero rows", secondPass == 0)

    let spans = store.spans(from: t0.addingTimeInterval(-1), to: t0.addingTimeInterval(3600))
    let byId = Dictionary(uniqueKeysWithValues: spans.map { ($0.id, $0) })
    var titlesMatch = true, urlsMatch = true, nilsStayNil = true
    for seed in seeds {
        guard let span = byId[seed.id] else { titlesMatch = false; urlsMatch = false; continue }
        if span.title != seed.title { titlesMatch = false }
        if span.url != seed.url { urlsMatch = false }
        if seed.title == nil && span.title != nil { nilsStayNil = false }
        if seed.url == nil && span.url != nil { nilsStayNil = false }
    }
    check("every title reads back identical to what was written before sealing", titlesMatch)
    check("every URL reads back identical to what was written before sealing", urlsMatch)
    check("rows with a nil title/URL stay nil after the migration", nilsStayNil)

    store.close()
}()

do {
    // Without a key, sealPlaintextSpans must return 0 — not seal what it can
    // and drop the rest, and never null out what it couldn't seal.
    let dir = makeTempStoreDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let seedStore = Store(directory: dir, crypto: Crypto(key: randomKey()))
    let dbPath = dir.appendingPathComponent("MacTime.db").path
    let id = insertPlaintextSpan(dbPath: dbPath,
                                 start: Date(timeIntervalSince1970: 1_800_000_000),
                                 end: Date(timeIntervalSince1970: 1_800_000_060),
                                 bundleId: "a", appName: "A",
                                 title: "Still here", url: "https://still-here.example.com", kind: .active)
    seedStore.close()

    let lockedStore = Store(directory: dir, crypto: Crypto(unavailable: "no key for this check"))
    let sealed = lockedStore.sealPlaintextSpans()
    check("sealPlaintextSpans with an unavailable Crypto seals nothing", sealed == 0, "got \(sealed)")
    lockedStore.close()

    var rawTitle: Database.Value = .null
    let raw = Database(path: dbPath)
    raw.run("SELECT window_title FROM activity_spans WHERE id = ?", bind: [id]) { s in
        rawTitle = Database.value(s, 0)
    }
    raw.close()
    if case .text("Still here") = rawTitle {
        check("the plaintext title is left exactly as it was, not nulled out", true)
    } else {
        check("the plaintext title is left exactly as it was, not nulled out", false, "got \(rawTitle)")
    }
}

// ------------------------------------------------------- mixed-format DB reads

do {
    let dir = makeTempStoreDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let crypto = Crypto(key: randomKey())
    let store = Store(directory: dir, crypto: crypto)
    let dbPath = dir.appendingPathComponent("MacTime.db").path

    let sealedId = store.insertSpan(start: Date(timeIntervalSince1970: 1_800_000_000),
                                    end: Date(timeIntervalSince1970: 1_800_000_060),
                                    bundleId: "a", appName: "A",
                                    title: "Sealed Title", url: "https://sealed.example.com", kind: .active)
    let plainId = insertPlaintextSpan(dbPath: dbPath,
                                      start: Date(timeIntervalSince1970: 1_800_000_120),
                                      end: Date(timeIntervalSince1970: 1_800_000_180),
                                      bundleId: "b", appName: "B",
                                      title: "Plain Title", url: "https://plain.example.com", kind: .active)

    let spans = store.spans(from: Date(timeIntervalSince1970: 1_800_000_000),
                            to: Date(timeIntervalSince1970: 1_800_000_200))
    let byId = Dictionary(uniqueKeysWithValues: spans.map { ($0.id, $0) })
    check("a store holding one sealed row reads it back correctly",
          byId[sealedId]?.title == "Sealed Title" && byId[sealedId]?.url == "https://sealed.example.com")
    check("...and one plaintext row alongside it, untouched",
          byId[plainId]?.title == "Plain Title" && byId[plainId]?.url == "https://plain.example.com")
    store.close()
}

// ------------------------------------------------------------------ titleTotals

do {
    let dir = makeTempStoreDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let crypto = Crypto(key: randomKey())
    let store = Store(directory: dir, crypto: crypto)
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // Three spans, same title+URL, 100s each — must group into one 300s row
    // despite three different nonces (Crypto.seal's whole reason titleTotals
    // can't GROUP BY in SQL any more).
    for i in 0..<3 {
        store.insertSpan(start: t0.addingTimeInterval(Double(i) * 200),
                         end: t0.addingTimeInterval(Double(i) * 200 + 100),
                         bundleId: "app.a", appName: "App A",
                         title: "Dashboard", url: "https://example.com/dash", kind: .active)
    }
    // Same title, different URL — must stay its own row.
    store.insertSpan(start: t0.addingTimeInterval(1000), end: t0.addingTimeInterval(1150),
                     bundleId: "app.a", appName: "App A",
                     title: "Dashboard", url: "https://example.com/other", kind: .active)
    // Two equal-duration, differently-titled rows for the tie-break check.
    store.insertSpan(start: t0.addingTimeInterval(3000), end: t0.addingTimeInterval(3010),
                     bundleId: "app.a", appName: "App A", title: "Zeta", url: nil, kind: .active)
    store.insertSpan(start: t0.addingTimeInterval(4000), end: t0.addingTimeInterval(4010),
                     bundleId: "app.a", appName: "App A", title: "Alpha", url: nil, kind: .active)

    let totals = store.titleTotals(from: t0, to: t0.addingTimeInterval(10_000), bundleId: "app.a")

    let dashboard = totals.first { $0.title == "Dashboard" && $0.url == "https://example.com/dash" }
    check("three identically-titled spans group into one row despite three different nonces",
          dashboard.map { abs($0.seconds - 300) < 0.001 } ?? false,
          "got \(String(describing: dashboard))")

    let dashboardOther = totals.first { $0.title == "Dashboard" && $0.url == "https://example.com/other" }
    check("the same title under a different URL stays a separate row",
          dashboardOther.map { abs($0.seconds - 150) < 0.001 } ?? false,
          "got \(String(describing: dashboardOther))")

    check("titleTotals rows come back longest-first",
          totals.map { $0.seconds } == totals.map { $0.seconds }.sorted(by: >),
          "got \(totals.map { $0.seconds })")

    let tie = totals.filter { abs($0.seconds - 10) < 0.001 }
    check("tied durations break by title, alphabetically",
          tie.map { $0.title } == ["Alpha", "Zeta"], "got \(tie.map { $0.title })")

    store.close()
}

// ---------------------------------------------- appTotals / dayStats unaffected
//
// Both deliberately never touch window_title or url — they must keep summing
// the same numbers for a store whose titles happen to be sealed.

do {
    let dir = makeTempStoreDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let crypto = Crypto(key: randomKey())
    let store = Store(directory: dir, crypto: crypto)
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    store.insertSpan(start: t0, end: t0.addingTimeInterval(600),
                     bundleId: "com.example.app", appName: "Example",
                     title: "Something Secret", url: "https://secret.example.com/x", kind: .active)
    store.insertSpan(start: t0.addingTimeInterval(600), end: t0.addingTimeInterval(900),
                     bundleId: "com.example.app", appName: "Example",
                     title: nil, url: nil, kind: .idle)

    let apps = store.appTotals(from: t0, to: t0.addingTimeInterval(900))
    check("appTotals still sums the active seconds for an app with sealed titles",
          apps.first?.seconds == 600, "got \(apps.first?.seconds ?? -1)")

    let days = store.dayStats(from: t0, to: t0.addingTimeInterval(900))
    check("dayStats still sums active and idle seconds for a store with sealed titles",
          days.first?.activeSeconds == 600 && days.first?.idleSeconds == 300,
          "got \(String(describing: days.first))")

    store.close()
}

// --------------------------------------------------------------- key unavailable

do {
    let dir = makeTempStoreDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = Store(directory: dir, crypto: Crypto(unavailable: "no key for this check"))

    let id = store.insertSpan(start: Date(timeIntervalSince1970: 1_800_000_000),
                              end: Date(timeIntervalSince1970: 1_800_000_060),
                              bundleId: "com.example.app", appName: "Example",
                              title: "Should not be written", url: "https://should-not-be-written.example.com",
                              kind: .active)

    let spans = store.spans(from: Date(timeIntervalSince1970: 1_800_000_000),
                            to: Date(timeIntervalSince1970: 1_800_000_100))
    let span = spans.first { $0.id == id }
    check("insertSpan still records the app, times and kind without a key",
          span?.bundleId == "com.example.app" && span?.duration == 60 && span?.kind == .active)
    check("insertSpan drops the title without a key", span?.title == nil, "got \(span?.title ?? "nil")")
    check("insertSpan drops the URL without a key", span?.url == nil, "got \(span?.url ?? "nil")")

    store.close()
}

do {
    // A blob that passes isSealed (right magic, long enough) but won't
    // authenticate — a row sealed under a key this store no longer has, or
    // bit rot. Must read back as Store.locked, never as nil: nil means
    // "nothing was recorded here", and this is history still sitting on disk.
    let dir = makeTempStoreDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = Store(directory: dir, crypto: Crypto(key: randomKey()))
    let dbPath = dir.appendingPathComponent("MacTime.db").path

    let garbage = Crypto.magic + Data(repeating: 0xAB, count: 12 + 20 + 16)
    let raw = Database(path: dbPath)
    raw.run("""
    INSERT INTO activity_spans (start, end, app_bundle_id, app_name, window_title, url, kind)
    VALUES (?,?,?,?,?,?,?)
    """, bind: [1_800_000_000.0, 1_800_000_060.0, "c", "C", garbage, nil, "active"])
    raw.close()

    let spans = store.spans(from: Date(timeIntervalSince1970: 1_800_000_000),
                            to: Date(timeIntervalSince1970: 1_800_000_100))
    check("a blob that won't decrypt reads back as Store.locked, not nil",
          spans.first?.title == Store.locked, "got \(String(describing: spans.first?.title))")

    store.close()
}

// -------------------------------------------------------------- Erase interaction

await { () async -> Void in
    let dir = makeTempStoreDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let crypto = Crypto(key: randomKey())
    let store = Store(directory: dir, crypto: crypto)
    let checkFile = dir.appendingPathComponent(Crypto.checkFileName)
    try! Data("stand-in check file contents".utf8).write(to: checkFile)

    let takenAt = Date(timeIntervalSince1970: 1_800_000_000)
    let dayKey = Format.dayKey.string(from: takenAt)
    let dayDir = store.screenshotsDir.appendingPathComponent(dayKey, isDirectory: true)
    try! FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
    let shotURL = dayDir.appendingPathComponent("shot.jpg")
    try! crypto.seal(Data(repeating: 0x99, count: 500)).write(to: shotURL)

    store.insertScreenshot(takenAt: takenAt, day: dayKey, displayID: 0,
                           path: shotURL.path, thumbPath: "", isActive: false)
    store.insertSpan(start: takenAt, end: takenAt.addingTimeInterval(60),
                     bundleId: "x", appName: "X", title: "Sealed span", url: nil, kind: .active)

    let summary = await Erase.data(from: nil, to: nil, in: store)
    check("erase-all with a sealed capture on disk still deletes its screenshot row",
          summary.screenshots == 1, "got \(summary.screenshots)")
    check("erase-all with a sealed capture on disk still deletes its span row",
          summary.spans == 1, "got \(summary.spans)")
    check("erase-all with a sealed capture on disk unlinks it with no failures",
          summary.failedFiles == 0, "got \(summary.failedFiles)")
    check("an unbounded erase removes the key-check file — the recovery path",
          !FileManager.default.fileExists(atPath: checkFile.path))

    store.close()
}()

await { () async -> Void in
    let dir = makeTempStoreDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = Store(directory: dir, crypto: Crypto(key: randomKey()))
    let checkFile = dir.appendingPathComponent(Crypto.checkFileName)
    try! Data("stand-in check file contents".utf8).write(to: checkFile)

    let takenAt = Date(timeIntervalSince1970: 1_800_000_000)
    store.insertScreenshot(takenAt: takenAt, day: Format.dayKey.string(from: takenAt),
                           displayID: 0, path: "", thumbPath: "", isActive: false)

    _ = await Erase.data(from: takenAt, to: takenAt.addingTimeInterval(3600), in: store)
    check("a ranged erase leaves the key-check file alone",
          FileManager.default.fileExists(atPath: checkFile.path))

    store.close()
}()

// The finding demonstrated rather than asserted: a written title is provably
// absent from the database file bytes, while the (deliberately unencrypted)
// app_bundle_id is right there in the clear.
await { () async -> Void in
    let dir = makeTempStoreDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = Store(directory: dir, crypto: Crypto(key: randomKey()))

    store.insertSpan(start: Date(timeIntervalSince1970: 1_800_000_000),
                     end: Date(timeIntervalSince1970: 1_800_000_060),
                     bundleId: "com.example.findme", appName: "Findme",
                     title: "A Very Findable Secret Title", url: nil, kind: .active)
    store.close() // flush the WAL so the finding is checkable in the main file

    let dbPath = dir.appendingPathComponent("MacTime.db").path
    let dbBytes = try! Data(contentsOf: URL(fileURLWithPath: dbPath))
    let walBytes = (try? Data(contentsOf: URL(fileURLWithPath: dbPath + "-wal"))) ?? Data()

    check("a written title does not appear anywhere in the database file bytes",
          !containsBytes(dbBytes, "A Very Findable Secret Title")
            && !containsBytes(walBytes, "A Very Findable Secret Title"))
    check("but the (deliberately unencrypted) app_bundle_id does",
          containsBytes(dbBytes, "com.example.findme") || containsBytes(walBytes, "com.example.findme"))
}()

// ------------------------------------------------ Store.sweepExports, the viewer's
// decrypted copies for "Open in Preview". Both members are plain statics with
// an injectable directory, so they test synchronously with no store involved.
// Never called with its default argument here — that is the real, shared
// directory, and clearing it out from under whatever else is running on this
// machine is exactly what these checks must not do.

do {
    let parent = makeTempStoreDir()
    defer { try? FileManager.default.removeItem(at: parent) }
    let dir = parent.appendingPathComponent("decrypted-copies", isDirectory: true)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try! Data([0xFF, 0xD8, 0xFF]).write(to: dir.appendingPathComponent("shot.jpg"))

    Store.sweepExports(dir)
    check("sweepExports removes a directory holding decrypted copies",
          !FileManager.default.fileExists(atPath: dir.path))
}

do {
    let parent = makeTempStoreDir()
    defer { try? FileManager.default.removeItem(at: parent) }
    let neverCreated = parent.appendingPathComponent("never-created", isDirectory: true)

    // Most launches have nothing to clear — this must not throw or touch
    // anything outside the directory it was given.
    Store.sweepExports(neverCreated)
    check("sweepExports on a directory that never existed is harmless",
          !FileManager.default.fileExists(atPath: neverCreated.path))
    check("...and leaves its parent directory alone",
          FileManager.default.fileExists(atPath: parent.path))
}

// Pinned precisely because the function is an unconditional recursive
// delete: a future edit that pointed it one level up would wipe the user's
// whole temp directory rather than just MacTime's corner of it.
check("Store.exportDir is a MacTime-specific subdirectory of the temp root, never the root itself",
      Store.exportDir.lastPathComponent == "MacTime"
        && Store.exportDir.deletingLastPathComponent().standardizedFileURL
             == URL(fileURLWithPath: NSTemporaryDirectory()).standardizedFileURL,
      "got \(Store.exportDir.path)")

// ============================================================================
// URLPolicy.origin — "keep only a URL's origin unless asked otherwise". A
// mistake here is a token going to disk, not a missing row, so the awkward
// cases get checked by name and then swept for the invariants that actually
// matter.
// ============================================================================

do {
    struct OriginCase { let label: String; let input: String; let expected: String? }
    let cases: [OriginCase] = [
        .init(label: "query string and fragment are dropped, leaving just the origin",
              input: "https://mail.google.com/mail/u/0/#inbox?ik=SECRET",
              expected: "https://mail.google.com"),
        .init(label: "a URL-encoded '@' in the userinfo doesn't confuse the userinfo/host split",
              input: "https://user:p%40ss@host.example/path?x=1",
              expected: "https://host.example"),
        // The userinfo/host split must happen on the *last* "@" — a password
        // is allowed to contain one, and splitting on the first would read
        // "ss@host.example" as the host.
        .init(label: "userinfo containing a literal '@' splits on the last '@', not the first",
              input: "https://user:pa@ss@host.example/path",
              expected: "https://host.example"),
        .init(label: "localhost with a non-default port keeps the port — it names which dev server",
              input: "http://localhost:3000/admin?key=zz",
              expected: "http://localhost:3000"),
        .init(label: "default https port (443) is dropped",
              input: "https://example.com:443/x", expected: "https://example.com"),
        .init(label: "default http port (80) is dropped",
              input: "http://example.com:80/x", expected: "http://example.com"),
        .init(label: "a non-default port is kept",
              input: "https://example.com:8443/x", expected: "https://example.com:8443"),
        .init(label: "an IPv4 literal host is treated like any other host",
              input: "https://192.168.1.5:8080/admin?t=1", expected: "https://192.168.1.5:8080"),
        // validHost strips an IPv6 literal's brackets before checking it for
        // forbidden characters (Foundation is inconsistent about whether
        // `URLComponents.host` keeps them), and assemble() puts them back —
        // these two pin that round-trip surviving the added rejection.
        .init(label: "an IPv6 literal keeps its brackets, with a port after them",
              input: "https://[::1]:3000/x", expected: "https://[::1]:3000"),
        .init(label: "an IPv6 literal with no port still keeps its brackets",
              input: "https://[2001:db8::1]/x", expected: "https://[2001:db8::1]"),
        .init(label: "a space in the host is rejected — a host with a space isn't a host",
              input: "https://foo bar.com/x", expected: nil),
        .init(label: "a tab in the host is rejected",
              input: "https://foo\tbar.com/x", expected: nil),
        .init(label: "a control character in the host is rejected",
              input: "https://exa\u{0007}mple.com/x", expected: nil),
        .init(label: "a hostless file: URL keeps only its scheme — the path is the private part",
              input: "file:///Users/jack/Documents/Q3%20layoffs.pdf", expected: "file:"),
        .init(label: "about:blank keeps only its scheme",
              input: "about:blank", expected: "about:"),
        .init(label: "a hostless URL with a fragment still keeps only its scheme",
              input: "about:preferences#privacy", expected: "about:"),
        .init(label: "a data: URL keeps only its scheme — the payload is entirely private",
              input: "data:text/html;base64,PHNjcmlwdD4=", expected: "data:"),
        .init(label: "mailto: keeps only its scheme",
              input: "mailto:someone@example.com", expected: "mailto:"),
        .init(label: "scheme and host are lowercased",
              input: "HTTPS://Mail.Google.COM/X?t=1", expected: "https://mail.google.com"),
        .init(label: "a punycode IDN host comes back in its Unicode form",
              input: "https://xn--mnchen-3ya.de/seite?q=geheim", expected: "https://münchen.de"),
        .init(label: "a Unicode IDN host round-trips to the same origin as its punycode spelling",
              input: "https://münchen.de/seite?q=geheim", expected: "https://münchen.de"),
        .init(label: "a non-http(s) app scheme with a host keeps host and drops the path",
              input: "chrome://settings/passwords", expected: "chrome://settings"),
        .init(label: "ftp's own default port (21) is dropped like http/https",
              input: "ftp://user:pw@files.example.com:21/dir", expected: "ftp://files.example.com"),
        .init(label: "a string with no scheme at all returns nil",
              input: "not a url at all", expected: nil),
        .init(label: "an empty string returns nil", input: "", expected: nil),
        .init(label: "whitespace-only input returns nil", input: "   ", expected: nil),
        .init(label: "an unparseable port returns nil rather than a guess",
              input: "https://example.com:notaport/x", expected: nil),
    ]

    for c in cases {
        let got = URLPolicy.origin(of: c.input)
        check(c.label, got == c.expected, "got \(got.debugDescription)")
    }

    check("leading and trailing whitespace is trimmed before parsing",
          URLPolicy.origin(of: "  https://example.com/path?x=1  ") == "https://example.com")

    // ---- properties, swept across the whole table above plus a few nastier
    // inputs of our own — this is the invariant the feature exists for, not
    // just the specific cases picked to exercise it.
    let extra = [
        "https://a:s#ecret@example.com/x?access_token=deadbeef",
        "https://example.com/reset?SECRET=1#frag",
        "https://user:pass@example.com:9999/x?token=zzz",
    ]
    let allInputs = cases.map(\.input) + extra

    check("no userinfo survives in any result — the most embarrassing possible failure here",
          allInputs.allSatisfy { input in
              guard let origin = URLPolicy.origin(of: input) else { return true }
              return !origin.contains("@")
          })

    check("no query string, fragment, or token-shaped substring survives in any result",
          allInputs.allSatisfy { input in
              guard let origin = URLPolicy.origin(of: input) else { return true }
              return !origin.contains("?") && !origin.contains("#")
                  && !origin.contains("token") && !origin.contains("SECRET")
                  && !origin.contains("access_token")
          })

    check("origin is idempotent — re-applying it to its own output changes nothing",
          allInputs.allSatisfy { input in
              guard let once = URLPolicy.origin(of: input) else { return true }
              return URLPolicy.origin(of: once) == once
          })
}

// ============================================================================
// CapturePolicy.detail — the exclusion path. What decides whether an app's
// window title and browser URL are recorded at all.
// ============================================================================

do {
    var readCount = 0
    func countingRead(title: String?, url: String?) -> () -> (title: String?, url: String?) {
        { readCount += 1; return (title, url) }
    }

    readCount = 0
    let excluded = CapturePolicy.detail(
        for: "com.excluded.app", excludedBundleIDs: ["com.excluded.app"], fullURLs: false,
        read: countingRead(title: "Secret Title", url: "https://secret.example.com/x?y=1"))
    check("an excluded app's window title comes back nil", excluded.title == nil)
    check("an excluded app's URL comes back nil", excluded.url == nil)
    // The real property: an excluded app's title is never *read*, not read
    // and then thrown away. Checking only the return value would also pass
    // for an implementation that reads it and discards the result.
    check("an excluded app's read() is never called at all",
          readCount == 0, "got \(readCount)")

    readCount = 0
    let kept = CapturePolicy.detail(
        for: "com.ok.app", excludedBundleIDs: ["com.excluded.app"], fullURLs: false,
        read: countingRead(title: "My Title", url: "https://example.com/path?q=1"))
    check("a non-excluded app's title passes through untouched", kept.title == "My Title")
    check("a non-excluded app's URL is stripped to its origin", kept.url == "https://example.com")
    check("a non-excluded app's read() is called exactly once", readCount == 1, "got \(readCount)")

    let full = CapturePolicy.detail(
        for: "com.ok.app", excludedBundleIDs: [], fullURLs: true,
        read: countingRead(title: "My Title", url: "https://example.com/path?q=1"))
    check("fullURLs: true passes the URL through verbatim, query string included",
          full.url == "https://example.com/path?q=1")

    let nilURLStripped = CapturePolicy.detail(
        for: "com.ok.app", excludedBundleIDs: [], fullURLs: false,
        read: countingRead(title: "T", url: nil))
    check("a nil URL from read() stays nil in origin-only mode", nilURLStripped.url == nil)
    check("...and the title still passes through", nilURLStripped.title == "T")

    let nilURLFull = CapturePolicy.detail(
        for: "com.ok.app", excludedBundleIDs: [], fullURLs: true,
        read: countingRead(title: "T", url: nil))
    check("a nil URL from read() stays nil in fullURLs mode too", nilURLFull.url == nil)

    let emptyExclusions = CapturePolicy.detail(
        for: "com.anything", excludedBundleIDs: [], fullURLs: false,
        read: countingRead(title: "X", url: nil))
    check("an empty excludedBundleIDs set excludes nothing", emptyExclusions.title == "X")

    let notPrefixExcluded = CapturePolicy.detail(
        for: "com.foo.barbaz", excludedBundleIDs: ["com.foo.bar"], fullURLs: false,
        read: countingRead(title: "T", url: nil))
    check("excluding com.foo.bar does not exclude com.foo.barbaz — no prefix matching",
          notPrefixExcluded.title == "T")

    let notSubstringExcluded = CapturePolicy.detail(
        for: "com.foo.bar", excludedBundleIDs: ["com.foo.barbaz"], fullURLs: false,
        read: countingRead(title: "T", url: nil))
    check("excluding com.foo.barbaz does not exclude com.foo.bar — matching is exact, not substring",
          notSubstringExcluded.title == "T")
}

// ------------------------------------------- CapturePolicy end-to-end, via Store
//
// The point of exclusion: an excluded app still adds up in the day's totals,
// it just stops saying what was on screen. Proven against a real Store, the
// way ActivityService.makeSample actually inserts a span.
do {
    let dir = makeTempStoreDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let crypto = Crypto(key: randomKey())
    let store = Store(directory: dir, crypto: crypto)

    let detail = CapturePolicy.detail(
        for: "com.excluded.app", excludedBundleIDs: ["com.excluded.app"], fullURLs: false) {
        ("Password Manager — Vault Unlocked", "https://vault.example.com/unlock?token=abc")
    }

    let id = store.insertSpan(start: Date(timeIntervalSince1970: 1_800_000_000),
                              end: Date(timeIntervalSince1970: 1_800_000_060),
                              bundleId: "com.excluded.app", appName: "Password Manager",
                              title: detail.title, url: detail.url, kind: .active)
    store.close()

    // Reopening needs the same Crypto passed back — a fresh throwaway key
    // can't read what the last one wrote.
    let reopened = Store(directory: dir, crypto: crypto)
    let span = reopened.spans(from: Date(timeIntervalSince1970: 1_800_000_000),
                              to: Date(timeIntervalSince1970: 1_800_000_100))
        .first { $0.id == id }

    check("an excluded app's name survives — the day still has to add up",
          span?.appName == "Password Manager", "got \(String(describing: span?.appName))")
    check("...while its title comes back nil, sealing round-trip included",
          span?.title == nil, "got \(span?.title ?? "nil")")
    check("...and its URL comes back nil too",
          span?.url == nil, "got \(span?.url ?? "nil")")

    reopened.close()
}

// ------------------------------------------------------------------- report

if failures.isEmpty {
    print("ok — \(checks) checks passed")
} else {
    for f in failures { FileHandle.standardError.write(Data("FAIL: \(f)\n".utf8)) }
    FileHandle.standardError.write(Data("\(failures.count) of \(checks) checks failed\n".utf8))
    exit(1)
}
