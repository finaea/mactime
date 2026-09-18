import Foundation

/// Bringing what was written before encryption under the key.
///
/// Sealing only new writes would leave everything already on disk in the clear
/// for up to a full retention window — fourteen days by default, ninety at the
/// top setting — which is most of what encrypting at rest was for. On the
/// machine this was written against that is 1.8 GB of plaintext captures from
/// three days of use. So every capture gets rewritten once, in the background.
///
/// **There is no progress file and nothing to resume from, on purpose.** What
/// decides whether an item still needs doing is the item itself: a capture that
/// starts with `Crypto.magic` is done, one that starts `FF D8 FF` is not.
/// Interrupting a pass — quit, crash, power loss — costs only the work it
/// hadn't reached, and the next launch picks up exactly where it stopped
/// without having to trust a counter that may not have been flushed. Each file
/// is replaced atomically, so the interruption can't land in the middle of one
/// either: what's on disk is the old plaintext or the new ciphertext, never
/// half of either.
///
/// Capture keeps running throughout, and the read path serves both formats
/// (`Crypto.openIfSealed`), so none of this is visible in the app beyond the
/// disk churn.
enum Rewrap {

    struct Summary {
        var sealed = 0
        /// Files that could not be rewritten. Left as they were — plaintext,
        /// and picked up again next launch — rather than half-written.
        var failed = 0
    }

    /// Start the migration for a store and return. Called once at launch.
    static func start(in store: Store) {
        let crypto = store.crypto
        // Without a key there is nothing to seal *with*, and the captures this
        // would rewrite are the plaintext ones — the only ones still readable.
        // Leaving them alone is the right move until a key comes back.
        guard crypto.isReady else { return }
        let dir = store.screenshotsDir
        let launchedAt = Date()

        Task.detached(priority: .utility) {
            let summary = await files(in: dir, using: crypto, writtenBefore: launchedAt)
            if summary.sealed + summary.failed > 0 {
                NSLog("MacTime: encrypted %d screenshot files written before encryption (%d failed)",
                      summary.sealed, summary.failed)
            }
        }
        // Separate task: the rows have to be done on the main thread, where
        // `Store` lives, while the files must not be. Neither waits on the
        // other — they touch nothing in common.
        Task { @MainActor in
            let sealed = await spans(in: store)
            guard sealed > 0 else { return }
            NSLog("MacTime: encrypted %d window titles and URLs written before encryption", sealed)
        }
    }

    /// Seal every title and URL still stored as plaintext.
    ///
    /// On the main thread because `Store` is, so the yield between batches is
    /// not a nicety: without it a store at the ninety-day setting would hold
    /// the run loop for as long as the whole rewrite takes. Each batch is its
    /// own transaction, so stopping between two of them leaves the database
    /// consistent and the next launch picks up the rest.
    @discardableResult
    @MainActor
    static func spans(in store: Store, batch: Int = 500,
                      pauseNanoseconds: UInt64 = 20_000_000) async -> Int {
        var total = 0
        while true {
            let sealed = store.sealPlaintextSpans(limit: batch)
            guard sealed > 0 else { return total }
            total += sealed
            try? await Task.sleep(nanoseconds: pauseNanoseconds)
        }
    }

    /// Seal every unsealed capture under `dir`.
    ///
    /// Utility QoS and off the main thread, with a pause every so often: this
    /// reads and rewrites gigabytes, and a launch that saturates the disk is
    /// its own kind of user-visible. The pauses roughly double the wall clock
    /// of a first run and cost nothing after it, since a second pass finds
    /// everything already sealed and writes nothing.
    @discardableResult
    static func files(in dir: URL, using crypto: Crypto, writtenBefore cutoff: Date,
                      pauseEvery: Int = 20,
                      pauseNanoseconds: UInt64 = 25_000_000) async -> Summary {
        await Task.detached(priority: .utility) { () -> Summary in
            var summary = Summary()
            for (index, url) in candidates(in: dir, writtenBefore: cutoff).enumerated() {
                // Gone since the walk: retention or an erase doing its job
                // while this runs. Not a failure, and not ours to report.
                guard let raw = try? Data(contentsOf: url) else { continue }
                guard !Crypto.isSealed(raw) else { continue }
                guard let sealed = try? crypto.seal(raw) else {
                    summary.failed += 1
                    continue
                }
                do {
                    try sealed.write(to: url, options: .atomic)
                    summary.sealed += 1
                } catch {
                    summary.failed += 1
                }
                if index % pauseEvery == pauseEvery - 1 {
                    try? await Task.sleep(nanoseconds: pauseNanoseconds)
                }
            }
            return summary
        }.value
    }

    /// The captures worth looking at, listed up front rather than walked lazily
    /// — `FileManager`'s enumerator can't be iterated from an async context,
    /// and a few thousand URLs is nothing next to the files they name.
    private static func candidates(in dir: URL, writtenBefore cutoff: Date) -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        var out: [URL] = []
        for case let url as URL in walker where url.pathExtension == "jpg" {
            // Anything written since launch came from `ScreenshotService.save`,
            // which seals before writing, so there is nothing here to do — and
            // skipping it keeps this pass away from a capture that may still be
            // arriving. Reading one half-written and sealing those bytes is the
            // one way this could actually destroy a capture rather than
            // postpone it.
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let modified, modified >= cutoff { continue }
            out.append(url)
        }
        return out
    }
}
