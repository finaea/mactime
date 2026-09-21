import AppKit
import Foundation

/// Replacing this Mac's history with an archive's.
///
/// ## Why it ends in a relaunch
///
/// The commit exchanges two directories, and an exchanged directory does not
/// re-point an open SQLite connection — a handle held across the swap keeps
/// reading the inode it was opened on. There is no way to re-point it either:
/// `Store` holds `private let db`, both trackers hold `private let store`, and
/// four views hold `let store`. Rebuilding every one of them in place, while
/// `ActivityService` may still be holding a row id from the database that just
/// went away, is a large amount of risk for an operation that happens once per
/// laptop. Relaunching gives every view, tracker, connection and background
/// task a clean boundary for free.
///
/// ## Why the commit is an exchange and not an erase
///
/// `Erase.data(nil, nil, .capturesAndActivity)` would delete the live rows,
/// files and `key-check` *before* the replacement was live, so any failure
/// after it destroys the history with nothing to show for it. `RENAME_SWAP` is
/// a single atomic operation with no half-swapped state to recover from: the
/// old store is still whole on the other side of it, and stays there until the
/// new one has been opened and checked.
///
/// The marker outside both directories is what makes a crash in the gap
/// recoverable — without it, a launch could not tell which side of the exchange
/// it was on.
enum ArchiveImport {

    // ------------------------------------------------------------- reading

    struct Preview {
        let manifest: Archive.Manifest
        let settings: Archive.SettingsPayload
    }

    /// What the archive claims, read without unpacking it — so the counted
    /// confirmation can name both sides before anything is touched.
    static func preview(_ archive: URL) throws -> Preview {
        guard let manifestData = try? Zip.read(Archive.manifestEntry, from: archive),
              let manifest = try? Archive.decoder().decode(Archive.Manifest.self, from: manifestData)
        else { throw Archive.Failure.unreadableManifest }
        guard manifest.schema <= Archive.schemaVersion else {
            throw Archive.Failure.unsupportedSchema(manifest.schema)
        }
        let settingsData = try? Zip.read(Archive.settingsEntry, from: archive)
        let settings = settingsData
            .flatMap { try? Archive.decoder().decode(Archive.SettingsPayload.self, from: $0) }
            ?? Archive.SettingsPayload.current()
        return Preview(manifest: manifest, settings: settings)
    }

    // ------------------------------------------------------------- staging

    static func stagingURL(for store: Store) -> URL {
        store.dataDir.deletingLastPathComponent()
            .appendingPathComponent(store.dataDir.lastPathComponent + ".importing", isDirectory: true)
    }

    static func markerURL(for dataDir: URL) -> URL {
        dataDir.deletingLastPathComponent()
            .appendingPathComponent(dataDir.lastPathComponent + ".import-marker.json")
    }

    /// Unpack the archive into a sibling directory, sealed under *this* Mac's
    /// key. Nothing destructive happens here; the live store is untouched
    /// throughout, and a failure leaves only the staging directory to delete.
    @MainActor
    static func stage(store: Store, from archive: URL, preview: Preview,
                      progress: @escaping ArchiveExport.Progress,
                      isCancelled: @escaping @MainActor () -> Bool) async throws -> URL {
        try Archive.requireKey(store.crypto)

        let fm = FileManager.default
        let staging = stagingURL(for: store)
        let work = Store.exportDir.appendingPathComponent("import-\(UUID().uuidString)", isDirectory: true)
        try? fm.removeItem(at: staging)

        var succeeded = false
        defer {
            try? fm.removeItem(at: work)
            if !succeeded { try? fm.removeItem(at: staging) }
        }

        // Staging sits beside the live store, so the peak is both of them at
        // once. That is the price of the guarantee that a failed import leaves
        // the existing history whole.
        let archiveSize = ((try? fm.attributesOfItem(atPath: archive.path)[.size]) as? Int64) ?? 0
        let needed = archiveSize * 2
        let free = Archive.freeBytes(at: store.dataDir)
        guard free > needed + 64 * 1024 * 1024 else {
            throw Archive.Failure.notEnoughSpace(needed: needed, free: free)
        }

        progress(0.05, "Reading the archive…")
        // `unzip` checks every entry's CRC as it extracts and exits non-zero if
        // one fails. That is the integrity check, and it runs here — before
        // anything of the user's is at risk.
        try await Task.detached(priority: .utility) { try Zip.extract(archive, to: work) }.value
        if isCancelled() { throw Archive.Failure.cancelled }

        try fm.createDirectory(at: staging.appendingPathComponent("Screenshots", isDirectory: true),
                               withIntermediateDirectories: true)

        // The staged store seals with the *destination's* key, which is what
        // makes the imported history readable here afterwards.
        let staged = Store(directory: staging, crypto: store.crypto)
        defer { staged.close() }

        // ------------------------------------------------------- captures

        progress(0.2, "Restoring screenshots…")
        let captures = try records(Archive.CaptureRecord.self,
                                   from: work.appendingPathComponent(Archive.capturesEntry))
        let crypto = store.crypto
        var restored = 0
        for chunk in stride(from: 0, to: captures.count, by: 200).map({
            Array(captures[$0 ..< min($0 + 200, captures.count)])
        }) {
            if isCancelled() { throw Archive.Failure.cancelled }
            let written = try await Task.detached(priority: .utility) { () -> [(Archive.CaptureRecord, String, String)] in
                var out: [(Archive.CaptureRecord, String, String)] = []
                for record in chunk {
                    let source = work.appendingPathComponent(record.file)
                    guard let jpeg = try? Data(contentsOf: source) else { continue }
                    let dayDir = staging.appendingPathComponent("Screenshots/\(record.day)",
                                                                isDirectory: true)
                    try fm.createDirectory(at: dayDir, withIntermediateDirectories: true)
                    let base = URL(fileURLWithPath: record.file).deletingPathExtension().lastPathComponent
                    let full = dayDir.appendingPathComponent(base + ".jpg")
                    let thumb = dayDir.appendingPathComponent(base + ".thumb.jpg")
                    // Thumbnails are regenerated rather than carried: they are
                    // derived data, and shipping them would have doubled the
                    // archive's entry count for bytes the app can recompute.
                    guard let sealed = try? crypto.seal(jpeg) else { continue }
                    try sealed.write(to: full, options: .atomic)
                    if let image = Thumbnail.ofJPEG(jpeg),
                       let sealedThumb = try? crypto.seal(image) {
                        try sealedThumb.write(to: thumb, options: .atomic)
                    }
                    out.append((record, full.path, thumb.path))
                }
                return out
            }.value

            staged.inTransaction {
                for (record, path, thumbPath) in written {
                    staged.insertScreenshot(takenAt: record.takenAt, day: record.day,
                                            displayID: record.displayId, path: path,
                                            thumbPath: thumbPath, isActive: record.isActive)
                }
            }
            restored += written.count
            progress(0.2 + 0.6 * Double(restored) / Double(max(captures.count, 1)),
                     "Restoring screenshots… \(restored) of \(captures.count)")
        }

        // ------------------------------------------------------- spans

        progress(0.85, "Restoring activity…")
        var spansRestored = 0
        try eachRecordBatch(Archive.SpanRecord.self,
                            from: work.appendingPathComponent(Archive.spansEntry),
                            batch: 2_000) { batch in
            staged.inTransaction {
                for record in batch {
                    _ = staged.insertSpan(start: record.start, end: record.end,
                                          bundleId: record.bundleId, appName: record.appName,
                                          title: record.title, url: record.url,
                                          kind: SpanKind(rawValue: record.kind) ?? .active)
                }
            }
            spansRestored += batch.count
        }

        // ------------------------------------------------------- key-check

        // Carried across deliberately. The commit swaps whole directories, so
        // "leave the destination's alone" is not automatic — the live directory
        // and everything in it gets parked. The archive's own key-check is never
        // unpacked: it was sealed under the *source* Mac's key, and a store
        // holding one this Mac's key cannot open makes `Crypto.resolve` refuse
        // to record for good over data that is in fact perfectly fine.
        let liveCheck = store.dataDir.appendingPathComponent(Crypto.checkFileName)
        if fm.fileExists(atPath: liveCheck.path) {
            try? fm.copyItem(at: liveCheck,
                             to: staging.appendingPathComponent(Crypto.checkFileName))
        }

        NSLog("MacTime: staged import — %d captures, %d spans", restored, spansRestored)
        succeeded = true
        return staging
    }

    // ------------------------------------------------------------- commit

    /// Swap the staged directory in and relaunch.
    ///
    /// `teardown` stops the trackers and closes the live store. It runs *after*
    /// the marker is written and *before* the exchange, because everything
    /// between those two points has to be recoverable by the next launch.
    @MainActor
    static func commit(store: Store, staging: URL, incoming: Archive.SettingsPayload,
                       expected: Archive.Manifest, teardown: () -> Void) throws {
        let marker = Marker(schema: Archive.schemaVersion,
                            dataDir: store.dataDir.path,
                            parked: staging.path,
                            expectedCaptures: expected.captureCount,
                            expectedSpans: expected.spanCount,
                            settings: incoming)
        let markerFile = markerURL(for: store.dataDir)
        try Archive.encoder().encode(marker).write(to: markerFile, options: .atomic)

        CaptureSuspension.begin()
        teardown()

        do {
            try exchange(store.dataDir, staging)
        } catch {
            // Nothing moved. Put everything back the way it was rather than
            // leaving a marker that would make the next launch believe an
            // import happened.
            try? FileManager.default.removeItem(at: markerFile)
            CaptureSuspension.end()
            throw error
        }

        relaunch()
    }

    /// One atomic directory exchange. After it, the data directory holds the
    /// imported store and `staging` holds the old one — which stays there until
    /// the next launch has opened the new one and found it sound.
    static func exchange(_ a: URL, _ b: URL) throws {
        let result = a.path.withCString { first in
            b.path.withCString { second in
                renamex_np(first, second, UInt32(RENAME_SWAP))
            }
        }
        guard result == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
                NSLocalizedDescriptionKey:
                    "Couldn't swap in the imported data: \(String(cString: strerror(errno))). "
                    + "Nothing has been deleted."])
        }
    }

    private static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL,
                                           configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    // ------------------------------------------------------------- recovery

    struct Marker: Codable {
        var schema: Int
        var dataDir: String
        var parked: String
        var expectedCaptures: Int
        var expectedSpans: Int
        var settings: Archive.SettingsPayload
    }

    /// Finish — or undo — an import that was committed before this launch.
    ///
    /// Called before the `Store` is built, and deliberately without one: it
    /// opens the database directly, so none of `Store.init`'s side effects
    /// (installing the shared `Crypto`, starting `Rewrap`, sweeping exports) run
    /// against a store that might be about to be swapped back out.
    @discardableResult
    static func resumePending(dataDir: URL) -> Bool {
        let fm = FileManager.default
        let markerFile = markerURL(for: dataDir)
        guard let data = try? Data(contentsOf: markerFile),
              let marker = try? Archive.decoder().decode(Marker.self, from: data) else { return false }

        let parked = URL(fileURLWithPath: marker.parked)
        if soundAfterImport(dataDir: dataDir, marker: marker) {
            // Settings are applied only now, on the far side of a store that
            // opened and counted correctly — never before the exchange, where a
            // rollback would leave this Mac wearing the archive's preferences
            // over its own history.
            Archive.apply(Archive.merge(incoming: marker.settings,
                                        into: Archive.SettingsPayload.current()))
            try? fm.removeItem(at: parked)
            try? fm.removeItem(at: markerFile)
            NSLog("MacTime: import completed — %d captures, %d spans",
                  marker.expectedCaptures, marker.expectedSpans)
            return true
        }

        NSLog("MacTime: imported store failed its check — rolling back")
        try? exchange(dataDir, parked)
        try? fm.removeItem(at: parked)
        try? fm.removeItem(at: markerFile)
        return false
    }

    /// Did the imported store arrive intact?
    ///
    /// Counts rather than a checksum: the archive was CRC-checked on the way
    /// into staging, so what is being tested here is that the *exchange* landed
    /// — a database that opens and holds the number of rows the manifest
    /// promised. A key-check has to be there too, because a store without one
    /// is a store a later launch could mint a fresh key over.
    private static func soundAfterImport(dataDir: URL, marker: Marker) -> Bool {
        guard FileManager.default.fileExists(
            atPath: dataDir.appendingPathComponent(Crypto.checkFileName).path) else { return false }
        let db = Database(path: dataDir.appendingPathComponent("MacTime.db").path)
        defer { db.close() }
        var captures = 0, spans = 0
        db.run("SELECT COUNT(*) FROM screenshots") { s in captures = Int(Database.int64(s, 0)) }
        db.run("SELECT COUNT(*) FROM activity_spans") { s in spans = Int(Database.int64(s, 0)) }

        // `<=` rather than `==`: export skips a capture whose file has gone
        // missing since its row was written, so a store can legitimately arrive
        // a little short of what the manifest counted. Holding *more* than the
        // archive described means this is not the store the import built.
        guard captures <= marker.expectedCaptures, spans <= marker.expectedSpans else { return false }
        // And an archive that carried something must not land as an empty
        // store — that is a database that opened but holds nothing, which is
        // the one "opens fine" outcome worth rolling back for.
        if marker.expectedCaptures + marker.expectedSpans > 0, captures + spans == 0 { return false }
        return true
    }

    // ------------------------------------------------------------- records

    private static func records<T: Decodable>(_ type: T.Type, from file: URL) throws -> [T] {
        var out: [T] = []
        try eachRecordBatch(type, from: file, batch: 4_000) { out.append(contentsOf: $0) }
        return out
    }

    /// Walk a JSON Lines file a batch at a time.
    ///
    /// Streamed because `activity.jsonl` has no ceiling — spans are never
    /// pruned — so a store a few years old can carry hundreds of megabytes of
    /// them. A blank line is skipped and a line that will not decode is logged
    /// and skipped: one unreadable record should cost that record, not the whole
    /// import.
    private static func eachRecordBatch<T: Decodable>(
        _ type: T.Type, from file: URL, batch size: Int, _ body: ([T]) throws -> Void
    ) throws {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? handle.close() }
        let decoder = Archive.decoder()
        var pending = Data()
        var batch: [T] = []
        batch.reserveCapacity(size)

        func drain(_ carryLast: Bool) throws {
            var lines = pending.split(separator: 0x0A, omittingEmptySubsequences: false)
            if carryLast, let last = lines.popLast() {
                pending = Data(last)
            } else {
                pending = Data()
            }
            for line in lines where !line.isEmpty {
                guard let record = try? decoder.decode(T.self, from: Data(line)) else {
                    NSLog("MacTime: import skipped an unreadable %@ record", "\(T.self)")
                    continue
                }
                batch.append(record)
                if batch.count >= size {
                    try body(batch)
                    batch.removeAll(keepingCapacity: true)
                }
            }
        }

        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            pending.append(chunk)
            try drain(true)
        }
        try drain(false)
        if !batch.isEmpty { try body(batch) }
    }
}
