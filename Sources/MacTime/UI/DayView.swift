import SwiftUI

/// ManicTime day-tab structure: screenshot strip + timeline rows on top,
/// details list bottom-left, summary bottom-right.
struct DayView: View {
    @StateObject private var model: DayModel
    @StateObject private var hoverState = HoverState()
    @State private var showCalendar = false
    @State private var keyMonitor: Any?
    @State private var scrollMonitor: Any?
    /// Strip + timeline + overview pane, in "dayArea" coords — the box the
    /// hover preview is confined to.
    @State private var timelinePane: CGRect = .zero

    init(store: Store) {
        _model = StateObject(wrappedValue: DayModel(store: store))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            VSplitView {
                VStack(spacing: 0) {
                    // Same horizontal inset as TimelineArea below — the strip
                    // and the timeline must share one x scale to line up.
                    ScreenshotStrip(shots: model.visibleShots,
                                    visibleFrom: model.visibleFrom,
                                    visibleTo: model.visibleTo) { shot in
                        model.viewerMode = .frozen(shot)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 118)
                    .background(Color.primary.opacity(0.03))
                    TimelineArea(spans: model.spans, visibleFrom: model.visibleFrom,
                                 visibleTo: model.visibleTo,
                                 dayStart: model.day, dayEnd: model.dayEnd,
                                 selection: $model.selection, zoom: $model.zoom,
                                 hoverState: hoverState)
                        .frame(minHeight: 80, maxHeight: .infinity)
                        .padding(.horizontal, 12)
                    OverviewBar(spans: model.spans, dayStart: model.day,
                                dayEnd: model.dayEnd, zoom: $model.zoom,
                                hoverState: hoverState)
                        .frame(height: 22)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 4)
                }
                .frame(minHeight: 235)
                // The hover preview is clamped to this pane, so it never
                // strays over the header or the details table below.
                .background(GeometryReader { g in
                    Color.clear.preference(key: TimelinePaneKey.self,
                                           value: g.frame(in: .named("dayArea")))
                })
                ZStack {
                    HSplitView {
                        DetailsTable(rows: model.detailRows)
                            .frame(minWidth: 420)
                        SummaryPanel(model: model)
                            .frame(minWidth: 260, idealWidth: 320, maxWidth: 420)
                    }
                    if model.viewerMode != .closed {
                        DockedViewer(model: model, hoverState: hoverState)
                    }
                }
                .frame(minHeight: 160, maxHeight: .infinity)
            }
        }
        .coordinateSpace(name: "dayArea")
        .onPreferenceChange(TimelinePaneKey.self) { timelinePane = $0 }
        .overlay(alignment: .topLeading) {
            HoverOverlay(state: hoverState, model: model, bounds: timelinePane)
        }
        .onAppear {
            model.load()
            installKeyMonitor()
            installScrollMonitor()
        }
        .onDisappear {
            if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
            if let m = scrollMonitor { NSEvent.removeMonitor(m); scrollMonitor = nil }
        }
    }

    /// Scroll behavior: over the timeline it pans the zoom window (scroll up =
    /// back in time); over the overview bar it zooms in/out around the window
    /// center (scroll up = zoom in).
    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        let state = hoverState, model = model
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
                ? event.scrollingDeltaX : event.scrollingDeltaY
            guard delta != 0 else { return event }

            // Over the viewer image: the wheel zooms the screenshot. Checked
            // first — a mouse has no pinch gesture, so this is the only way to
            // zoom without a trackpad.
            if state.overViewer, model.viewerMode != .closed {
                model.zoomViewer(by: CGFloat(exp(Double(delta) / 200)))
                return nil
            }

            if state.point != nil, let z = model.zoom {
                // pan the timeline
                let length = z.upperBound.timeIntervalSince(z.lowerBound)
                let shift = -Double(delta) * length / 400.0
                var lower = z.lowerBound.addingTimeInterval(shift)
                lower = max(model.day, min(lower, model.dayEnd.addingTimeInterval(-length)))
                model.zoom = lower...lower.addingTimeInterval(length)
                return nil
            }

            if state.overOverview {
                // zoom around the window center
                let daySpan = model.dayEnd.timeIntervalSince(model.day)
                let current = model.zoom ?? model.day...model.dayEnd
                let length = current.upperBound.timeIntervalSince(current.lowerBound)
                let newLength = min(daySpan, max(60, length * exp(-Double(delta) / 150)))
                let mid = current.lowerBound.addingTimeInterval(length / 2)
                var lower = mid.addingTimeInterval(-newLength / 2)
                lower = max(model.day, min(lower, model.dayEnd.addingTimeInterval(-newLength)))
                let range = lower...lower.addingTimeInterval(newLength)
                model.zoom = (range.lowerBound <= model.day && range.upperBound >= model.dayEnd)
                    ? nil : range
                return nil
            }
            return event
        }
    }

    /// Space cycles the docked viewer: open (live, follows hover) → freeze on
    /// the hovered capture → back to live. Esc closes. Deliberately not an
    /// F-key: keyboards whose firmware owns the F-row as media keys (Keychron
    /// & co.) never deliver F11/F12 to the app at all.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        let state = hoverState, model = model
        // Open → live; live → freeze on the hovered (or last shown) capture;
        // frozen → back to live. Exit is Esc or ✕ only.
        let toggleViewer = {
            switch model.viewerMode {
            case .closed:
                model.viewerMode = .live
            case .live:
                if let t = state.time, let shot = model.nearestShot(to: t) {
                    model.viewerMode = .frozen(shot)
                } else if let shot = model.lastLiveShot {
                    model.viewerMode = .frozen(shot)
                }
            case .frozen:
                model.viewerMode = .live
            }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 49: // Space (kVK_Space) — only when the day window itself has
                     // focus: not the Settings window, not the calendar popover,
                     // and never while a text field is being edited.
                guard event.window === NSApp.mainWindow,
                      !(event.window?.firstResponder is NSTextView) else { return event }
                toggleViewer()
                return nil
            case 53: // Esc
                if model.viewerMode != .closed {
                    model.viewerMode = .closed
                    return nil
                }
                return event
            default:
                return event
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button { model.shift(by: -1) } label: { Image(systemName: "chevron.left") }
            Button { model.shift(by: 1) } label: { Image(systemName: "chevron.right") }
                .disabled(model.isToday)
            Button {
                showCalendar.toggle()
            } label: {
                HStack(spacing: 5) {
                    Text(Format.dayHeading.string(from: model.day))
                        .font(.title3.weight(.semibold))
                    Image(systemName: "calendar")
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showCalendar) {
                DatePicker("", selection: Binding(
                    get: { model.day },
                    set: { model.jump(to: $0); showCalendar = false }
                ), in: ...Date(), displayedComponents: .date)
                .datePickerStyle(.graphical)
                .frame(width: 260)
                .padding(10)
            }
            if !model.isToday {
                Button("Today") { model.goToday() }
            }
            // Mouse-reachable viewer toggle: the keyboard shortcuts alone are
            // undiscoverable, and on media-key keyboards F12 never arrives.
            Button {
                model.viewerMode = model.viewerMode == .closed ? .live : .closed
            } label: {
                Image(systemName: model.viewerMode == .closed
                      ? "photo.on.rectangle" : "photo.fill.on.rectangle.fill")
            }
            .help("Screenshot viewer — follows the timeline hover (Space)")
            Spacer()
            if let sel = model.selection {
                Text("Selection: \(Format.time.string(from: sel.lowerBound))–\(Format.time.string(from: sel.upperBound))")
                    .foregroundStyle(.secondary)
                Button("Clear") { model.selection = nil }
            } else if let bounds = model.dayBounds {
                Group {
                    Text("Day start ").foregroundStyle(.secondary)
                        + Text(Format.hm.string(from: bounds.start)).bold()
                        + Text("   Day end ").foregroundStyle(.secondary)
                        + Text(Format.hm.string(from: bounds.end)).bold()
                        + Text("   Duration ").foregroundStyle(.secondary)
                        + Text(Format.duration(bounds.end.timeIntervalSince(bounds.start))).bold()
                }
                .font(.callout.monospacedDigit())
            }
            Text("Active \(Format.duration(model.activeTotal))")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// ============================================================== hover preview

/// Published separately from DayModel so mouse-move updates re-render only the
/// overlay, not the whole day view.
final class HoverState: ObservableObject {
    @Published var point: CGPoint?   // in the "dayArea" coordinate space
    @Published var time: Date?
    /// Cursor is over the overview bar — read by the scroll monitor only,
    /// deliberately not published (no view depends on it).
    var overOverview = false
    /// Cursor is over the docked viewer image, so the scroll wheel zooms the
    /// screenshot instead of panning the timeline. Also unpublished.
    var overViewer = false
}

/// Frame of the strip/timeline/overview pane in "dayArea" coords.
struct TimelinePaneKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

struct HoverOverlay: View {
    @ObservedObject var state: HoverState
    @ObservedObject var model: DayModel
    /// Pane the preview is confined to; falls back to the whole day area.
    var bounds: CGRect = .zero

    @AppStorage(Settings.Key.hoverPreviewOffsetX) private var offsetX = -8.0
    @AppStorage(Settings.Key.hoverPreviewOffsetY) private var offsetY = -8.0

    var body: some View {
        GeometryReader { geo in
            if let p = state.point, let t = state.time {
                let viewerOpen = model.viewerMode != .closed
                let shot = model.nearestShot(to: t)
                let box = HoverTooltip.boxSize(hasShot: shot != nil, viewerOpen: viewerOpen)
                let full = CGRect(origin: .zero, size: geo.size)
                // A pane shorter than the box collapses the clamp to a single
                // value, which parks the preview instead of tracking. Fall back
                // to the whole area rather than pin it.
                let pane = bounds.isEmpty ? full : bounds
                let b = pane.height < box.height + 24 ? full : pane
                // The configured offset places the box's bottom-right corner;
                // .offset positions its top-left, hence the subtraction. Doing
                // it from the bottom-right keeps the gap constant across the
                // with-thumbnail and timestamp-only sizes.
                let wantX = p.x + CGFloat(offsetX) - box.width
                let wantY = p.y + CGFloat(offsetY) - box.height
                HoverTooltip(time: t, span: model.span(at: t), shot: shot,
                             viewerOpen: viewerOpen)
                    .offset(x: clamp(wantX, b.minX + 4, b.maxX - box.width - 4),
                            y: clamp(wantY, b.minY + 4, b.maxY - box.height - 4))
            }
        }
        .allowsHitTesting(false)
    }

    /// Low bound wins when the pane is smaller than the box, so a cramped
    /// window pins the preview to the top-left rather than inverting it.
    private func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        hi < lo ? lo : min(max(v, lo), hi)
    }
}

/// ManicTime-style hover readout: time, the span under the cursor with its
/// range and duration, and a thumbnail of the nearest capture. The full-size
/// screenshot shows in the docked viewer (Space).
struct HoverTooltip: View {
    let time: Date
    let span: ActivitySpan?
    let shot: ScreenshotRecord?
    let viewerOpen: Bool

    private static let pad: CGFloat = 8
    private static let gap: CGFloat = 3
    private static let thumbW: CGFloat = 213
    private static let thumbH: CGFloat = 120
    private static let headerH: CGFloat = 52   // time + app row + range row
    private static let hintH: CGFloat = 15

    /// Exact box size, computed instead of measured. Placement needs it *before*
    /// layout runs, and reading it back with a PreferenceKey never delivered
    /// here. Every row below is explicitly framed so this stays truthful.
    static func boxSize(hasShot: Bool, viewerOpen: Bool) -> CGSize {
        var h = pad * 2 + headerH
        if hasShot { h += gap + thumbH }
        if !viewerOpen { h += gap + hintH }
        return CGSize(width: pad * 2 + thumbW, height: h)
    }

    /// Stacked: time + app on top, thumbnail in the middle, viewer hint at the
    /// bottom.
    var body: some View {
        VStack(alignment: .leading, spacing: Self.gap) {
            VStack(alignment: .leading, spacing: Self.gap) {
                Text(Format.time.string(from: time))
                    .font(.caption.weight(.semibold).monospacedDigit())
                if let span {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(color(span.kind))
                            .frame(width: 7, height: 7)
                        Text(span.kind == .active ? span.appName
                             : span.kind == .idle ? "Away" : "Sleep")
                            .font(.caption)
                            .lineLimit(1)
                    }
                    Text("\(Format.time.string(from: span.start)) – \(Format.time.string(from: span.end)) (\(Format.duration(span.duration)))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(width: Self.thumbW, height: Self.headerH, alignment: .topLeading)

            if let shot {
                HoverThumb(shot: shot)
            }

            if !viewerOpen {
                Text("Space · screenshot viewer")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(width: Self.thumbW, height: Self.hintH, alignment: .leading)
            }
        }
        .padding(Self.pad)
        .frame(width: Self.boxSize(hasShot: shot != nil, viewerOpen: viewerOpen).width,
               height: Self.boxSize(hasShot: shot != nil, viewerOpen: viewerOpen).height,
               alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
        .shadow(radius: 6, y: 2)
    }

    private func color(_ kind: SpanKind) -> Color {
        switch kind {
        case .active: return .green
        case .idle: return .gray
        case .sleep: return .indigo
        }
    }
}

/// The small capture preview inside the hover tooltip. Loads the pre-encoded
/// 120px thumbnail (never the full shot — this re-fires on every hover move)
/// and keeps it through ImageCache, same as the strip cells.
private struct HoverThumb: View {
    let shot: ScreenshotRecord
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 4).fill(.quaternary)
            }
        }
        .frame(width: 213, height: 120)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task(id: shot.id) {
            image = await ImageCache.image(path: shot.thumbPath)
        }
    }
}

// ============================================================== model

final class DayModel: ObservableObject {
    let store: Store
    @Published var day: Date
    @Published var spans: [ActivitySpan] = []
    @Published var shots: [ScreenshotRecord] = []
    @Published var selection: ClosedRange<Date>? {
        didSet { rebuildDerived() }
    }
    /// Visible timeline window; nil = the whole day. Driven by the overview bar.
    @Published var zoom: ClosedRange<Date>?
    @Published var viewerMode: ViewerMode = .closed {
        didSet { if viewerMode != oldValue { resetViewerTransform() } }
    }
    /// Viewer zoom/pan. Lives here rather than in DockedViewer so the scroll
    /// monitor can drive the zoom — a mouse wheel has no pinch gesture.
    @Published var viewerZoom: CGFloat = 1
    @Published var viewerPan: CGSize = .zero
    /// Last capture the live viewer displayed — what a hover-less Space freezes.
    var lastLiveShot: ScreenshotRecord?

    static let maxViewerZoom: CGFloat = 8

    func resetViewerTransform() {
        viewerZoom = 1
        viewerPan = .zero
    }

    /// Zoom about the viewer centre, dropping the pan once we're back to fit.
    func zoomViewer(by factor: CGFloat) {
        viewerZoom = min(Self.maxViewerZoom, max(1, viewerZoom * factor))
        if viewerZoom == 1 { viewerPan = .zero }
    }
    @Published var detailRows: [DetailRow] = []

    enum ViewerMode: Equatable {
        case closed
        case live                       // follows timeline hover (F12)
        case frozen(ScreenshotRecord)   // pinned to one capture (F11 / click)
    }

    private var refreshTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    /// The shown day was today when it was picked, so it should follow the clock
    /// across midnight. Cleared once the user browses to some other day.
    private var followingToday = true

    init(store: Store) {
        self.store = store
        self.day = Calendar.current.startOfDay(for: Date())
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        // A sleep can span a date change; refresh on wake rather than waiting
        // out the next 30s tick.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit {
        refreshTimer?.invalidate()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    /// Reload the day, rolling `day` over first if the clock crossed midnight
    /// while we were following today (e.g. the Mac slept through it). Without
    /// the rollover the view latches onto the day it was opened on forever.
    private func refresh() {
        guard followingToday else { return }
        if !isToday {
            day = Calendar.current.startOfDay(for: Date())
            selection = nil
            zoom = nil
        }
        load()
    }

    var dayEnd: Date { Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day }
    var isToday: Bool { Calendar.current.isDateInToday(day) }

    var range: (Date, Date) {
        if let sel = selection { return (sel.lowerBound, sel.upperBound) }
        return (day, dayEnd)
    }

    var visibleShots: [ScreenshotRecord] {
        if let sel = selection {
            return shots.filter { $0.takenAt >= sel.lowerBound && $0.takenAt <= sel.upperBound }
        }
        if let z = zoom {
            return shots.filter { $0.takenAt >= z.lowerBound && $0.takenAt <= z.upperBound }
        }
        return shots
    }

    var visibleFrom: Date { zoom?.lowerBound ?? day }
    var visibleTo: Date { zoom?.upperBound ?? dayEnd }

    func shift(by days: Int) {
        day = Calendar.current.date(byAdding: .day, value: days, to: day) ?? day
        selection = nil
        zoom = nil
        followingToday = isToday
        load()
    }

    func goToday() {
        day = Calendar.current.startOfDay(for: Date())
        selection = nil
        zoom = nil
        followingToday = true
        load()
    }

    func jump(to date: Date) {
        day = Calendar.current.startOfDay(for: date)
        selection = nil
        zoom = nil
        followingToday = isToday
        load()
    }

    /// Span under a timeline moment — the hover tooltip's info line.
    func span(at time: Date) -> ActivitySpan? {
        spans.last { $0.start <= time && time < $0.end }
    }

    /// Viewer Delete action: remove files + row, refresh.
    func delete(_ shot: ScreenshotRecord) {
        try? FileManager.default.removeItem(atPath: shot.path)
        try? FileManager.default.removeItem(atPath: shot.thumbPath)
        store.deleteScreenshot(id: shot.id)
        if case .frozen(let frozen) = viewerMode, frozen.id == shot.id {
            viewerMode = .live
        }
        load()
    }

    /// First and last active moment of the loaded day (ManicTime's
    /// "Day start / Day end / Duration" header).
    var dayBounds: (start: Date, end: Date)? {
        let active = spans.filter { $0.kind == .active }
        guard let first = active.first?.start,
              let last = active.map(\.end).max() else { return nil }
        return (first, last)
    }

    /// Nearest screenshot within 15 minutes of a hovered timeline moment.
    func nearestShot(to time: Date) -> ScreenshotRecord? {
        guard let best = shots.min(by: {
            abs($0.takenAt.timeIntervalSince(time)) < abs($1.takenAt.timeIntervalSince(time))
        }) else { return nil }
        return abs(best.takenAt.timeIntervalSince(time)) <= 900 ? best : nil
    }

    func load() {
        spans = store.spans(from: day, to: dayEnd)
        shots = store.screenshots(from: day, to: dayEnd)
        rebuildDerived()
    }

    // Seconds of each span clamped to the current range.
    private func clamped(_ span: ActivitySpan) -> TimeInterval {
        let (from, to) = range
        let s = max(span.start, from), e = min(span.end, to)
        return max(0, e.timeIntervalSince(s))
    }

    var activeTotal: TimeInterval { total(of: .active) }
    var idleTotal: TimeInterval { total(of: .idle) }
    var sleepTotal: TimeInterval { total(of: .sleep) }

    private func total(of kind: SpanKind) -> TimeInterval {
        spans.filter { $0.kind == kind }.reduce(0) { $0 + clamped($1) }
    }

    var appTotals: [AppTotal] {
        var acc: [String: (name: String, secs: TimeInterval)] = [:]
        for span in spans where span.kind == .active {
            let secs = clamped(span)
            if secs <= 0 { continue }
            acc[span.bundleId, default: (span.appName, 0)].secs += secs
        }
        return acc.map { AppTotal(bundleId: $0.key, appName: $0.value.name, seconds: $0.value.secs) }
            .sorted { $0.seconds > $1.seconds }
    }

    private func rebuildDerived() {
        var acc: [String: DetailRow] = [:]
        for span in spans where span.kind == .active {
            let secs = clamped(span)
            if secs <= 0 { continue }
            let title = span.url ?? span.title ?? ""
            let key = span.bundleId + "\u{1}" + title
            if var row = acc[key] {
                row.seconds += secs
                acc[key] = row
            } else {
                acc[key] = DetailRow(id: key, bundleId: span.bundleId, appName: span.appName,
                                     title: title, seconds: secs)
            }
        }
        let total = max(1, acc.values.reduce(0) { $0 + $1.seconds })
        detailRows = acc.values
            .map { row in
                var r = row
                r.share = row.seconds / total
                return r
            }
            .sorted { $0.seconds > $1.seconds }
    }
}

struct DetailRow: Identifiable {
    let id: String
    let bundleId: String
    let appName: String
    let title: String
    var seconds: TimeInterval
    var share: Double = 0
}

// ============================================================== timeline

struct TimelineArea: View {
    let spans: [ActivitySpan]
    let visibleFrom: Date
    let visibleTo: Date
    let dayStart: Date
    let dayEnd: Date
    @Binding var selection: ClosedRange<Date>?
    @Binding var zoom: ClosedRange<Date>?
    let hoverState: HoverState

    /// Pinch anchor: the visible range and focal time when the gesture began.
    @State private var pinch: (range: ClosedRange<Date>, focus: Date)?

    var body: some View {
        TimelineCanvas(spans: spans, visibleFrom: visibleFrom, visibleTo: visibleTo,
                       selection: $selection, hoverState: hoverState)
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { scale in magnify(by: scale) }
                    .onEnded { _ in pinch = nil }
            )
    }

    /// Trackpad pinch zooms the timeline around the hovered moment.
    private func magnify(by scale: CGFloat) {
        if pinch == nil {
            let range = zoom ?? dayStart...dayEnd
            let mid = range.lowerBound.addingTimeInterval(
                range.upperBound.timeIntervalSince(range.lowerBound) / 2)
            pinch = (range, hoverState.time ?? mid)
        }
        guard let pinch else { return }
        let daySpan = dayEnd.timeIntervalSince(dayStart)
        let baseLength = pinch.range.upperBound.timeIntervalSince(pinch.range.lowerBound)
        let length = min(daySpan, max(60, baseLength / Double(scale)))
        // keep the focal moment at the same relative position
        let frac = pinch.focus.timeIntervalSince(pinch.range.lowerBound) / max(baseLength, 1)
        var lower = pinch.focus.addingTimeInterval(-length * frac)
        lower = max(dayStart, min(lower, dayEnd.addingTimeInterval(-length)))
        let range = lower...lower.addingTimeInterval(length)
        zoom = (range.lowerBound <= dayStart && range.upperBound >= dayEnd) ? nil : range
    }
}

struct TimelineCanvas: View {
    let spans: [ActivitySpan]
    let visibleFrom: Date
    let visibleTo: Date
    @Binding var selection: ClosedRange<Date>?
    let hoverState: HoverState

    private var span: TimeInterval { max(60, visibleTo.timeIntervalSince(visibleFrom)) }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            Canvas { ctx, size in
                draw(ctx: &ctx, size: size)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { v in
                        let a = time(at: v.startLocation.x, width: width)
                        let b = time(at: v.location.x, width: width)
                        selection = min(a, b)...max(a, b)
                    }
            )
            .onTapGesture { selection = nil }
            // Hover in LOCAL space, converted to dayArea by hand. Asking for
            // .named("dayArea") directly returned a y the overlay couldn't use,
            // which pinned the preview to the top of its clamp range.
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let local):
                    let frame = geo.frame(in: .named("dayArea"))
                    hoverState.point = CGPoint(x: frame.minX + local.x,
                                               y: frame.minY + local.y)
                    hoverState.time = time(at: local.x, width: width)
                case .ended:
                    hoverState.point = nil
                    hoverState.time = nil
                }
            }
        }
    }

    private func time(at x: CGFloat, width: CGFloat) -> Date {
        let frac = max(0, min(1, x / max(width, 1)))
        return visibleFrom.addingTimeInterval(span * frac)
    }

    private static let axisFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private func draw(ctx: inout GraphicsContext, size: CGSize) {
        let w = size.width
        // Rows scale with the pane height (the details/timeline split is draggable).
        let axisZone: CGFloat = 16
        let contentH = max(36, size.height - axisZone)
        let statusY: CGFloat = 2
        let statusH = max(12, (contentH - 10) * 0.32)
        let appsY = statusY + statusH + 6
        let appsH = max(16, contentH - appsY - 2)
        let axisY = contentH

        // track backgrounds
        ctx.fill(Path(roundedRect: CGRect(x: 0, y: statusY, width: w, height: statusH), cornerRadius: 3),
                 with: .color(Color.primary.opacity(0.06)))
        ctx.fill(Path(roundedRect: CGRect(x: 0, y: appsY, width: w, height: appsH), cornerRadius: 3),
                 with: .color(Color.primary.opacity(0.06)))

        for item in spans {
            guard item.end > visibleFrom, item.start < visibleTo else { continue }
            let x0 = x(for: item.start, width: w)
            let x1 = x(for: item.end, width: w)
            guard x1 > x0 else { continue }
            let rectW = max(x1 - x0, 0.5)

            let statusColor: Color
            switch item.kind {
            case .active: statusColor = .green
            case .idle: statusColor = Color.gray.opacity(0.55)
            case .sleep: statusColor = Color.indigo.opacity(0.5)
            }
            ctx.fill(Path(CGRect(x: x0, y: statusY, width: rectW, height: statusH)),
                     with: .color(statusColor))

            if item.kind == .active {
                ctx.fill(Path(CGRect(x: x0, y: appsY, width: rectW, height: appsH)),
                         with: .color(Color(nsColor: AppColor.nsColor(for: item.bundleId))))
            }
        }

        // time axis: tick step adapts to the zoom level (labels ≥ ~70pt apart)
        let candidates: [TimeInterval] = [300, 600, 900, 1800, 3600, 7200, 10800, 21600, 43200]
        let step = candidates.first { $0 >= span * 70 / max(Double(w), 1) } ?? 43_200
        let dayStart = Calendar.current.startOfDay(for: visibleFrom)
        let offset = (visibleFrom.timeIntervalSince(dayStart) / step).rounded(.down) * step
        var tick = dayStart.addingTimeInterval(offset)
        while tick <= visibleTo {
            defer { tick = tick.addingTimeInterval(step) }
            guard tick >= visibleFrom else { continue }
            let hx = x(for: tick, width: w)
            var line = Path()
            line.move(to: CGPoint(x: hx, y: statusY))
            line.addLine(to: CGPoint(x: hx, y: axisY - 4))
            ctx.stroke(line, with: .color(Color.primary.opacity(0.12)), lineWidth: 1)
            ctx.draw(Text(Self.axisFormat.string(from: tick)).font(.caption2).foregroundStyle(.secondary),
                     at: CGPoint(x: min(max(hx, 18), w - 18), y: axisY + 6))
        }

        // row labels, inside the tracks so they follow the scaling rows
        ctx.draw(Text("Status").font(.caption2).foregroundStyle(.secondary),
                 at: CGPoint(x: 6, y: statusY + statusH / 2), anchor: .leading)
        ctx.draw(Text("Apps").font(.caption2).foregroundStyle(.secondary),
                 at: CGPoint(x: 6, y: appsY + appsH / 2), anchor: .leading)

        // selection overlay
        if let sel = selection, sel.upperBound > visibleFrom, sel.lowerBound < visibleTo {
            let x0 = x(for: sel.lowerBound, width: w)
            let x1 = x(for: sel.upperBound, width: w)
            ctx.fill(Path(CGRect(x: x0, y: 0, width: max(x1 - x0, 1), height: axisY)),
                     with: .color(Color.accentColor.opacity(0.18)))
            var edges = Path()
            edges.move(to: CGPoint(x: x0, y: 0)); edges.addLine(to: CGPoint(x: x0, y: axisY))
            edges.move(to: CGPoint(x: x1, y: 0)); edges.addLine(to: CGPoint(x: x1, y: axisY))
            ctx.stroke(edges, with: .color(Color.accentColor.opacity(0.7)), lineWidth: 1)
        }
    }

    private func x(for date: Date, width: CGFloat) -> CGFloat {
        let frac = date.timeIntervalSince(visibleFrom) / span
        return max(0, min(width, width * CGFloat(frac)))
    }
}

// ============================================================== overview bar

/// The zoom/pan strip under the timeline: always shows the full day with a
/// draggable window over the visible range. Drag inside to pan, drag the edges
/// to resize, drag outside to jump, double-click to reset to the whole day.
struct OverviewBar: View {
    let spans: [ActivitySpan]
    let dayStart: Date
    let dayEnd: Date
    @Binding var zoom: ClosedRange<Date>?
    let hoverState: HoverState

    @State private var mode: DragMode?
    @State private var pinchBase: ClosedRange<Date>?
    private enum DragMode { case pan(TimeInterval), left, right, rubberBand(Date) }

    private var daySpan: TimeInterval { dayEnd.timeIntervalSince(dayStart) }
    private static let minWindow: TimeInterval = 600

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            Canvas { ctx, size in draw(ctx: &ctx, size: size) }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { v in handleDrag(v, width: w) }
                        .onEnded { _ in mode = nil }
                )
                .simultaneousGesture(
                    MagnificationGesture()
                        .onChanged { scale in pinchZoom(by: scale) }
                        .onEnded { _ in pinchBase = nil }
                )
                .onTapGesture(count: 2) { zoom = nil }
                .onHover { hoverState.overOverview = $0 }
                .help("Drag to select a range, scroll or pinch to zoom, double-click to reset")
        }
    }

    /// Pinch on the bar zooms around the window's center.
    private func pinchZoom(by scale: CGFloat) {
        if pinchBase == nil { pinchBase = zoom ?? dayStart...dayEnd }
        guard let base = pinchBase else { return }
        let baseLength = base.upperBound.timeIntervalSince(base.lowerBound)
        let length = min(daySpan, max(60, baseLength / Double(scale)))
        let mid = base.lowerBound.addingTimeInterval(baseLength / 2)
        var lower = mid.addingTimeInterval(-length / 2)
        lower = max(dayStart, min(lower, dayEnd.addingTimeInterval(-length)))
        setZoom(lower...lower.addingTimeInterval(length))
    }

    private func x(for date: Date, width: CGFloat) -> CGFloat {
        width * CGFloat(date.timeIntervalSince(dayStart) / daySpan)
    }

    private func time(at x: CGFloat, width: CGFloat) -> Date {
        dayStart.addingTimeInterval(daySpan * Double(max(0, min(1, x / max(width, 1)))))
    }

    private func handleDrag(_ v: DragGesture.Value, width: CGFloat) {
        let current = zoom ?? dayStart...dayEnd
        if mode == nil {
            let x0 = x(for: current.lowerBound, width: width)
            let x1 = x(for: current.upperBound, width: width)
            if zoom != nil, abs(v.startLocation.x - x0) < 10 {
                mode = .left
            } else if zoom != nil, abs(v.startLocation.x - x1) < 10 {
                mode = .right
            } else if zoom != nil, v.startLocation.x > x0, v.startLocation.x < x1 {
                mode = .pan(time(at: v.startLocation.x, width: width)
                    .timeIntervalSince(current.lowerBound))
            } else {
                // un-zoomed (or outside the window): rubber-band a new window
                mode = .rubberBand(time(at: v.startLocation.x, width: width))
            }
        }
        let t = time(at: v.location.x, width: width)
        switch mode {
        case .pan(let offset):
            let length = current.upperBound.timeIntervalSince(current.lowerBound)
            var lower = t.addingTimeInterval(-offset)
            lower = max(dayStart, min(lower, dayEnd.addingTimeInterval(-length)))
            setZoom(lower...lower.addingTimeInterval(length))
        case .left:
            let lower = min(t, current.upperBound.addingTimeInterval(-Self.minWindow))
            setZoom(max(dayStart, lower)...current.upperBound)
        case .right:
            let upper = max(t, current.lowerBound.addingTimeInterval(Self.minWindow))
            setZoom(current.lowerBound...min(dayEnd, upper))
        case .rubberBand(let anchor):
            let lower = max(dayStart, min(anchor, t))
            let upper = min(dayEnd, max(anchor, t))
            if upper.timeIntervalSince(lower) >= 60 {
                zoom = lower...upper
            }
        case nil:
            break
        }
    }

    private func setZoom(_ range: ClosedRange<Date>) {
        if range.lowerBound <= dayStart && range.upperBound >= dayEnd {
            zoom = nil
        } else {
            zoom = range
        }
    }

    private func draw(ctx: inout GraphicsContext, size: CGSize) {
        let w = size.width, h = size.height
        ctx.fill(Path(roundedRect: CGRect(x: 0, y: 2, width: w, height: h - 4), cornerRadius: 4),
                 with: .color(Color.primary.opacity(0.07)))

        // activity minimap
        for item in spans where item.kind == .active {
            let x0 = x(for: item.start, width: w)
            let x1 = x(for: item.end, width: w)
            ctx.fill(Path(CGRect(x: x0, y: h - 7, width: max(x1 - x0, 0.5), height: 4)),
                     with: .color(.green.opacity(0.7)))
        }

        // hour ticks every 4h
        for hour in stride(from: 0, through: 24, by: 4) {
            let hx = w * CGFloat(hour) / 24
            var line = Path()
            line.move(to: CGPoint(x: hx, y: 4))
            line.addLine(to: CGPoint(x: hx, y: h - 4))
            ctx.stroke(line, with: .color(Color.primary.opacity(0.1)), lineWidth: 1)
        }

        // zoom window
        let range = zoom ?? dayStart...dayEnd
        let x0 = x(for: range.lowerBound, width: w)
        let x1 = x(for: range.upperBound, width: w)
        let window = CGRect(x: x0, y: 2, width: max(x1 - x0, 4), height: h - 4)
        ctx.fill(Path(roundedRect: window, cornerRadius: 4),
                 with: .color(Color.accentColor.opacity(zoom == nil ? 0.10 : 0.22)))
        ctx.stroke(Path(roundedRect: window, cornerRadius: 4),
                   with: .color(Color.accentColor.opacity(0.8)), lineWidth: 1)
        // edge handles
        for hx in [window.minX, window.maxX] {
            ctx.fill(Path(roundedRect: CGRect(x: hx - 1.5, y: 4, width: 3, height: h - 8), cornerRadius: 1.5),
                     with: .color(Color.accentColor.opacity(0.9)))
        }
    }
}

// ============================================================== docked viewer

/// The ManicTime-style screenshot viewer: overlays the details/summary area
/// instead of opening a window. Live mode follows the timeline hover; frozen
/// mode pins one capture and offers file actions.
struct DockedViewer: View {
    @ObservedObject var model: DayModel
    @ObservedObject var hoverState: HoverState
    @State private var image: NSImage?
    /// Gesture anchors: pan offset when the drag began, zoom when the pinch did.
    @State private var panBase: CGSize = .zero
    @State private var zoomBase: CGFloat?

    private var shot: ScreenshotRecord? {
        switch model.viewerMode {
        case .closed: return nil
        case .frozen(let s): return s
        case .live:
            if let t = hoverState.time, let s = model.nearestShot(to: t) { return s }
            return model.lastLiveShot
        }
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d/M/yyyy h:mm:ss a"
        return f
    }()

    var body: some View {
        let current = shot
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if let current {
                    let span = model.span(at: current.takenAt)
                    Circle()
                        .fill(kindColor(span?.kind))
                        .frame(width: 8, height: 8)
                    Text(kindLabel(span))
                    Text(Self.stamp.string(from: current.takenAt))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else {
                    Text("Hover the timeline to preview screenshots")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.viewerZoom > 1 {
                    Button {
                        model.resetViewerTransform()
                    } label: {
                        Text(String(format: "%.0f%% · fit", model.viewerZoom * 100))
                            .font(.caption.monospacedDigit())
                    }
                    .buttonStyle(.plain)
                    .help("Reset zoom (or double-click the image)")
                }
                Text(model.viewerMode == .live ? "Live · Space freezes · Esc closes" : "Frozen · Space unfreezes · Esc closes")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                if let current {
                    Menu {
                        actions(for: current)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 34)
                }
                Button {
                    model.viewerMode = .closed
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            ZStack {
                Color.black.opacity(0.85)
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .scaleEffect(model.viewerZoom)
                        .offset(model.viewerPan)
                        .gesture(panGesture)
                        .simultaneousGesture(zoomGesture)
                        .onTapGesture(count: 2) { model.resetViewerTransform() }
                } else if current != nil {
                    ProgressView()
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .onHover { hoverState.overViewer = $0 }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: current?.id) {
            guard let current else { image = nil; return }
            // A different capture means the old zoom/pan no longer refers to
            // anything — start it back at fit. Live mode changes shot on every
            // hover move, so this also keeps live from inheriting a stale pan.
            model.resetViewerTransform()
            panBase = .zero
            zoomBase = nil
            model.lastLiveShot = current
            let path = current.path
            image = await Task.detached(priority: .userInitiated) { NSImage(contentsOfFile: path) }.value
        }
    }

    /// Drag pans the zoomed image. At fit (1×) there's nothing to pan, so the
    /// gesture stays out of the way.
    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { v in
                guard model.viewerZoom > 1 else { return }
                model.viewerPan = CGSize(width: panBase.width + v.translation.width,
                                         height: panBase.height + v.translation.height)
            }
            .onEnded { _ in panBase = model.viewerPan }
    }

    /// Trackpad pinch. `zoomBase` anchors the gesture so it scales from where
    /// it started rather than compounding every frame.
    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { scale in
                if zoomBase == nil { zoomBase = model.viewerZoom }
                let base = zoomBase ?? 1
                model.viewerZoom = min(DayModel.maxViewerZoom, max(1, base * scale))
                if model.viewerZoom == 1 { model.viewerPan = .zero }
            }
            .onEnded { _ in
                zoomBase = nil
                panBase = model.viewerPan
            }
    }

    @ViewBuilder
    private func actions(for shot: ScreenshotRecord) -> some View {
        Button("Open in Preview") {
            NSWorkspace.shared.open(URL(fileURLWithPath: shot.path))
        }
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: shot.path)])
        }
        Button("Copy to Clipboard") {
            if let img = image {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([img])
            }
        }
        Button("Save As…") {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = URL(fileURLWithPath: shot.path).lastPathComponent
            panel.begin { response in
                guard response == .OK, let dest = panel.url else { return }
                try? FileManager.default.copyItem(at: URL(fileURLWithPath: shot.path), to: dest)
            }
        }
        Divider()
        Button("Delete", role: .destructive) {
            model.delete(shot)
        }
    }

    private func kindColor(_ kind: SpanKind?) -> Color {
        switch kind {
        case .active, nil: return .green
        case .idle: return .gray
        case .sleep: return .indigo
        }
    }

    private func kindLabel(_ span: ActivitySpan?) -> String {
        guard let span else { return "Active" }
        switch span.kind {
        case .active: return span.appName
        case .idle: return "Away"
        case .sleep: return "Sleep"
        }
    }
}

// ============================================================== screenshot strip

/// Thumbnails sit at their capture time on the *same* x scale as the timeline
/// below, so a shot lines up with the activity it belongs to. (It used to be a
/// plain scrolling list, which meant the strip and the timeline agreed about
/// nothing.)
struct ScreenshotStrip: View {
    let shots: [ScreenshotRecord]
    let visibleFrom: Date
    let visibleTo: Date
    let onOpen: (ScreenshotRecord) -> Void

    private static let thumbW: CGFloat = 156

    private struct Placed: Identifiable {
        let shot: ScreenshotRecord
        let x: CGFloat
        var id: Int64 { shot.id }
    }

    var body: some View {
        GeometryReader { geo in
            let placed = place(width: geo.size.width)
            ZStack(alignment: .topLeading) {
                if placed.isEmpty {
                    Text(shots.isEmpty ? "No screenshots in this range"
                                       : "Zoom in to see screenshots")
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ForEach(placed) { item in
                        ThumbCell(shot: item.shot, width: Self.thumbW)
                            .offset(x: item.x, y: 4)
                            .onTapGesture { onOpen(item.shot) }
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
        }
    }

    /// Centre each thumbnail on its capture time. Zoomed out, hundreds of shots
    /// map to the same few pixels — keep the first of any overlapping cluster
    /// and drop the rest, so what's shown is still exactly where it happened.
    /// Two displays captured at one instant collapse the same way.
    private func place(width: CGFloat) -> [Placed] {
        let span = max(60, visibleTo.timeIntervalSince(visibleFrom))
        var out: [Placed] = []
        var lastX = -CGFloat.greatestFiniteMagnitude
        for shot in shots {
            let frac = shot.takenAt.timeIntervalSince(visibleFrom) / span
            guard frac >= 0, frac <= 1 else { continue }
            let x = width * CGFloat(frac) - Self.thumbW / 2
            guard x >= lastX + Self.thumbW + 4 else { continue }
            lastX = x
            out.append(Placed(shot: shot, x: x))
        }
        return out
    }
}

struct ThumbCell: View {
    let shot: ScreenshotRecord
    var width: CGFloat = 156
    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 2) {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    RoundedRectangle(cornerRadius: 4).fill(.quaternary)
                }
            }
            .frame(width: width, height: 88)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            Text(Format.time.string(from: shot.takenAt))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(width: width)
        .task(id: shot.id) {
            image = await ImageCache.image(path: shot.thumbPath)
        }
    }
}

// ============================================================== details + summary

struct DetailsTable: View {
    let rows: [DetailRow]

    var body: some View {
        Table(rows) {
            TableColumn("Application") { row in
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color(nsColor: AppColor.nsColor(for: row.bundleId)))
                        .frame(width: 8, height: 8)
                    Text(row.appName)
                }
            }
            .width(min: 120, ideal: 160)
            TableColumn("Title / URL") { row in
                Text(row.title.isEmpty ? "—" : row.title)
                    .foregroundStyle(row.title.isEmpty ? .tertiary : .primary)
                    .help(row.title)
            }
            TableColumn("Duration") { row in
                Text(Format.duration(row.seconds)).monospacedDigit()
            }
            .width(80)
            TableColumn("%") { row in
                Text(String(format: "%.0f%%", row.share * 100)).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(44)
        }
    }
}

struct SummaryPanel: View {
    @ObservedObject var model: DayModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(model.selection == nil ? "Day summary" : "Selection summary")
                    .font(.headline)

                kindRow("Active", model.activeTotal, .green)
                kindRow("Away", model.idleTotal, .gray)
                if model.sleepTotal > 0 {
                    kindRow("Sleep", model.sleepTotal, .indigo)
                }

                Divider()

                let totals = model.appTotals
                let maxSecs = max(totals.first?.seconds ?? 1, 1)
                ForEach(totals.prefix(10)) { total in
                    VStack(alignment: .leading, spacing: 2) {
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
                        .font(.callout)
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color(nsColor: AppColor.nsColor(for: total.bundleId)).opacity(0.7))
                                .frame(width: geo.size.width * total.seconds / maxSecs)
                        }
                        .frame(height: 4)
                    }
                }
            }
            .padding(12)
        }
    }

    private func kindRow(_ label: String, _ seconds: TimeInterval, _ color: Color) -> some View {
        HStack {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
            Spacer()
            Text(Format.duration(seconds)).monospacedDigit().foregroundStyle(.secondary)
        }
        .font(.callout)
    }
}
