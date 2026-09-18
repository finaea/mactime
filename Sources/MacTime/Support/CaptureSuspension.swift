import Foundation

/// A hold on capture for the length of one operation. `Erase` takes one so a
/// capture round can't land a file — or a span — in a range it has just swept.
///
/// **This is not pause.** Pause is a statement by the user: it persists, it
/// changes the menu bar icon, and it outlives a restart. A suspension is
/// internal, lasts as long as the call that took it, shows nowhere, and leaves
/// nothing behind. Someone who paused before erasing is still paused after;
/// someone who did not is still recording after. Sharing `isPaused` for this
/// would have flipped the icon mid-erase and, on any exit path that forgot to
/// put it back, left the user silently paused forever.
///
/// Counted rather than a flag, because the daily retention sweep and a "Delete
/// data" from Settings can overlap — the first to finish must not release the
/// other's hold.
///
/// Pure Foundation on purpose: `Erase` is one of the files the checks in Tests/
/// compile, and the services are not.
enum CaptureSuspension {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var depth = 0

    static var isSuspended: Bool {
        lock.lock()
        defer { lock.unlock() }
        return depth > 0
    }

    /// Always paired with `end` through a `defer`, never by hand: an erase that
    /// returns early — nothing in range is the ordinary case for the retention
    /// sweep — must release exactly like one that runs to the bottom.
    static func begin() {
        lock.lock()
        defer { lock.unlock() }
        depth += 1
    }

    static func end() {
        lock.lock()
        defer { lock.unlock() }
        depth = max(0, depth - 1)
    }
}
