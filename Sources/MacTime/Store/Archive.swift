import Foundation

/// The export format: a zip of readable files, with no encryption of its own.
///
/// ## What "readable" means, and what it costs
///
/// The archive is plaintext by design. Its whole reason for existing is that a
/// user can leave MacTime — or survive MacTime leaving them — with their
/// history intact and openable by something else. An encrypted proprietary
/// archive would be lock-in wearing a security costume, and Rewind.ai's
/// shutdown is what happens to people who only had one.
///
/// The cost is stated rather than hidden: the file this produces is every
/// screenshot and every window title in the clear, and MacTime cannot follow it
/// once it is written. `Store.sweepExports` reaches the viewer's temp copies,
/// not a file the user placed on their Desktop. Both directions are gated by
/// Touch ID instead — see `ArchiveExport.run` and `ArchiveImport`.
///
/// ## Why JSON Lines and not one JSON array
///
/// `activity.jsonl` is unbounded. Screenshot retention caps captures at ninety
/// days, but `deleteSpans` is reachable only from the user's own "Delete data"
/// — the retention sweep passes `.capturesOnly` — so activity spans are **never
/// pruned**. Measured on a live store: 939 spans a day, so roughly 69 MB of
/// JSON after a year and 206 MB after three, growing for as long as the install
/// lives. One object per line is what lets both ends work a record at a time
/// instead of holding the whole history in memory. A newline inside a window
/// title is safe: JSON escapes it, so a record is always exactly one line.
enum Archive {

    /// Bumped when a reader would get the wrong answer from an older file.
    /// Version 1 is the first shipped format.
    static let schemaVersion = 1

    static let manifestEntry = "manifest.json"
    static let settingsEntry = "settings.json"
    static let spansEntry = "activity.jsonl"
    static let capturesEntry = "screenshots.jsonl"
    static let screenshotsPrefix = "screenshots"

    /// What the archive says about itself. Read — and checked — before the user
    /// is asked to confirm anything destructive.
    struct Manifest: Codable {
        var schema: Int
        var createdAt: Date
        var appVersion: String
        var captureCount: Int
        var spanCount: Int
        var firstRecord: Date?
        var lastRecord: Date?
    }

    /// One activity span. `title` and `url` are decrypted here — that is the
    /// point of the export — and re-sealed under the destination's key on the
    /// way back in.
    struct SpanRecord: Codable {
        var start: Date
        var end: Date
        var bundleId: String
        var appName: String
        var title: String?
        var url: String?
        var kind: String
    }

    /// One capture. Not redundant with the filename: `isActive` (which display
    /// held the focused window) and `displayId` have nowhere else to live, and a
    /// filename is the wrong place to encode a schema.
    ///
    /// Thumbnails are deliberately absent. They are derived, they would double
    /// the archive's entry count, and `ArchiveImport` regenerates them.
    struct CaptureRecord: Codable {
        var takenAt: Date
        var day: String
        var displayId: Int
        var isActive: Bool
        /// Archive-relative, always `screenshots/<day>/<name>.jpg`.
        var file: String
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    // ------------------------------------------------------------- settings

    /// The settings that travel with the history.
    ///
    /// Carrying these is not a convenience. Excluded apps is a *privacy*
    /// setting: history restored without it means MacTime quietly resumes
    /// capturing the password manager its owner had excluded.
    struct SettingsPayload: Codable {
        var excludedBundleIDs: [String]
        var excludedAppsReviewed: Bool
        var screenshotRetentionDays: Int
        var captureFullURLs: Bool
        var browserTrackingEnabled: Bool
        var requireAuthentication: Bool
        var idleThresholdSeconds: Double
        var screenshotIntervalSeconds: Double
        var screenshotQuality: Double
        var hoverPreviewOffsetX: Double
        var hoverPreviewOffsetY: Double
        var showAllDisplays: Bool

        static func current() -> SettingsPayload {
            SettingsPayload(
                excludedBundleIDs: Array(Settings.excludedBundleIDs).sorted(),
                excludedAppsReviewed: Settings.excludedAppsReviewed,
                screenshotRetentionDays: Settings.screenshotRetentionDays,
                captureFullURLs: Settings.captureFullURLs,
                browserTrackingEnabled: Settings.browserTrackingEnabled,
                requireAuthentication: Settings.requireAuthentication,
                idleThresholdSeconds: Settings.idleThresholdSeconds,
                screenshotIntervalSeconds: Settings.screenshotIntervalSeconds,
                screenshotQuality: Settings.screenshotQuality,
                hoverPreviewOffsetX: Settings.hoverPreviewOffsetX,
                hoverPreviewOffsetY: Settings.hoverPreviewOffsetY,
                showAllDisplays: Settings.showAllDisplays)
        }
    }

    /// What a key should be after an import, given both sides.
    ///
    /// Neither "replace" nor "merge" is right, because these keys are not one
    /// kind of thing. Three rules decide all of them, and the first two are the
    /// reason this is a function and not an assignment:
    ///
    /// 1. **An import may never weaken a privacy setting.** Replacing the
    ///    exclusion list would drop an app the user excluded on *this* Mac; a
    ///    union can only ever exclude more. The same logic makes `false` win for
    ///    the two "record less" toggles and `true` win for the lock.
    /// 2. **An import may never strand data outside the retention window.** An
    ///    archive holding ninety days landing in a fourteen-day store would lose
    ///    seventy-six of them at the next prune, so retention takes the larger.
    /// 3. **Machine-local state never travels at all** — `startAtLogin` is a
    ///    login-item registration, `paused`/`screenshotsEnabled` describe
    ///    recording here and now, and `lastExportedAt` must stay honest about
    ///    *this* Mac. None of them are in `SettingsPayload`, which is the
    ///    enforcement: a key that cannot be written down cannot be carried.
    ///
    /// Everything else takes the archive's value, which is the point of
    /// carrying settings at all.
    ///
    /// Written as a pure function over two payloads so the rule can be checked
    /// without a UserDefaults suite — see Tests/.
    static func merge(incoming: SettingsPayload, into local: SettingsPayload) -> SettingsPayload {
        SettingsPayload(
            excludedBundleIDs: Array(Set(local.excludedBundleIDs)
                .union(incoming.excludedBundleIDs)).sorted(),
            excludedAppsReviewed: local.excludedAppsReviewed || incoming.excludedAppsReviewed,
            screenshotRetentionDays: max(local.screenshotRetentionDays,
                                         incoming.screenshotRetentionDays),
            captureFullURLs: local.captureFullURLs && incoming.captureFullURLs,
            browserTrackingEnabled: local.browserTrackingEnabled && incoming.browserTrackingEnabled,
            requireAuthentication: local.requireAuthentication || incoming.requireAuthentication,
            idleThresholdSeconds: incoming.idleThresholdSeconds,
            screenshotIntervalSeconds: incoming.screenshotIntervalSeconds,
            screenshotQuality: incoming.screenshotQuality,
            hoverPreviewOffsetX: incoming.hoverPreviewOffsetX,
            hoverPreviewOffsetY: incoming.hoverPreviewOffsetY,
            showAllDisplays: incoming.showAllDisplays)
    }

    static func apply(_ payload: SettingsPayload) {
        Settings.setExcludedBundleIDs(payload.excludedBundleIDs)
        Settings.setExcludedAppsReviewed(payload.excludedAppsReviewed)
        Settings.d.set(payload.screenshotRetentionDays, forKey: Settings.Key.screenshotRetentionDays)
        Settings.d.set(payload.captureFullURLs, forKey: Settings.Key.captureFullURLs)
        Settings.d.set(payload.browserTrackingEnabled, forKey: Settings.Key.browserTrackingEnabled)
        Settings.d.set(payload.requireAuthentication, forKey: Settings.Key.requireAuthentication)
        Settings.d.set(payload.idleThresholdSeconds, forKey: Settings.Key.idleThresholdSeconds)
        Settings.d.set(payload.screenshotIntervalSeconds, forKey: Settings.Key.screenshotIntervalSeconds)
        Settings.d.set(payload.screenshotQuality, forKey: Settings.Key.screenshotQuality)
        Settings.d.set(payload.hoverPreviewOffsetX, forKey: Settings.Key.hoverPreviewOffsetX)
        Settings.d.set(payload.hoverPreviewOffsetY, forKey: Settings.Key.hoverPreviewOffsetY)
        Settings.d.set(payload.showAllDisplays, forKey: Settings.Key.showAllDisplays)
    }

    // ------------------------------------------------------------- errors

    enum Failure: LocalizedError {
        case encryptionUnavailable(String)
        case notEnoughSpace(needed: Int64, free: Int64)
        case unreadableManifest
        case unsupportedSchema(Int)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .encryptionUnavailable(let why):
                return why
            case .notEnoughSpace(let needed, let free):
                let f = ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)
                let g = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
                return "This needs about \(f) free and there is \(g)."
            case .unreadableManifest:
                return "That doesn't look like a MacTime export — its manifest is missing or unreadable."
            case .unsupportedSchema(let version):
                return "That export was written by a newer version of MacTime (format \(version)). "
                     + "Update MacTime and try again."
            case .cancelled:
                return "Cancelled."
            }
        }
    }

    /// Refuse rather than improvise when there is no key.
    ///
    /// Export would have nothing to decrypt with; import has to *seal* every
    /// capture and title it unpacks, and the two alternatives are both worse
    /// than stopping. Writing plaintext into the store breaks the rule
    /// `Crypto.resolve` spells out — "no key means no writing, not plaintext
    /// writing" — and minting a fresh key makes everything recorded before the
    /// import permanently unreadable the moment the real key comes back.
    ///
    /// Refusing costs nothing: the archive is still on disk and the store is
    /// untouched, so fixing the keychain and trying again is the whole recovery.
    /// `Crypto.unavailableReason` already names the specific cause and already
    /// says that nothing has been deleted, so it is surfaced verbatim.
    static func requireKey(_ crypto: Crypto) throws {
        guard !crypto.isReady else { return }
        throw Failure.encryptionUnavailable(
            crypto.unavailableReason ?? "MacTime's encryption key isn't available.")
    }

    static func freeBytes(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? .max
    }
}
