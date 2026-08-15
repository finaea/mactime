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

    /// yyyy-MM-dd, local timezone. Used for screenshot day folders — sorts lexically.
    static let dayKey: DateFormatter = {
        let f = DateFormatter()
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
