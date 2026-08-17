import Foundation

/// UserDefaults-backed settings. Keys are shared with @AppStorage in SettingsView.
enum Settings {
    private static let d = UserDefaults.standard

    static func registerDefaults() {
        d.register(defaults: [
            Key.trackingEnabled: true,
            Key.browserTrackingEnabled: true,
            Key.idleThresholdSeconds: 300.0,
            Key.screenshotsEnabled: true,
            Key.screenshotIntervalSeconds: 15.0,
            Key.screenshotRetentionDays: 14,
            Key.screenshotQuality: 0.6,
            Key.hoverPreviewOffsetX: -8.0,
            Key.hoverPreviewOffsetY: -8.0,
            Key.showAllDisplays: false,
        ])
    }

    enum Key {
        /// false — show only the display that held the focused window.
        /// true  — show every display captured at that instant, side by side.
        static let showAllDisplays = "showAllDisplays"
        /// Offset from the pointer to the hover preview's BOTTOM-RIGHT corner.
        /// Anchoring that corner (rather than the top-left) keeps the box the
        /// same distance from the cursor whether or not it has a thumbnail in
        /// it — the two variants differ in size. Default -8,-8 = top-left tight.
        static let hoverPreviewOffsetX = "hoverPreviewOffsetX"
        static let hoverPreviewOffsetY = "hoverPreviewOffsetY"
        static let trackingEnabled = "trackingEnabled"
        static let browserTrackingEnabled = "browserTrackingEnabled"
        static let idleThresholdSeconds = "idleThresholdSeconds"
        static let screenshotsEnabled = "screenshotsEnabled"
        static let screenshotIntervalSeconds = "screenshotIntervalSeconds"
        static let screenshotRetentionDays = "screenshotRetentionDays"
        static let screenshotQuality = "screenshotQuality"
    }

    static var trackingEnabled: Bool { d.bool(forKey: Key.trackingEnabled) }
    static var browserTrackingEnabled: Bool { d.bool(forKey: Key.browserTrackingEnabled) }
    static var idleThresholdSeconds: Double { d.double(forKey: Key.idleThresholdSeconds) }
    static var screenshotsEnabled: Bool { d.bool(forKey: Key.screenshotsEnabled) }
    static var screenshotIntervalSeconds: Double { d.double(forKey: Key.screenshotIntervalSeconds) }
    static var screenshotRetentionDays: Int { d.integer(forKey: Key.screenshotRetentionDays) }
    static var screenshotQuality: Double { d.double(forKey: Key.screenshotQuality) }
    static var hoverPreviewOffsetX: Double { d.double(forKey: Key.hoverPreviewOffsetX) }
    static var hoverPreviewOffsetY: Double { d.double(forKey: Key.hoverPreviewOffsetY) }
    static var showAllDisplays: Bool { d.bool(forKey: Key.showAllDisplays) }
}
