import AppKit

/// Active-tab URL capture. Safari/Chromium via Apple Events (needs the per-browser
/// Automation permission, prompted on first use); Firefox via the AX tree fallback.
enum BrowserService {
    enum Kind {
        case appleEvents(script: String)
        case axTree
    }

    private static let browsers: [String: Kind] = [
        "com.apple.Safari": .appleEvents(script:
            #"tell application id "com.apple.Safari" to return URL of current tab of front window"#),
        "com.apple.SafariTechnologyPreview": .appleEvents(script:
            #"tell application id "com.apple.SafariTechnologyPreview" to return URL of current tab of front window"#),
        "com.google.Chrome": .appleEvents(script:
            #"tell application id "com.google.Chrome" to return URL of active tab of front window"#),
        "org.mozilla.firefox": .axTree,
    ]

    static func isBrowser(_ bundleId: String) -> Bool { browsers[bundleId] != nil }

    private static var scriptCache: [String: NSAppleScript] = [:]

    /// Main thread only (NSAppleScript requirement).
    static func activeURL(bundleId: String, pid: pid_t) -> String? {
        guard let kind = browsers[bundleId] else { return nil }
        switch kind {
        case .appleEvents(let source):
            let script: NSAppleScript
            if let cached = scriptCache[bundleId] {
                script = cached
            } else {
                guard let s = NSAppleScript(source: source) else { return nil }
                scriptCache[bundleId] = s
                script = s
            }
            var error: NSDictionary?
            let result = script.executeAndReturnError(&error)
            if error != nil { return nil } // no window, permission denied, …
            guard let url = result.stringValue, !url.isEmpty else { return nil }
            return url
        case .axTree:
            return AX.urlFromAXTree(pid: pid)
        }
    }
}
