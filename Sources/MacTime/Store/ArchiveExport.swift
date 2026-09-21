import Foundation

/// Writing the history out as a zip of readable files.
///
/// ## Why it publishes atomically
///
/// The archive is built as `.MacTime-<uuid>.partial` **beside** the destination
/// — same directory, so same volume, so the final swap is atomic — and moved
/// into place only after it verifies. Appending straight to the user's chosen
/// path has two failure modes that both look like success: a cancelled or
/// disk-full export leaves a partial file that reads as a backup, and because
/// NSSavePanel's "replace" hands back the URL without unlinking anything,
/// `zip -g` would append a second copy *into* the previous backup rather than
/// replacing it.
///
/// ## Why plaintext is only ever one day deep
///
/// Captures are sealed on disk, so exporting means decrypting them. Doing that
/// for the whole store before compressing would put a complete plaintext copy
/// of the history on disk for the length of the export — the exact thing
/// `Crypto`'s header exists to argue against — and need roughly twice the
/// store's size in free space. Instead each day is decrypted, appended, and
/// deleted before the next one starts, so the clear-text working set is about
/// 1,600 files rather than 145,000. The scratch directory lives under
/// `Store.exportDir`, which `Store.sweepExports` already empties at every
/// launch, so even a crash mid-export cannot leave it lying around for long.
enum ArchiveExport {

    struct Summary {
        let captures: Int
        let spans: Int
        let bytes: Int64
    }

    /// Progress as a fraction plus a line to show, and a cancel check consulted
    /// between days — never inside one, because a half-appended day would have
    /// to be unpicked from the archive.
    typealias Progress = @MainActor (Double, String) -> Void

    @MainActor
    static func run(store: Store, to destination: URL,
                    progress: @escaping Progress,
                    isCancelled: @escaping @MainActor () -> Bool) async throws -> Summary {
        try Archive.requireKey(store.crypto)

        let fm = FileManager.default
        let folder = destination.deletingLastPathComponent()
        let partial = folder.appendingPathComponent(".MacTime-\(UUID().uuidString).partial")
        let work = Store.exportDir.appendingPathComponent("export-\(UUID().uuidString)", isDirectory: true)

        // Both are scratch: neither survives this function, on any exit path.
        // The partial especially — a leftover dotfile in someone's Documents
        // folder is litter, and one that is half an archive is worse.
        defer {
            try? fm.removeItem(at: work)
            try? fm.removeItem(at: partial)
        }

        try fm.createDirectory(at: work, withIntermediateDirectories: true)

        // A rough ceiling: the sealed store is within a few percent of the
        // plaintext it came from, and the archive stores the JPEGs rather than
        // compressing them. Checked against the *destination's* volume, which is
        // the one that has to hold the result.
        let screenshots = store.screenshotsDir
        let needed = await Task.detached(priority: .utility) {
            directorySize(screenshots)
        }.value
        let free = Archive.freeBytes(at: folder)
        guard free > needed + 64 * 1024 * 1024 else {
            throw Archive.Failure.notEnoughSpace(needed: needed, free: free)
        }

        let capturesFile = work.appendingPathComponent(Archive.capturesEntry)
        let spansFile = work.appendingPathComponent(Archive.spansEntry)
        fm.createFile(atPath: capturesFile.path, contents: nil)
        fm.createFile(atPath: spansFile.path, contents: nil)

        var entries = Set([Archive.manifestEntry, Archive.settingsEntry,
                           Archive.spansEntry, Archive.capturesEntry])
        var captureCount = 0
        var firstRecord: Date?, lastRecord: Date?

        // ------------------------------------------------------- captures

        let days = store.captureDays()
        for (index, day) in days.enumerated() {
            if isCancelled() { throw Archive.Failure.cancelled }
            progress(Double(index) / Double(max(days.count, 1)) * 0.8, "Exporting \(day)…")

            let rows = store.capturesForExport(day: day)
            guard !rows.isEmpty else { continue }
            let crypto = store.crypto
            let written = try await Task.detached(priority: .utility) { () -> [Archive.CaptureRecord] in
                let dayDir = work.appendingPathComponent("\(Archive.screenshotsPrefix)/\(day)",
                                                         isDirectory: true)
                try fm.createDirectory(at: dayDir, withIntermediateDirectories: true)
                var records: [Archive.CaptureRecord] = []
                for row in rows {
                    let name = URL(fileURLWithPath: row.path).lastPathComponent
                    guard !name.isEmpty,
                          let sealed = try? Data(contentsOf: URL(fileURLWithPath: row.path)),
                          let plain = try? crypto.openIfSealed(sealed) else {
                        // A capture whose file is gone or will not open. Its row
                        // is skipped with it: an archive naming a file it does
                        // not carry would fail its own verification, and half a
                        // capture is not worth failing the whole export over.
                        NSLog("MacTime: export skipped unreadable capture %@", row.path)
                        continue
                    }
                    try plain.write(to: dayDir.appendingPathComponent(name), options: .atomic)
                    records.append(Archive.CaptureRecord(
                        takenAt: row.takenAt, day: day, displayId: row.displayID,
                        isActive: row.isActive,
                        file: "\(Archive.screenshotsPrefix)/\(day)/\(name)"))
                }
                return records
            }.value

            guard !written.isEmpty else { continue }
            try append(written, to: capturesFile)
            try Zip.append(["\(Archive.screenshotsPrefix)/\(day)"], from: work, to: partial,
                           compress: false)
            try fm.removeItem(at: work.appendingPathComponent("\(Archive.screenshotsPrefix)/\(day)"))

            captureCount += written.count
            for record in written {
                if firstRecord == nil || record.takenAt < firstRecord! { firstRecord = record.takenAt }
                if lastRecord == nil || record.takenAt > lastRecord! { lastRecord = record.takenAt }
            }
            entries.formUnion(written.map(\.file))
        }

        // ------------------------------------------------------- spans

        progress(0.85, "Exporting activity…")
        var spanCount = 0, cursor: Int64 = 0
        while true {
            if isCancelled() { throw Archive.Failure.cancelled }
            let page = store.spansForExport(after: cursor, limit: 2_000)
            guard !page.isEmpty else { break }
            cursor = page[page.count - 1].id
            let records = page.map(\.record)
            try append(records, to: spansFile)
            spanCount += records.count
            for record in records {
                if firstRecord == nil || record.start < firstRecord! { firstRecord = record.start }
                if lastRecord == nil || record.end > lastRecord! { lastRecord = record.end }
            }
            // The read is main-thread because `Store` is; the yield is what
            // keeps a million-span export from holding the run loop for its
            // whole length.
            await Task.yield()
        }

        // ------------------------------------------------------- metadata

        progress(0.9, "Finishing…")
        let manifest = Archive.Manifest(
            schema: Archive.schemaVersion, createdAt: Date(),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String ?? "unknown",
            captureCount: captureCount, spanCount: spanCount,
            firstRecord: firstRecord, lastRecord: lastRecord)
        let encoder = Archive.encoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: work.appendingPathComponent(Archive.manifestEntry))
        try encoder.encode(Archive.SettingsPayload.current())
            .write(to: work.appendingPathComponent(Archive.settingsEntry))

        // Deflated, unlike the JPEGs: these four are the only entries where
        // compression earns anything, and the two record streams are repetitive
        // enough to shrink a long way.
        try Zip.append([Archive.manifestEntry, Archive.settingsEntry,
                        Archive.spansEntry, Archive.capturesEntry],
                       from: work, to: partial, compress: true)

        // ------------------------------------------------------- verify, publish

        progress(0.95, "Verifying…")
        try Zip.verify(partial, holdsExactly: entries)
        // Read the manifest back out of the finished archive rather than
        // trusting the copy we just wrote: this is the last chance to notice
        // that what landed on disk is not what was encoded.
        guard let readBack = try? Zip.read(Archive.manifestEntry, from: partial),
              let checked = try? Archive.decoder().decode(Archive.Manifest.self, from: readBack),
              checked.captureCount == captureCount, checked.spanCount == spanCount else {
            throw Archive.Failure.unreadableManifest
        }

        let bytes = ((try? fm.attributesOfItem(atPath: partial.path)[.size]) as? Int64) ?? 0
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: partial)
        } else {
            try fm.moveItem(at: partial, to: destination)
        }

        // Only now. A `lastExportedAt` written before the archive is in place
        // would tell the user they have a backup they do not have — and this
        // number is load-bearing, because without a recovery code the export
        // *is* the backup strategy.
        Settings.setLastExportedAt(Date())
        progress(1, "Done.")
        return Summary(captures: captureCount, spans: spanCount, bytes: bytes)
    }

    // ------------------------------------------------------------- helpers

    /// Append records as JSON Lines — one object per line, encoded one at a
    /// time. Never an array: `activity_spans` is unbounded (see `Archive`), so
    /// a whole-document encoder would grow with the age of the install.
    private static func append<T: Encodable>(_ records: [T], to file: URL) throws {
        let encoder = Archive.encoder()
        var blob = Data()
        for record in records {
            blob.append(try encoder.encode(record))
            blob.append(0x0A)
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: blob)
    }

    /// Walks the whole capture tree, so it runs off the main thread: at the
    /// ninety-day setting that is ~145,000 `stat` calls, and doing them inline
    /// would freeze the Settings window before the save panel even appeared.
    private static func directorySize(_ url: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }
}
