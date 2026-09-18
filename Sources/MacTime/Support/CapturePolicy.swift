import Foundation

/// What a sample is allowed to say about the foreground app.
///
/// Pure and AppKit-free so `tools/run-tests.sh` can exercise it. The rules that
/// decide what reaches the database are worth a check; the AppKit calls that
/// gather the material aren't reachable from one, so they arrive as closures.
enum CapturePolicy {
    /// The window title and browser URL to record for `bundleId`.
    ///
    /// `read` runs only when the app isn't excluded, which is the difference
    /// between hiding something and collecting it and then throwing it away: an
    /// excluded app's title is never asked for, its Accessibility and Apple
    /// Events round-trips never happen, and nothing sensitive passes through
    /// memory on its way to being dropped.
    ///
    /// The app's *name* is deliberately not this function's business. An
    /// excluded app still shows up in the day's totals — it just stops saying
    /// what was on screen.
    ///
    /// What does survive is then held to `URLPolicy`: origin-only unless the
    /// user has asked for whole URLs.
    static func detail(for bundleId: String,
                       excludedBundleIDs: Set<String>,
                       fullURLs: Bool,
                       read: () -> (title: String?, url: String?)) -> (title: String?, url: String?) {
        guard !excludedBundleIDs.contains(bundleId) else { return (nil, nil) }
        let read = read()
        guard let raw = read.url else { return read }
        return (read.title, fullURLs ? raw : URLPolicy.origin(of: raw))
    }
}
