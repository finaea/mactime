import AppKit

/// The app list behind the exclusion picker: what can be picked, what to call
/// it, and which apps are worth suggesting.
///
/// Picking, rather than typing: a bundle ID is not something a user should have
/// to know, and one typed with a typo excludes nothing while looking like it
/// excluded something.
enum ExcludedApps {
    struct App: Identifiable, Hashable {
        let bundleID: String
        let name: String
        var id: String { bundleID }
    }

    /// Apps most likely to be worth cutting out, offered once if they turn out
    /// to be installed. Suggested and not applied: excluding a user's messages
    /// without asking is its own surprise, and so is quietly deciding for them
    /// that a password manager is fine to photograph.
    static let sensitiveBundleIDs = [
        "com.1password.1password",            // 1Password 8
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "org.keepassxc.keepassxc",
        "org.whispersystems.signal-desktop",
        "com.apple.MobileSMS",                // Messages
    ]

    static func installed(_ bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    /// Falls back to the bundle ID, which is what an app that has since been
    /// uninstalled leaves behind. Its exclusion is kept either way — it may
    /// well come back, and dropping the entry silently would be worse.
    static func name(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return bundleID
        }
        return FileManager.default.displayName(atPath: url.path)
    }

    static func icon(for bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    /// Apps running right now with a user interface — agents and daemons have no
    /// windows to cut, and MacTime has nothing to hide from itself.
    static func running() -> [App] {
        let me = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let bundleID = app.bundleIdentifier, bundleID != me,
                      seen.insert(bundleID).inserted else { return nil }
                return App(bundleID: bundleID, name: app.localizedName ?? bundleID)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// An app picked out of the open panel — anything installed, not only what
    /// happens to be running while Settings is open.
    static func app(at url: URL) -> App? {
        guard let bundleID = Bundle(url: url)?.bundleIdentifier else { return nil }
        return App(bundleID: bundleID, name: FileManager.default.displayName(atPath: url.path))
    }

    static func named(_ bundleIDs: some Sequence<String>) -> [App] {
        bundleIDs.map { App(bundleID: $0, name: name(for: $0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func suggestions(alreadyExcluded: Set<String>) -> [App] {
        named(sensitiveBundleIDs.filter { !alreadyExcluded.contains($0) && installed($0) })
    }
}
