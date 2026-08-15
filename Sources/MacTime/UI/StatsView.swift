import SwiftUI
import Charts

/// ManicTime statistics structure: From/To range with presets on top, then
/// chart sub-tabs — Day duration, Top Applications, Top Computer Usage,
/// Attendance.
struct StatsView: View {
    let store: Store

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

    enum SubTab: String, CaseIterable {
        case dayDuration = "Day duration"
        case topApps = "Top Applications"
        case computerUsage = "Top Computer Usage"
        case attendance = "Attendance"
    }

    @State private var preset: Preset = .thisWeek
    @State private var fromDate = Calendar.current.startOfDay(for: Date())
    @State private var toDate = Date()
    @State private var subTab: SubTab = .dayDuration

    @State private var dayStats: [DayStat] = []
    @State private var totals: [AppTotal] = []
    @State private var selectedBundleId: String?
    @State private var titles: [TitleTotal] = []

    var body: some View {
        VStack(spacing: 0) {
            rangeHeader
            Divider()
            Picker("", selection: $subTab) {
                ForEach(SubTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .onChange(of: subTab) { reload() }
            Divider()

            if dayStats.isEmpty {
                Text("No activity in this range")
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                switch subTab {
                case .dayDuration: DayDurationView(stats: dayStats)
                case .topApps: topAppsView
                case .computerUsage: ComputerUsageView(stats: dayStats)
                case .attendance: AttendanceView(from: fromDate, to: toDate, stats: dayStats)
                }
            }
        }
        .onAppear { apply(preset: preset) }
    }

    // ------------------------------------------------------------- range header

    private var rangeHeader: some View {
        HStack(spacing: 10) {
            Text("From")
                .foregroundStyle(.secondary)
            DatePicker("", selection: $fromDate, displayedComponents: .date)
                .labelsHidden()
                .onChange(of: fromDate) { userEditedDates() }
            Text("To")
                .foregroundStyle(.secondary)
            DatePicker("", selection: $toDate, displayedComponents: .date)
                .labelsHidden()
                .onChange(of: toDate) { userEditedDates() }

            Button { shift(-1) } label: { Image(systemName: "chevron.left") }
            Button { shift(1) } label: { Image(systemName: "chevron.right") }

            Picker("", selection: $preset) {
                ForEach(Preset.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .frame(width: 170)
            .onChange(of: preset) { apply(preset: preset) }

            Spacer()
            let active = dayStats.reduce(0) { $0 + $1.activeSeconds }
            Text("Active \(Format.duration(active))")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// End of range is exclusive internally; the To picker shows the last
    /// included day, so add a day when querying.
    private var queryRange: (Date, Date) {
        let cal = Calendar.current
        let from = cal.startOfDay(for: fromDate)
        let to = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: toDate)) ?? toDate
        return (from, to)
    }

    private func apply(preset p: Preset) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        switch p {
        case .today:
            fromDate = today; toDate = today
        case .yesterday:
            let y = cal.date(byAdding: .day, value: -1, to: today)!
            fromDate = y; toDate = y
        case .thisWeek:
            let interval = cal.dateInterval(of: .weekOfYear, for: today)!
            fromDate = interval.start
            toDate = min(today, interval.end.addingTimeInterval(-1))
        case .previousWeek:
            let thisWeek = cal.dateInterval(of: .weekOfYear, for: today)!
            fromDate = cal.date(byAdding: .weekOfYear, value: -1, to: thisWeek.start)!
            toDate = thisWeek.start.addingTimeInterval(-1)
        case .thisMonth:
            let interval = cal.dateInterval(of: .month, for: today)!
            fromDate = interval.start
            toDate = min(today, interval.end.addingTimeInterval(-1))
        case .previousMonth:
            let thisMonth = cal.dateInterval(of: .month, for: today)!
            fromDate = cal.date(byAdding: .month, value: -1, to: thisMonth.start)!
            toDate = thisMonth.start.addingTimeInterval(-1)
        case .yearToDate:
            fromDate = cal.dateInterval(of: .year, for: today)!.start
            toDate = today
        case .allTime:
            fromDate = store.firstSpanStart() ?? today
            toDate = today
        case .custom:
            break
        }
        reload()
    }

    private func userEditedDates() {
        if preset != .custom { preset = .custom }
        reload()
    }

    private func shift(_ direction: Int) {
        let cal = Calendar.current
        switch preset {
        case .today, .yesterday:
            fromDate = cal.date(byAdding: .day, value: direction, to: fromDate)!
            toDate = fromDate
            preset = .custom
        case .thisWeek, .previousWeek:
            fromDate = cal.date(byAdding: .weekOfYear, value: direction, to: fromDate)!
            toDate = cal.date(byAdding: .day, value: 6, to: fromDate)!
            preset = .custom
        case .thisMonth, .previousMonth:
            fromDate = cal.date(byAdding: .month, value: direction, to: fromDate)!
            let interval = cal.dateInterval(of: .month, for: fromDate)!
            toDate = interval.end.addingTimeInterval(-1)
            preset = .custom
        default:
            let days = max(1, cal.dateComponents([.day], from: fromDate, to: toDate).day ?? 1)
            fromDate = cal.date(byAdding: .day, value: direction * days, to: fromDate)!
            toDate = cal.date(byAdding: .day, value: direction * days, to: toDate)!
            preset = .custom
        }
        reload()
    }

    private func reload() {
        let (from, to) = queryRange
        dayStats = store.dayStats(from: from, to: to)
        totals = store.appTotals(from: from, to: to)
        if let selected = selectedBundleId, totals.contains(where: { $0.bundleId == selected }) {
            titles = store.titleTotals(from: from, to: to, bundleId: selected)
        } else {
            selectedBundleId = totals.first?.bundleId
            titles = selectedBundleId.map { store.titleTotals(from: from, to: to, bundleId: $0) } ?? []
        }
    }

    // ------------------------------------------------------------- top apps

    private var topAppsView: some View {
        VSplitView {
            let top = Array(totals.prefix(12))
            Chart(top) { total in
                BarMark(
                    x: .value("Time", total.seconds / 3600),
                    y: .value("App", total.appName)
                )
                .foregroundStyle(Color(nsColor: AppColor.nsColor(for: total.bundleId)))
                .annotation(position: .trailing) {
                    Text(Format.duration(total.seconds))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .chartYScale(domain: top.map(\.appName))
            .chartXAxisLabel("hours")
            .padding(12)
            .frame(minHeight: 220)

            HSplitView {
                List(totals, selection: $selectedBundleId) { total in
                    HStack {
                        Circle()
                            .fill(Color(nsColor: AppColor.nsColor(for: total.bundleId)))
                            .frame(width: 8, height: 8)
                        Text(total.appName).lineLimit(1)
                        Spacer()
                        Text(Format.duration(total.seconds))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .tag(total.bundleId)
                }
                .frame(minWidth: 240, idealWidth: 300, maxWidth: 400)
                .onChange(of: selectedBundleId) {
                    let (from, to) = queryRange
                    titles = selectedBundleId.map { store.titleTotals(from: from, to: to, bundleId: $0) } ?? []
                }

                Table(titles) {
                    TableColumn("Title / URL") { row in
                        let text = (row.url?.isEmpty == false ? row.url! : row.title.isEmpty ? "—" : row.title)
                        Text(text).help(text)
                    }
                    TableColumn("Duration") { row in
                        Text(Format.duration(row.seconds)).monospacedDigit()
                    }
                    .width(90)
                }
            }
            .frame(minHeight: 180)
        }
    }
}

// ================================================================ day duration

/// One column per day, spanning first→last activity on a midnight-to-midnight
/// axis (midnight at the top, like ManicTime's chart), with a Chart/Table toggle.
struct DayDurationView: View {
    let stats: [DayStat]
    @State private var mode = "Chart"

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $mode) {
                    Text("Chart").tag("Chart")
                    Text("Table").tag("Table")
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if mode == "Chart" {
                chart.padding(12)
            } else {
                table
            }
        }
    }

    private var rows: [DayStat] { stats.filter { $0.firstActive != nil && $0.lastActive != nil } }

    private var chart: some View {
        // Time of day increases downward (ManicTime style): plot 24 - hour.
        Chart(rows) { stat in
            BarMark(
                x: .value("Day", shortDay(stat.dayKey)),
                yStart: .value("Start", 24 - hourOfDay(stat.firstActive!, dayKey: stat.dayKey)),
                yEnd: .value("End", 24 - hourOfDay(stat.lastActive!, dayKey: stat.dayKey)),
                width: .ratio(0.7)
            )
            .foregroundStyle(.green.opacity(0.75))
            .annotation(position: .top) {
                Text(Format.duration(stat.activeSeconds))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .chartYScale(domain: 0...24)
        .chartYAxis {
            AxisMarks(values: [0, 3, 6, 9, 12, 15, 18, 21, 24]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(hourLabel(24 - v))
                    }
                }
            }
        }
    }

    private var table: some View {
        Table(rows) {
            TableColumn("Date") { Text(longDay($0.dayKey)) }
            TableColumn("Day start") { stat in
                Text(stat.firstActive.map { Format.time.string(from: $0) } ?? "—").monospacedDigit()
            }
            TableColumn("Day end") { stat in
                Text(stat.lastActive.map { Format.time.string(from: $0) } ?? "—").monospacedDigit()
            }
            TableColumn("Duration") { stat in
                let span = zip(stat.firstActive, stat.lastActive).map { $1.timeIntervalSince($0) }
                Text(span.map(Format.duration) ?? "—").monospacedDigit()
            }
            TableColumn("Active") { Text(Format.duration($0.activeSeconds)).monospacedDigit() }
            TableColumn("Away") { Text(Format.duration($0.idleSeconds)).monospacedDigit() }
        }
    }
}

// ================================================================ computer usage

/// Stacked column per day: active / away / sleep hours, plus range totals.
struct ComputerUsageView: View {
    let stats: [DayStat]

    private struct Slice: Identifiable {
        var id: String { day + kind }
        let day: String
        let kind: String
        let hours: Double
    }

    private var slices: [Slice] {
        stats.flatMap { stat in
            [Slice(day: shortDay(stat.dayKey), kind: "Active", hours: stat.activeSeconds / 3600),
             Slice(day: shortDay(stat.dayKey), kind: "Away", hours: stat.idleSeconds / 3600),
             Slice(day: shortDay(stat.dayKey), kind: "Sleep", hours: stat.sleepSeconds / 3600)]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 18) {
                total("Active", stats.reduce(0) { $0 + $1.activeSeconds }, .green)
                total("Away", stats.reduce(0) { $0 + $1.idleSeconds }, .gray)
                total("Sleep", stats.reduce(0) { $0 + $1.sleepSeconds }, .indigo)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)

            Chart(slices) { slice in
                BarMark(
                    x: .value("Day", slice.day),
                    y: .value("Hours", slice.hours),
                    width: .ratio(0.7)
                )
                .foregroundStyle(by: .value("Kind", slice.kind))
            }
            .chartForegroundStyleScale([
                "Active": Color.green.opacity(0.8),
                "Away": Color.gray.opacity(0.5),
                "Sleep": Color.indigo.opacity(0.5),
            ])
            .chartYAxisLabel("hours")
            .padding(12)
        }
    }

    private func total(_ label: String, _ seconds: TimeInterval, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
            Text(Format.duration(seconds)).monospacedDigit().foregroundStyle(.secondary)
        }
        .font(.callout)
    }
}

// ================================================================ attendance

/// ManicTime-style attendance: a calendar heatmap — one row per month, columns
/// aligned to weekdays (weeks start Sunday). Green = active time reached the
/// minimum, red = a tracked day that fell short, gray = untracked/future.
struct AttendanceView: View {
    let from: Date
    let to: Date
    let stats: [DayStat]

    @State private var minHours: Double = 1

    private enum CellState { case attended, absent, untracked }

    private struct Cell: Identifiable {
        let id: Int      // slot index within the month row
        let dayNumber: Int?
        let state: CellState
    }

    private struct MonthRow: Identifiable {
        let id: String
        let label: String
        let attended: Int
        let absent: Int
        let cells: [Cell]
    }

    private static let slots = 42   // 6 weeks × 7 weekday columns
    private let cellSize = CGSize(width: 30, height: 24)

    var body: some View {
        let rows = buildRows()
        let attendedTotal = rows.reduce(0) { $0 + $1.attended }
        let absentTotal = rows.reduce(0) { $0 + $1.absent }

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Text("Min. active time (hours)")
                    .foregroundStyle(.secondary)
                Picker("", selection: $minHours) {
                    ForEach([0.5, 1.0, 2.0, 3.0, 4.0, 6.0], id: \.self) {
                        Text($0 == 0.5 ? "0.5" : "\(Int($0))").tag($0)
                    }
                }
                .frame(width: 70)
                Spacer()
                legendDot(.green, "Attended \(attendedTotal)")
                legendDot(.red, "Absent \(absentTotal)")
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 6) {
                    weekdayHeader
                    ForEach(rows) { row in
                        HStack(spacing: 3) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(row.label).font(.callout.weight(.semibold))
                                HStack(spacing: 6) {
                                    Text("\(row.attended)").foregroundStyle(.green)
                                    Text("\(row.absent)").foregroundStyle(.red)
                                }
                                .font(.caption.monospacedDigit())
                            }
                            .frame(width: 52, alignment: .leading)
                            ForEach(row.cells) { cell in cellView(cell) }
                        }
                    }
                }
                .padding(12)
            }
        }
    }

    private func legendDot(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(text).font(.callout.monospacedDigit())
        }
    }

    private var weekdayHeader: some View {
        HStack(spacing: 3) {
            Spacer().frame(width: 52)
            ForEach(0..<Self.slots, id: \.self) { i in
                Text(["S", "M", "T", "W", "T", "F", "S"][i % 7])
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: cellSize.width, height: 14)
            }
        }
    }

    @ViewBuilder
    private func cellView(_ cell: Cell) -> some View {
        Group {
            if let n = cell.dayNumber {
                Text("\(n)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(cell.state == .untracked ? Color.secondary : .white)
                    .frame(width: cellSize.width, height: cellSize.height)
                    .background(background(for: cell.state), in: RoundedRectangle(cornerRadius: 3))
            } else {
                Color.clear.frame(width: cellSize.width, height: cellSize.height)
            }
        }
    }

    private func background(for state: CellState) -> Color {
        switch state {
        case .attended: return .green.opacity(0.75)
        case .absent: return .red.opacity(0.85)
        case .untracked: return .primary.opacity(0.06)
        }
    }

    private func buildRows() -> [MonthRow] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let fromDay = cal.startOfDay(for: from)
        let toDay = cal.startOfDay(for: to)
        let activeByDay = Dictionary(uniqueKeysWithValues: stats.map { ($0.dayKey, $0.activeSeconds) })

        let monthFormatter = DateFormatter()
        monthFormatter.dateFormat = "MMM"

        var rows: [MonthRow] = []
        var cursor = cal.dateInterval(of: .month, for: fromDay)!.start
        while cursor <= toDay {
            let interval = cal.dateInterval(of: .month, for: cursor)!
            let daysInMonth = cal.range(of: .day, in: .month, for: cursor)!.count
            let firstWeekday = cal.component(.weekday, from: interval.start) - 1 // Sunday = 0

            var cells: [Cell] = []
            var attended = 0, absent = 0
            for slot in 0..<Self.slots {
                let dayNumber = slot - firstWeekday + 1
                guard dayNumber >= 1, dayNumber <= daysInMonth else {
                    cells.append(Cell(id: slot, dayNumber: nil, state: .untracked))
                    continue
                }
                let date = cal.date(byAdding: .day, value: dayNumber - 1, to: interval.start)!
                let state: CellState
                if date > today || date > toDay || date < fromDay {
                    state = .untracked
                } else {
                    let active = activeByDay[Format.dayKey.string(from: date)] ?? 0
                    state = active >= minHours * 3600 ? .attended : .absent
                    if state == .attended { attended += 1 } else { absent += 1 }
                }
                cells.append(Cell(id: slot, dayNumber: dayNumber, state: state))
            }
            rows.append(MonthRow(
                id: Format.dayKey.string(from: interval.start),
                label: monthFormatter.string(from: cursor),
                attended: attended, absent: absent, cells: cells))
            cursor = cal.date(byAdding: .month, value: 1, to: cursor)!
        }
        return rows
    }
}

// ================================================================ shared helpers

private func hourOfDay(_ date: Date, dayKey: String) -> Double {
    let dayStart = Calendar.current.startOfDay(for: date)
    return min(24, max(0, date.timeIntervalSince(dayStart) / 3600))
}

private func hourLabel(_ hour: Double) -> String {
    let h = Int(hour.rounded())
    if h == 0 || h == 24 { return "12AM" }
    if h == 12 { return "12PM" }
    return h < 12 ? "\(h)AM" : "\(h - 12)PM"
}

private func shortDay(_ dayKey: String) -> String {
    // yyyy-MM-dd → d/M
    let parts = dayKey.split(separator: "-")
    guard parts.count == 3 else { return dayKey }
    return "\(Int(parts[2]) ?? 0)/\(Int(parts[1]) ?? 0)"
}

private func longDay(_ dayKey: String) -> String {
    guard let date = Format.dayKey.date(from: dayKey) else { return dayKey }
    return Format.dayHeading.string(from: date)
}

private func zip<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
    guard let a, let b else { return nil }
    return (a, b)
}
