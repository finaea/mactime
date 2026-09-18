import AppKit

enum Format {
    /// "2h 13m", "45m 10s", "12s"
    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s >= 3600 { return "\(s / 3600)h \((s % 3600) / 60)m" }
        if s >= 60 { return "\(s / 60)m \(s % 60)s" }
        return "\(s)s"
    }

    static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static let hm: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    static let dayHeading: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE, d MMM yyyy"
        return f
    }()

    /// yyyy-MM-dd for screenshot day folders and `screenshots.day`.
    ///
    /// Without a locale and a calendar a fixed-format formatter emits whatever
    /// the user's *region* dictates rather than the format string (Apple
    /// QA1480). Both pins are needed and neither substitutes for the other: the
    /// locale fixes the numbering system — an Arabic-indic region writes
    /// `٢٠٢٦-٠٩-١٥` — and the calendar fixes the era, since a Buddhist-calendar
    /// region writes `2569-09-15` in perfectly ordinary ASCII. Retention used to compare
    /// those names lexically, so a region change either destroyed history early
    /// or — the privacy failure — stopped matching anything at all while
    /// Settings still promised "Keep for 14 days". Retention now works off
    /// `taken_at`; pinning keeps the *names* stable too, and lets the ASCII
    /// hand-parsers in TimeMath and StatsView read back what we wrote.
    ///
    /// The time zone is deliberately *not* pinned. "Day" means local day
    /// everywhere else in the app — `Store.dayStats` splits spans on
    /// `Calendar.current` midnights, `DayModel` opens on `startOfDay` — so the
    /// formatter has to keep following the system zone. Setting the calendar
    /// does not change that: it stays on `TimeZone.current` and its boundaries
    /// still line up with `Calendar.current.startOfDay`.
    static let dayKey: DateFormatter = {
        let f = DateFormatter()
        // Locale before dateFormat: assigning it can reset a format already set.
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

enum AppColor {
    /// Stable per-app color: hash the bundle id into a hue.
    static func nsColor(for bundleId: String) -> NSColor {
        if bundleId.isEmpty { return .systemGray }
        var h: UInt64 = 5381
        for b in bundleId.utf8 { h = h &* 33 &+ UInt64(b) }
        let hue = CGFloat(h % 360) / 360.0
        return NSColor(hue: hue, saturation: 0.55, brightness: 0.82, alpha: 1)
    }
}
