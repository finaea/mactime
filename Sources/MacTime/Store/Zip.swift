import Foundation

/// The zip container, built by `/usr/bin/zip` and verified by reading its own
/// central directory back.
///
/// ## Why a subprocess and not a framework
///
/// There is no zip writer in Foundation and no libarchive in the SDK, so the
/// candidates were `/usr/bin/zip`, `ditto -c -k`, and
/// `NSFileCoordinator(.forUploading)`. `ditto` was measured writing
/// **spec-violating archives** past 65,535 entries: it wraps the 16-bit entry
/// count in the End of Central Directory record and emits no Zip64 record, so a
/// 70,001-entry archive reports 4,465 and a 140,004-entry one reports 8,932.
/// `unzip` recovers by walking the directory, but a reader that trusts the
/// count sees a fraction of the history — the worst possible failure for a
/// backup, because the archive still looks fine. MacTime reaches that size
/// easily: ~1,600 captures a day, so ~145,000 entries at the 90-day setting.
///
/// `zip` wrote the sentinel and the Zip64 record correctly at the same size, and
/// macOS's own unarchiver read it back complete.
///
/// ## Why `-g`
///
/// `-g` grows the archive in place, and the cost tracks the bytes added rather
/// than the archive's size — measured at 16.8s to append 1 GB to a 12 MB
/// archive and 6.8s to append the same 1 GB to a 1 GB one. That is what lets
/// export decrypt one day at a time and delete each day's plaintext before
/// starting the next, instead of materialising the whole store in the clear and
/// compressing it afterwards.
enum Zip {

    enum Failure: LocalizedError {
        case toolFailed(String, Int32)
        case notAZip
        case truncated
        case missingEntries([String])
        case unexpectedEntries([String])
        case duplicateEntries([String])

        var errorDescription: String? {
            switch self {
            case .toolFailed(let tool, let code):
                return "\(tool) exited with code \(code)."
            case .notAZip:
                return "That file isn't a zip archive."
            case .truncated:
                return "The archive is incomplete — it may have been cut short while it was written or copied."
            case .missingEntries(let names):
                return "The archive is missing \(names.count) file\(names.count == 1 ? "" : "s") it should contain."
            case .unexpectedEntries(let names):
                return "The archive holds \(names.count) file\(names.count == 1 ? "" : "s") it should not."
            case .duplicateEntries(let names):
                return "The archive names \(names.count) file\(names.count == 1 ? "" : "s") more than once."
            }
        }
    }

    // ------------------------------------------------------------- writing

    /// Append `paths` (relative to `directory`) to `archive`.
    ///
    /// `-D` skips directory entries — `unzip` recreates the tree from the file
    /// paths anyway, and at 90 days of captures that is ninety entries of
    /// nothing. `-X` drops the extra attribute fields for the same reason.
    static func append(_ paths: [String], from directory: URL, to archive: URL,
                       compress: Bool) throws {
        guard !paths.isEmpty else { return }
        var args = ["-q", "-r", "-D", "-X", compress ? "-9" : "-0"]
        // `-g` only once there is something to grow; on a fresh path it has
        // nothing to append to.
        if FileManager.default.fileExists(atPath: archive.path) { args.append("-g") }
        args.append(archive.path)
        args.append(contentsOf: paths)
        try run("/usr/bin/zip", args, in: directory)
    }

    // ------------------------------------------------------------- reading

    /// Extract the whole archive into `destination`.
    ///
    /// `unzip` verifies every entry's CRC as it writes it and exits non-zero if
    /// any of them fails, which is where import gets its integrity check — and
    /// it happens on the way into staging, before anything destructive.
    static func extract(_ archive: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try run("/usr/bin/unzip", ["-q", "-o", archive.path, "-d", destination.path],
                in: destination)
    }

    /// One entry's bytes, without unpacking the rest — how the manifest is read
    /// before the user is asked to confirm anything.
    static func read(_ entry: String, from archive: URL) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", archive.path, entry]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure.toolFailed("unzip", process.terminationStatus)
        }
        return data
    }

    private static func run(_ tool: String, _ args: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        // Every non-zero exit is a failure, including `zip`'s warning codes: a
        // file it could not read is a capture missing from the backup, which is
        // exactly the thing that must not pass silently.
        guard process.terminationStatus == 0 else {
            throw Failure.toolFailed((tool as NSString).lastPathComponent, process.terminationStatus)
        }
    }

    // ------------------------------------------------------------- verifying

    /// Every entry name in the archive, read from its central directory.
    ///
    /// Deliberately not `unzip -l` parsing: this reads the structure the format
    /// actually defines, follows the Zip64 records when the 32-bit fields are
    /// saturated, and walks exactly the declared directory length — so a
    /// truncated archive is caught rather than silently under-reported, which is
    /// the failure `ditto` produces and the one this guards against.
    static func entryNames(in archive: URL) throws -> [String] {
        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()

        // The EOCD sits within 64 KB of the end (its comment field is 16-bit).
        let tailLength = Int(min(size, 66_560))
        try handle.seek(toOffset: size - UInt64(tailLength))
        let tail = try handle.read(upToCount: tailLength) ?? Data()
        guard let eocd = lastIndex(of: [0x50, 0x4B, 0x05, 0x06], in: tail) else { throw Failure.notAZip }

        var total = Int(u16(tail, eocd + 10))
        var cdSize = Int(u32(tail, eocd + 12))
        var cdOffset = UInt64(u32(tail, eocd + 16))

        // 0xFFFF / 0xFFFFFFFF are sentinels meaning "read the Zip64 record".
        if total == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF {
            guard let locator = lastIndex(of: [0x50, 0x4B, 0x06, 0x07], in: tail) else {
                throw Failure.truncated
            }
            let z64Offset = u64(tail, locator + 8)
            try handle.seek(toOffset: z64Offset)
            guard let header = try handle.read(upToCount: 56), header.count == 56,
                  header.prefix(4).elementsEqual([0x50, 0x4B, 0x06, 0x06]) else {
                throw Failure.truncated
            }
            total = Int(u64(header, 32))
            cdSize = Int(u64(header, 40))
            cdOffset = u64(header, 48)
        }

        guard cdOffset + UInt64(cdSize) <= size else { throw Failure.truncated }
        try handle.seek(toOffset: cdOffset)
        guard let directory = try handle.read(upToCount: cdSize), directory.count == cdSize else {
            throw Failure.truncated
        }

        var names: [String] = []
        names.reserveCapacity(total)
        var cursor = 0
        while cursor + 46 <= directory.count {
            guard directory[directory.startIndex + cursor ..< directory.startIndex + cursor + 4]
                    .elementsEqual([0x50, 0x4B, 0x01, 0x02]) else { break }
            let nameLength = Int(u16(directory, cursor + 28))
            let extraLength = Int(u16(directory, cursor + 30))
            let commentLength = Int(u16(directory, cursor + 32))
            let nameStart = directory.startIndex + cursor + 46
            guard nameStart + nameLength <= directory.endIndex else { throw Failure.truncated }
            names.append(String(decoding: directory[nameStart ..< nameStart + nameLength], as: UTF8.self))
            cursor += 46 + nameLength + extraLength + commentLength
        }
        // The count the archive declares and the entries it actually carries
        // have to agree. They do not in a `ditto`-written archive past 65,535
        // entries, which is the whole reason this check exists.
        guard names.count == total else { throw Failure.truncated }
        return names
    }

    /// The archive holds exactly this set of names, each once.
    static func verify(_ archive: URL, holdsExactly expected: Set<String>) throws {
        let names = try entryNames(in: archive)
        var seen = Set<String>(), duplicates = Set<String>()
        for name in names where !seen.insert(name).inserted { duplicates.insert(name) }
        guard duplicates.isEmpty else { throw Failure.duplicateEntries(Array(duplicates).sorted()) }

        let missing = expected.subtracting(seen)
        guard missing.isEmpty else { throw Failure.missingEntries(Array(missing).sorted()) }
        let extra = seen.subtracting(expected)
        guard extra.isEmpty else { throw Failure.unexpectedEntries(Array(extra).sorted()) }
    }

    // ------------------------------------------------------------- bytes

    private static func lastIndex(of signature: [UInt8], in data: Data) -> Int? {
        guard data.count >= signature.count else { return nil }
        for i in stride(from: data.count - signature.count, through: 0, by: -1) {
            if data[data.startIndex + i ..< data.startIndex + i + signature.count]
                .elementsEqual(signature) { return i }
        }
        return nil
    }

    private static func u16(_ d: Data, _ at: Int) -> UInt16 {
        let b = d.startIndex + at
        return UInt16(d[b]) | UInt16(d[b + 1]) << 8
    }
    private static func u32(_ d: Data, _ at: Int) -> UInt32 {
        let b = d.startIndex + at
        return (0..<4).reduce(UInt32(0)) { $0 | UInt32(d[b + $1]) << (8 * UInt32($1)) }
    }
    private static func u64(_ d: Data, _ at: Int) -> UInt64 {
        let b = d.startIndex + at
        return (0..<8).reduce(UInt64(0)) { $0 | UInt64(d[b + $1]) << (8 * UInt64($1)) }
    }
}
