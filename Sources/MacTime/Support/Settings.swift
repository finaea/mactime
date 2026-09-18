import Foundation

/// UserDefaults-backed settings. Keys are shared with @AppStorage in SettingsView.
enum Settings {
    /// `UserDefaults.standard` in the app. A `var` for the same reason
    /// `Store.init` takes a directory: the checks in Tests/ point this at a
    /// throwaway suite, because a check run must not read the user's real
    /// settings and must certainly not write them.
    nonisolated(unsafe) static var d = UserDefaults.standard

    static func registerDefaults() {
        d.register(defaults: [
            Key.trackingEnabled: true,
            Key.paused: false,
            Key.requireAuthentication: false,
            Key.browserTrackingEnabled: true,
            Key.captureFullURLs: false,
            Key.excludedBundleIDs: [String](),
            Key.excludedAppsReviewed: false,
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
        /// Recording paused by the user. Persisted, because in memory it meant
        /// a quit, a crash or a reboot silently resumed: pause for a sensitive
        /// call, reboot an hour later, and you are being recorded again with
        /// nothing anywhere saying so.
        static let paused = "paused"
        /// Ask for Touch ID or the login password before any MacTime window
        /// opens. Off by default — it gates *viewing*, never recording, and
        /// most people don't want a fingerprint between them and their own day.
        static let requireAuthentication = "requireAuthentication"
        static let browserTrackingEnabled = "browserTrackingEnabled"
        /// false — keep only a URL's origin (`https://mail.google.com`).
        /// true  — keep the whole thing, query string included. Opt-in, and off
        /// by default, because that query string is where the tokens live.
        static let captureFullURLs = "captureFullURLs"
        /// Apps whose windows are cut out of screenshots, and whose window
        /// titles and URLs are never recorded at all.
        static let excludedBundleIDs = "excludedBundleIDs"
        /// Whether the suggested exclusions have been answered. Accepting them
        /// and declining them are both answers, and both stop the asking.
        static let excludedAppsReviewed = "excludedAppsReviewed"
        static let idleThresholdSeconds = "idleThresholdSeconds"
        static let screenshotsEnabled = "screenshotsEnabled"
        static let screenshotIntervalSeconds = "screenshotIntervalSeconds"
        static let screenshotRetentionDays = "screenshotRetentionDays"
        static let screenshotQuality = "screenshotQuality"
    }

    static var trackingEnabled: Bool { d.bool(forKey: Key.trackingEnabled) }

    /// The one copy of the pause state. Both trackers read it rather than each
    /// keeping a flag, so a pause set anywhere is a pause everywhere — and it
    /// is still set on the next launch.
    static var paused: Bool { d.bool(forKey: Key.paused) }
    static func setPaused(_ paused: Bool) { d.set(paused, forKey: Key.paused) }

    static var requireAuthentication: Bool { d.bool(forKey: Key.requireAuthentication) }
    static var browserTrackingEnabled: Bool { d.bool(forKey: Key.browserTrackingEnabled) }
    static var captureFullURLs: Bool { d.bool(forKey: Key.captureFullURLs) }

    /// A set, because every sample and every capture round asks it a membership
    /// question. It lives in defaults as an array — `@AppStorage` cannot bind
    /// one of those, so the list is edited through `setExcludedBundleIDs`.
    static var excludedBundleIDs: Set<String> { Set(d.stringArray(forKey: Key.excludedBundleIDs) ?? []) }
    static func setExcludedBundleIDs(_ ids: [String]) { d.set(ids, forKey: Key.excludedBundleIDs) }

    static var excludedAppsReviewed: Bool { d.bool(forKey: Key.excludedAppsReviewed) }
    static func setExcludedAppsReviewed(_ reviewed: Bool) { d.set(reviewed, forKey: Key.excludedAppsReviewed) }
    static var idleThresholdSeconds: Double { d.double(forKey: Key.idleThresholdSeconds) }
    static var screenshotsEnabled: Bool { d.bool(forKey: Key.screenshotsEnabled) }
    static var screenshotIntervalSeconds: Double { d.double(forKey: Key.screenshotIntervalSeconds) }
    static var screenshotRetentionDays: Int { d.integer(forKey: Key.screenshotRetentionDays) }
    static var screenshotQuality: Double { d.double(forKey: Key.screenshotQuality) }
    static var hoverPreviewOffsetX: Double { d.double(forKey: Key.hoverPreviewOffsetX) }
    static var hoverPreviewOffsetY: Double { d.double(forKey: Key.hoverPreviewOffsetY) }
    static var showAllDisplays: Bool { d.bool(forKey: Key.showAllDisplays) }
}
