import CryptoKit
import Foundation

/// AES-256-GCM at rest, for the screenshot files and — from the second half of
/// this change — the window titles and URLs in `activity_spans`.
///
/// The problem it exists for: `~/Library/Application Support/` is not covered by
/// TCC, and Screen Recording is. MacTime takes the most gated capability macOS
/// has and leaves the result somewhere any process running as the user reads
/// without a prompt, so a coding agent, an npm `postinstall` or commodity
/// malware gets a pixel-perfect replay of everything on screen without ever
/// asking for a permission. Encrypted, all it gets is ciphertext.
///
/// AES rather than ChaCha20 because the target is arm64-only: Apple silicon has
/// the ARMv8 crypto extensions, so AES runs in hardware at roughly 2 GB/s — a
/// 550 KB capture costs about 0.3 ms against the tens of ms its JPEG encode
/// already takes on the same queue. (ChaCha20 is the right answer for portable
/// code that cannot assume AES hardware. This isn't that.)
///
/// Deliberately *not* encrypted: `start`, `end`, `kind` and `app_bundle_id`, so
/// `appTotals` and `dayStats` stay one SQL statement each. The trade is worth
/// stating plainly rather than hiding: someone reading the database still
/// learns which apps were used when. They learn nothing about what was on the
/// screen, what the windows were called, or which pages were open.
final class Crypto: Sendable {

    // ------------------------------------------------------------- format

    /// `"MTC1"`, then CryptoKit's combined sealed box — a 12-byte nonce, the
    /// ciphertext, and a 16-byte authentication tag.
    ///
    /// The magic is what lets one read path serve both formats while the
    /// migration in `Rewrap` runs: a capture is either sealed or it is a JPEG
    /// that has not been reached yet, and a JPEG opens `FF D8 FF`, so no file
    /// can be mistaken for the other kind. It costs four bytes and removes the
    /// need for a second filename, a second column, or any state saying how far
    /// the migration got.
    static let magic = Data("MTC1".utf8)
    /// Nonce + tag. With the magic, 32 bytes per sealed value.
    private static let boxOverhead = 12 + 16

    /// The two rejections are not a judgement about how bad the damage is, and
    /// no caller tells them apart — every one of them collapses both to "this
    /// can't be read". Which one comes back is decided by *where* the damage
    /// is, because `open` checks the magic before it hands anything to GCM:
    /// corrupt the magic and it is turned away as `notSealed`; corrupt the
    /// nonce, the ciphertext or the tag and GCM rejects it as `corrupt`. What
    /// holds either way — and what actually matters — is that nothing tampered
    /// with ever opens to something.
    enum Failure: Error {
        /// No usable key — see `unavailableReason`. Never a reason to fall back
        /// to writing plaintext.
        case noKey
        /// Doesn't carry the magic, so it is either plaintext or too damaged to
        /// recognise. `openIfSealed` treats the first case as the ordinary one.
        case notSealed
        /// GCM said no: a flipped byte in the box, a truncated file, or the
        /// wrong key. Authenticated encryption makes those one answer, which is
        /// the point — there is no partial success to mistake for a result.
        case corrupt
    }

    // ------------------------------------------------------------- state

    private enum State {
        case ready(SymmetricKey)
        case unavailable(String)
    }
    private let state: State

    init(key: SymmetricKey) { state = .ready(key) }
    init(unavailable reason: String) { state = .unavailable(reason) }

    private var key: SymmetricKey? {
        if case .ready(let k) = state { return k }
        return nil
    }

    var isReady: Bool { key != nil }

    /// Why the key can't be used, for the banner in the day view and the log.
    /// nil when everything is fine.
    var unavailableReason: String? {
        if case .unavailable(let why) = state { return why }
        return nil
    }

    /// The process-wide instance, installed by `Store.init`. A static because
    /// the read path runs where a store reference doesn't reach — `ImageCache`
    /// is called from thumbnail cells that hold nothing but a path — and it
    /// matches how `Settings`, `Format` and `ImageCache` itself are already
    /// reached. The stand-in below is only ever live for the microseconds
    /// before the store is built, so a view rendering early says "unavailable"
    /// rather than trapping.
    nonisolated(unsafe) private(set) static var shared =
        Crypto(unavailable: "The data key hasn't been loaded yet.")

    static func install(_ crypto: Crypto) { shared = crypto }

    // ------------------------------------------------------------- seal / open

    func seal(_ plaintext: Data) throws -> Data {
        guard let key else { throw Failure.noKey }
        // A fresh random nonce per value, which CryptoKit picks. It is why
        // `titleTotals` can no longer GROUP BY in SQL: two spans on the same
        // page seal to different bytes.
        let box = try AES.GCM.seal(plaintext, using: key)
        guard let combined = box.combined else { throw Failure.corrupt }
        return Self.magic + combined
    }

    func open(_ data: Data) throws -> Data {
        guard let key else { throw Failure.noKey }
        guard Self.isSealed(data) else { throw Failure.notSealed }
        do {
            let box = try AES.GCM.SealedBox(combined: Data(data.dropFirst(Self.magic.count)))
            return try AES.GCM.open(box, using: key)
        } catch {
            throw Failure.corrupt
        }
    }

    /// The mixed-format read path: sealed values are opened, anything else is
    /// handed back untouched. Every screenshot read goes through this, because
    /// while `Rewrap` is working the same day folder holds both.
    func openIfSealed(_ data: Data) throws -> Data {
        Self.isSealed(data) ? try open(data) : data
    }

    static func isSealed(_ data: Data) -> Bool {
        data.count >= magic.count + boxOverhead && data.prefix(magic.count).elementsEqual(magic)
    }

    // ------------------------------------------------------------- key check

    /// Sealed under the key and written next to the database. Small, fixed, and
    /// carries nothing secret — its whole job is to answer two questions at
    /// launch that nothing else can: *has this store been encrypted before*,
    /// and *is the key we just fetched the one it was encrypted with*.
    static let checkFileName = "key-check"
    private static let checkPlaintext = Data("MacTime data key check v1".utf8)

    private func writeCheckFile(to url: URL) {
        guard let sealed = try? seal(Self.checkPlaintext) else { return }
        try? sealed.write(to: url, options: .atomic)
    }

    private func opensCheckFile(_ contents: Data) -> Bool {
        (try? open(contents)) == Self.checkPlaintext
    }

    // ------------------------------------------------------------- resolution

    /// What the key store had to say. The three cases are not interchangeable:
    /// `absent` means nothing has ever been stored, `failed` means something is
    /// stored and we could not have it (denied at the prompt, locked keychain,
    /// a signature the ACL no longer recognises). Minting a replacement is safe
    /// in the first case and catastrophic in the second, so they stay apart all
    /// the way through.
    enum Lookup {
        case found(SymmetricKey)
        case absent
        case failed(String)
    }

    /// Decide what state to come up in, given a key store and a data directory.
    ///
    /// Two rules, and both exist because the alternative destroys data:
    ///
    /// 1. **A new key is minted only when there is no check file.** If one
    ///    exists, this store has been written under a key, and every capture
    ///    and title in it is sealed with that key. Generating a fresh one there
    ///    would turn a recoverable problem — the key is in a backup, on the old
    ///    Mac, behind a keychain prompt the user dismissed — into permanent
    ///    loss, silently, while the app carried on looking healthy.
    /// 2. **No key means no writing, not plaintext writing.** Capture stops and
    ///    titles are dropped rather than stored in the clear. A privacy feature
    ///    that turns itself off when it hits trouble isn't one.
    ///
    /// Taking the key store as closures keeps the whole of this decision
    /// checkable without a Keychain — see Tests/.
    static func resolve(dataDir: URL,
                        lookup: () -> Lookup,
                        create: () -> Lookup) -> Crypto {
        let checkFile = dataDir.appendingPathComponent(checkFileName)
        let check = try? Data(contentsOf: checkFile)

        switch lookup() {
        case .found(let key):
            let crypto = Crypto(key: key)
            guard let check else {
                // A key with no check file. Either this store predates the file
                // or someone removed it; writing one for the key we already
                // hold is right in both, and refusing over a missing sentinel
                // would be its own way to brick a working install.
                crypto.writeCheckFile(to: checkFile)
                return crypto
            }
            guard crypto.opensCheckFile(check) else {
                return Crypto(unavailable:
                    "The key in your keychain doesn't match this MacTime data — it was "
                    + "encrypted with a different one. Nothing is being recorded, and nothing "
                    + "has been deleted.")
            }
            return crypto

        case .absent:
            guard check == nil else {
                return Crypto(unavailable:
                    "MacTime's data key is missing from your keychain, so the screenshots and "
                    + "titles already recorded can't be read and nothing new is being recorded. "
                    + "Restoring the keychain brings them back; Settings ▸ Delete data ▸ "
                    + "Everything starts fresh instead.")
            }
            switch create() {
            case .found(let key):
                let crypto = Crypto(key: key)
                crypto.writeCheckFile(to: checkFile)
                return crypto
            case .absent:
                return Crypto(unavailable: "Couldn't store a new data key in your keychain.")
            case .failed(let why):
                return Crypto(unavailable: why)
            }

        case .failed(let why):
            // Deliberately does *not* mint a replacement, whether or not a
            // check file exists: a keychain that is merely locked or a prompt
            // the user dismissed is a transient problem, and the next launch
            // should find the same data waiting.
            return Crypto(unavailable: why)
        }
    }
}
