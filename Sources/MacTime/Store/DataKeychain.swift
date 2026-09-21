import CryptoKit
import Foundation
import Security

/// The data key, in the login keychain.
///
/// Compiled by tools/run-tests.sh but never called from it: the checks build
/// their own key and hand it to `Store`, because a test run must not read — or
/// worse, create — the key the real store is encrypted with.
///
/// ## Which keychain
///
/// The file keychain, not the data-protection one. That is not a preference:
/// `SecItemAdd` with `kSecUseDataProtectionKeychain` returns
/// `errSecMissingEntitlement` (-34018) here, because that keychain wants a
/// `keychain-access-groups` / `application-identifier` entitlement and those
/// need a Team ID. This app is signed with a self-made identity and has none.
///
/// ## Which access control, and why not a tighter one
///
/// The item gets the default ACL — the app that created it is trusted, matched
/// by its designated requirement — and deliberately nothing stricter.
///
/// The temptation is to pin the item to an exact code requirement. Read
/// tools/bundle-macos.sh before reaching for that: this app is self-signed, and
/// that script exists *because* rebuilding changes the signature and drops the
/// TCC grants. Pinning the key the same way means every rebuild orphans it, and
/// an orphaned key is not an inconvenience — it is every screenshot ever
/// captured, permanently unreadable. That is a far worse outcome than the
/// injection threat a tighter ACL would buy defence against — a threat the
/// hardened runtime (`--options runtime`, in tools/bundle-macos.sh) now takes
/// most of the cost out of anyway, since a process that could read the key from
/// this app's memory would no longer be able to get in there to try.
///
/// What the default ACL costs an attacker is still the thing that matters here:
/// another process reading the item gets a keychain prompt asking for the login
/// password, which is loud and refusable — as against the file store, which it
/// reads with no prompt at all. That gap is the whole finding.
///
/// So the two outcomes after a re-sign are:
///
/// - Signed with the stable "MacTime Dev" identity (tools/make-dev-identity.sh):
///   the designated requirement doesn't change across rebuilds, so nothing
///   prompts and nothing breaks.
/// - Signed ad-hoc: the cdhash changes every build, so macOS asks once per
///   build. "Always Allow" adds the new signature to the ACL. Data is never
///   lost either way — a dismissed prompt is `errSecAuthFailed`, which
///   `Crypto.resolve` treats as "come back later", never as "mint a new key".
///
/// ## What `ThisDeviceOnly` does and does not buy
///
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` keeps the key off iCloud
/// Keychain. It does **not** keep it out of backups, and it is worth being
/// precise about that rather than claiming otherwise: the attribute is a
/// data-protection-keychain concept, and this item is in the file keychain by
/// necessity (above). It lives in `~/Library/Keychains/login.keychain-db`, which
/// Migration Assistant and Time Machine both copy — which is exactly why
/// migrating a Mac carries the history across and a keychain restore brings it
/// back. What the attribute rules out is the key syncing to another machine
/// behind the user's back; moving it deliberately still works, and the README
/// says so.
///
/// Anyone wanting the history somewhere a keychain won't reach should use
/// Settings ▸ Backup ▸ Export — see `ArchiveExport`.
enum DataKeychain {
    private static let service = "MacTime"
    /// Versioned so a future key-rotation scheme can add one rather than
    /// overwrite the key three months of captures were sealed with.
    private static let account = "data-key-v1"

    private static var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecUseDataProtectionKeychain as String: false]
    }

    /// Fetched exactly once per launch, from `Store.init`, and held as a
    /// `SymmetricKey` for the life of the process. Never per file: this is an
    /// XPC round-trip to `securityd` costing ~2.5 ms on this machine, and at two
    /// files per capture it would dominate everything the encryption itself
    /// does by four orders of magnitude.
    static func load() -> Crypto.Lookup {
        var query = base
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, data.count == 32 else {
                return .failed("The data key in your keychain is damaged.")
            }
            return .found(SymmetricKey(data: data))
        case errSecItemNotFound:
            return .absent
        default:
            // Everything else — a dismissed prompt, a locked keychain, an ACL
            // that no longer recognises this build — is "not now", not "gone".
            // `Crypto.resolve` leans on that distinction.
            return .failed("Couldn't read MacTime's data key from your keychain: "
                           + message(status) + " Nothing is being recorded, and nothing "
                           + "already recorded has been deleted.")
        }
    }

    static func create() -> Crypto.Lookup {
        let key = SymmetricKey(size: .bits256)
        var add = base
        add[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        add[kSecAttrLabel as String] = "MacTime data key"
        add[kSecAttrDescription as String] = "Encrypts MacTime's screenshots, window titles and URLs"

        let status = SecItemAdd(add as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return .found(key)
        case errSecDuplicateItem:
            // Something stored one between the read and this write. Whatever it
            // holds is authoritative — the freshly minted key above is thrown
            // away rather than overwriting it.
            return load()
        default:
            return .failed("Couldn't store a new data key in your keychain: " + message(status))
        }
    }

    private static func message(_ status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "error \(status)."
    }
}

extension Crypto {
    /// The key for a real store: the login keychain's, resolved once.
    static func forLoginKeychain(dataDir: URL) -> Crypto {
        let crypto = resolve(dataDir: dataDir, lookup: DataKeychain.load, create: DataKeychain.create)
        if let why = crypto.unavailableReason {
            NSLog("MacTime: encryption unavailable — %@", why)
        }
        return crypto
    }
}
