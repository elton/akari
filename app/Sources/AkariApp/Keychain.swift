import CryptoKit
import Foundation
import Security
import os

private let keychainLog = Logger(subsystem: "me.eltonzheng.akari", category: "keychain")

/// What the app holds for one credential slot (docs/protocol.md §3.10 / §8.2).
///
/// The four cases are not synonyms and the difference is load-bearing on the
/// core side: `cleared` suppresses the `.env` fallback, `unset` and `denied`
/// let it through. Collapsing any two of them would either resurrect a
/// credential the user deleted here, or let a locked Keychain take the voice
/// session down with it.
enum StoredCredential: Equatable, Sendable {
    /// The Keychain holds a usable value.
    case set(String)
    /// The item exists with a zero-length value: the user emptied it here.
    case cleared
    /// No item. The slot was never configured in the app.
    case unset
    /// The Keychain could not be read (locked, refused, or corrupt).
    case denied

    /// `credentials.provide.values[].state` on the wire.
    var wireState: String {
        switch self {
        case .set: "set"
        case .cleared: "cleared"
        case .unset: "unset"
        case .denied: "denied"
        }
    }

    var value: String? {
        if case .set(let value) = self { return value }
        return nil
    }

    /// First 8 hex of SHA-256, or nil when there is no value. Comparable with
    /// the `fingerprint` the core reports in `settings.state`.
    var fingerprint: String? { value.map(CredentialFingerprint.of) }
}

/// Printing a credential must not print the credential. `\(stored)` reaching a
/// log or an error message is the accident this guards against — the same
/// discipline `CredentialValuePayload` applies on the wire side, and there is a
/// test for it.
extension StoredCredential: CustomStringConvertible, CustomDebugStringConvertible {
    var description: String {
        switch self {
        case .set: "set(fp \(fingerprint ?? "?"))"
        default: wireState
        }
    }

    var debugDescription: String { description }
}

/// SHA-256 prefix, shared with `fingerprint()` in core/src/credentials.ts.
///
/// A prefix of the hash rather than the last four characters of the value:
/// the last four characters *are* part of the credential, while 32 bits of
/// SHA-256 over a high-entropy key answer "did it change" and "are both sides
/// holding the same one" without handing out anything (docs/protocol.md §8.4).
enum CredentialFingerprint {
    static func of(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .prefix(4)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

enum CredentialStoreError: LocalizedError, CustomStringConvertible {
    case keychain(OSStatus)

    var description: String {
        switch self {
        case .keychain(let status):
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "未知错误"
            return "钥匙串操作失败（\(status)）：\(detail)"
        }
    }

    /// `LocalizedError`, not a `localizedDescription` property: the property
    /// on a bare `Error` is the one Foundation's bridging supplies, so a custom
    /// one is silently ignored the moment the value is held as `any Error`.
    var errorDescription: String? { description }
}

/// The credential storage the settings window and the `credentials.request`
/// answer both go through.
///
/// It is a protocol with two implementations for one reason: the real one talks
/// to the system Keychain, which a test cannot use without either writing to the
/// developer's login keychain or provoking an access prompt. Everything above
/// this line is then testable against `InMemoryCredentialStore`.
///
/// Main actor: every caller is UI or a control message already on the main
/// actor, and reads of this app's own `WhenUnlocked` items do not raise a
/// prompt, so there is nothing here worth an async hop.
@MainActor
protocol CredentialStore: AnyObject {
    func load(_ slot: String) -> StoredCredential
    /// Stores `value`. A blank value is stored as `clear()` — §8.4 treats
    /// all-whitespace as "没有", and an empty secret is never worth keeping.
    func save(_ slot: String, value: String) throws
    /// Writes a zero-length item: "the user emptied this here", which suppresses
    /// the `.env` fallback (§8.2).
    func clear(_ slot: String) throws
    /// Removes the item entirely, so the slot goes back to `unset` and the
    /// `.env` fallback applies again. This is the only way out of `cleared`.
    func forget(_ slot: String) throws
}

/// `kSecClassGenericPassword`, service = bundle id, account = slot name.
///
/// Accessibility is requested as `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`:
/// - *WhenUnlocked* rather than `AfterFirstUnlock` or `Always` — the core is
///   only ever launched by a logged-in, unlocked session, so nothing needs to
///   read these while the screen is locked. `kSecAttrAccessibleAlways` is both
///   deprecated and strictly wider than anything this app does.
/// - *ThisDeviceOnly* — these credentials configure the core **on this
///   machine**; syncing them to a device without akari installed produces a
///   second copy of a secret and no capability.
///
/// **Requested, not necessarily enforced.** `kSecAttrAccessible` is only a real
/// access control on the *data protection* keychain. On the login (file)
/// keychain the API accepts the attribute and drops it: the item reads back
/// with no `pdmn` at all, and what actually guards it is a per-app ACL keyed on
/// the code's designated requirement — which, for an unsigned / ad-hoc signed
/// build, changes on every rebuild and is worth close to nothing. Whether this
/// build gets the real thing is *measured*, not assumed, by
/// `dataProtectionAvailable`; the settings window says which one is in force.
final class KeychainCredentialStore: CredentialStore {
    /// = bundle id (docs/protocol.md §8.2). Hardcoded rather than read from
    /// `Bundle.main`: `swift run` has no bundle identifier, and a settings
    /// window that silently uses a different service in development would write
    /// credentials the bundled app cannot find.
    static let defaultService = "me.eltonzheng.akari"

    /// An account this app never writes, so the capability probe below can
    /// delete it without ever deleting anything.
    static let dataProtectionProbeAccount = "__akari.dataProtectionProbe"

    /// Whether the data protection keychain will accept this build. Measured
    /// once against the real Security framework, never assumed.
    ///
    /// **Why measure.** Everything `kSecAttrAccessible` promises depends on the
    /// answer, and on this build the answer is no: the data protection keychain
    /// needs a `keychain-access-groups` / `application-identifier` entitlement,
    /// which cannot be signed without an Apple Developer Team ID — the same
    /// blocker as the `codesign` peer check (docs/decisions.md「遗留」).
    /// Measured on the target machine: `SecItemAdd` with
    /// `kSecUseDataProtectionKeychain: true` answers `errSecMissingEntitlement`
    /// (-34018), and ad-hoc signing the entitlement in does not buy a way
    /// around it — the kernel SIGKILLs the process at exec.
    ///
    /// **Why a delete is the probe.** A read is useless here: a data protection
    /// query for an item that lives in the file keychain answers
    /// `errSecItemNotFound`, exactly like an unentitled process would be told,
    /// so it cannot tell the two apart. `SecItemDelete` does distinguish them
    /// (-34018 unentitled vs `errSecItemNotFound` entitled), and deleting an
    /// account nothing ever writes changes nothing in either case.
    static let dataProtectionAvailable: Bool = {
        let probe: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: defaultService,
            kSecAttrAccount as String: dataProtectionProbeAccount,
            kSecUseDataProtectionKeychain as String: true,
        ]
        let status = SecItemDelete(probe as CFDictionary)
        // Anything other than "nothing to delete" is treated as unavailable:
        // guessing "probably fine" is the failure mode this whole property
        // exists to remove.
        let available = status == errSecItemNotFound || status == errSecSuccess
        if available {
            keychainLog.notice("keychain: data protection keychain in use")
        } else {
            keychainLog.notice("""
                keychain: data protection keychain unavailable (\(status, privacy: .public)); \
                credentials go to the login keychain and kSecAttrAccessible is NOT enforced
                """)
        }
        return available
    }()

    private let service: String
    /// Captured per instance so one process cannot answer differently on two
    /// consecutive calls, and so the value that shaped the queries is the value
    /// the window reports.
    let usesDataProtection: Bool

    init(service: String = KeychainCredentialStore.defaultService,
         dataProtection: Bool = KeychainCredentialStore.dataProtectionAvailable) {
        self.service = service
        self.usesDataProtection = dataProtection
    }

    func load(_ slot: String) -> StoredCredential {
        var query = baseQuery(slot)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        switch status {
        case errSecSuccess:
            guard let data = out as? Data else {
                keychainLog.error("keychain item for \(slot, privacy: .public) is not data")
                return .denied
            }
            // Zero length is the tombstone: "user emptied this" (§8.2).
            if data.isEmpty { return .cleared }
            guard let text = String(data: data, encoding: .utf8) else {
                // Corrupt rather than absent. `denied` falls back to `.env` like
                // `unset` does, and is reported separately so the settings
                // window can explain the empty field instead of pretending the
                // slot was never configured.
                keychainLog.error("keychain item for \(slot, privacy: .public) is not UTF-8")
                return .denied
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .cleared : .set(text)
        case errSecItemNotFound:
            return .unset
        default:
            // Locked keychain, denied access, cancelled prompt — all the same
            // answer for the core: fall back, but say so.
            keychainLog.error("keychain read for \(slot, privacy: .public) failed: \(status)")
            return .denied
        }
    }

    func save(_ slot: String, value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // Trimmed before hashing and before sending, so a pasted key with a
        // trailing newline still fingerprints equal to the same key in `.env`
        // (the core trims its `.env` side but not what the app hands it).
        guard !trimmed.isEmpty else { return try clear(slot) }
        try write(slot, data: Data(trimmed.utf8))
    }

    func clear(_ slot: String) throws {
        try write(slot, data: Data())
    }

    func forget(_ slot: String) throws {
        let status = SecItemDelete(baseQuery(slot) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychain(status)
        }
    }

    private func write(_ slot: String, data: Data) throws {
        let query = baseQuery(slot)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        if data.isEmpty {
            // The tombstone cannot go in through `SecItemUpdate`: the login
            // keychain answers `errSecSuccess` and keeps the old bytes
            // (measured — `KeychainTests.realKeychain` catches it). Left as an
            // update, "清空" would report success, the item would still hold the
            // credential, `load` would answer `.set` instead of `.cleared`, and
            // the core would keep being handed the value the user just deleted
            // — with the `.env` suppression that `cleared` exists for
            // (docs/protocol.md §8.2) never happening. `SecItemAdd` does store
            // a zero-length value, so the tombstone is written as delete + add.
            let delete = SecItemDelete(query as CFDictionary)
            guard delete == errSecSuccess || delete == errSecItemNotFound else {
                throw CredentialStoreError.keychain(delete)
            }
        } else {
            let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if update == errSecSuccess { return }
            guard update == errSecItemNotFound else {
                throw CredentialStoreError.keychain(update)
            }
        }
        let add = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        guard add == errSecSuccess else {
            throw CredentialStoreError.keychain(add)
        }
    }

    /// Every query — read, write, update, delete — carries the same
    /// `kSecUseDataProtectionKeychain`. The two keychains are separate stores:
    /// a query for one does not see items in the other, so a single call that
    /// forgot the key would read `unset` for a slot that is set, and the app
    /// would answer `credentials.request` with "never configured".
    private func baseQuery(_ slot: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: slot,
            kSecUseDataProtectionKeychain as String: usesDataProtection,
        ]
    }
}

/// Test double. Also what the settings window falls back to if a Keychain is
/// genuinely unusable is *not* this — an unusable Keychain stays unusable and
/// says so; this type exists only for tests.
final class InMemoryCredentialStore: CredentialStore {
    /// nil = no item; empty = the zero-length tombstone.
    private var items: [String: Data] = [:]

    /// Every read answers `denied`, as a locked Keychain would.
    var isLocked = false
    /// Every write throws, as a refused Keychain would.
    var writeFailure: OSStatus?

    init(_ initial: [String: String] = [:]) {
        for (slot, value) in initial { items[slot] = Data(value.utf8) }
    }

    func load(_ slot: String) -> StoredCredential {
        if isLocked { return .denied }
        guard let data = items[slot] else { return .unset }
        guard let text = String(data: data, encoding: .utf8) else { return .denied }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .cleared : .set(text)
    }

    func save(_ slot: String, value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return try clear(slot) }
        if let writeFailure { throw CredentialStoreError.keychain(writeFailure) }
        items[slot] = Data(trimmed.utf8)
    }

    func clear(_ slot: String) throws {
        if let writeFailure { throw CredentialStoreError.keychain(writeFailure) }
        items[slot] = Data()
    }

    func forget(_ slot: String) throws {
        if let writeFailure { throw CredentialStoreError.keychain(writeFailure) }
        items.removeValue(forKey: slot)
    }
}
