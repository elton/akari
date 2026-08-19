import Foundation
import Security
import Testing
@testable import AkariApp

// The credential store's semantics. No real credential appears here: every
// value is a literal, and the real Keychain is only touched by the opt-in test
// at the bottom.

@MainActor
@Suite("credential store")
struct KeychainTests {
    @Test("an absent item is unset, a zero-length one is cleared")
    func absentVersusEmpty() throws {
        let store = InMemoryCredentialStore()
        #expect(store.load(CredentialSlotID.dashscopeAPIKey) == .unset)

        try store.clear(CredentialSlotID.dashscopeAPIKey)
        // Not `.unset`: the difference is what tells the core to stop falling
        // back to `.env` (docs/protocol.md §8.2).
        #expect(store.load(CredentialSlotID.dashscopeAPIKey) == .cleared)

        try store.forget(CredentialSlotID.dashscopeAPIKey)
        #expect(store.load(CredentialSlotID.dashscopeAPIKey) == .unset)
    }

    @Test("saving a blank value clears rather than storing an empty secret")
    func blankSaveClears() throws {
        let store = InMemoryCredentialStore()
        try store.save(CredentialSlotID.huggingFaceToken, value: "   \n ")
        #expect(store.load(CredentialSlotID.huggingFaceToken) == .cleared)
    }

    @Test("values are trimmed on the way in, so they fingerprint like .env does")
    func trimsOnSave() throws {
        let store = InMemoryCredentialStore()
        try store.save(CredentialSlotID.cloudflareAPIToken, value: "  token-value\n")
        #expect(store.load(CredentialSlotID.cloudflareAPIToken) == .set("token-value"))
        // core/src/credentials.ts trims its `.env` side but not what the app
        // hands it; trimming here is what keeps the two fingerprints equal.
        #expect(store.load(CredentialSlotID.cloudflareAPIToken).fingerprint
                == CredentialFingerprint.of("token-value"))
    }

    @Test("a locked store answers denied, which is not the same as unset")
    func lockedIsDenied() throws {
        let store = InMemoryCredentialStore([CredentialSlotID.dashscopeAPIKey: "sk-test"])
        store.isLocked = true
        #expect(store.load(CredentialSlotID.dashscopeAPIKey) == .denied)
        #expect(store.load(CredentialSlotID.dashscopeAPIKey).wireState == "denied")
    }

    @Test("a refused write surfaces as an error instead of being swallowed")
    func writeFailurePropagates() {
        let store = InMemoryCredentialStore()
        store.writeFailure = errSecInteractionNotAllowed
        #expect(throws: CredentialStoreError.self) {
            try store.save(CredentialSlotID.dashscopeAPIKey, value: "sk-test")
        }
    }

    @Test("the four states map onto the wire strings the protocol names")
    func wireStates() {
        #expect(StoredCredential.set("x").wireState == "set")
        #expect(StoredCredential.cleared.wireState == "cleared")
        #expect(StoredCredential.unset.wireState == "unset")
        #expect(StoredCredential.denied.wireState == "denied")
        #expect(StoredCredential.set("x").value == "x")
        #expect(StoredCredential.cleared.value == nil)
    }

    @Test("printing a stored credential cannot leak it")
    func printingIsSafe() {
        let secret = "sk-do-not-print-1234567890"
        let stored = StoredCredential.set(secret)
        let printed = "\(stored) \(String(describing: stored)) \(String(reflecting: stored))"
        #expect(!printed.contains(secret))
        #expect(printed.contains(CredentialFingerprint.of(secret)))
    }

    @Test("the fingerprint is 8 hex of SHA-256, matching core/src/credentials.ts")
    func fingerprintShape() {
        // sha256("akari") — the same eight characters bun's createHash produces.
        let fingerprint = CredentialFingerprint.of("akari")
        #expect(fingerprint.count == 8)
        #expect(fingerprint.allSatisfy { $0.isHexDigit })
        #expect(CredentialFingerprint.of("akari") == fingerprint)
        #expect(CredentialFingerprint.of("akari ") != fingerprint)
    }

    @Test("the data protection probe can never delete a credential")
    func probeAccountIsNotACredentialSlot() {
        // The capability probe is a `SecItemDelete`. It is only harmless
        // because the account it names is one this app never writes.
        #expect(!CredentialSlotID.all.contains(KeychainCredentialStore.dataProtectionProbeAccount))
    }

    /// The real Keychain, off by default.
    ///
    /// It is skipped in `make check` on purpose: `SecItemAdd` from an unsigned
    /// `swift test` binary talks to the login keychain and can raise an access
    /// prompt, which in a test run means a hang, not a failure. Run it by hand
    /// with `AKARI_KEYCHAIN_TEST=1 swift test --filter realKeychain`; it uses its
    /// own service name and deletes what it wrote.
    @Test("the real Keychain round trips a value",
          .enabled(if: ProcessInfo.processInfo.environment["AKARI_KEYCHAIN_TEST"] == "1"))
    func realKeychain() throws {
        let service = "me.eltonzheng.akari.test.\(UUID().uuidString)"
        let store = KeychainCredentialStore(service: service)
        let slot = CredentialSlotID.cloudflareAccountID
        defer { try? store.forget(slot) }

        #expect(store.load(slot) == .unset)
        try store.save(slot, value: "account-id-value")
        #expect(store.load(slot) == .set("account-id-value"))
        try store.save(slot, value: "second-value")
        #expect(store.load(slot) == .set("second-value"))
        try store.clear(slot)
        #expect(store.load(slot) == .cleared)
        try store.forget(slot)
        #expect(store.load(slot) == .unset)
    }

    /// The header comment on `KeychainCredentialStore` claims
    /// `kSecAttrAccessible` is *requested* and only *enforced* on the data
    /// protection keychain. This checks that claim against the system instead
    /// of believing it: `pdmn` is the accessibility attribute, and the login
    /// keychain drops it without saying so — which is how a protection ends up
    /// documented, commented, and absent.
    ///
    /// Opt-in for the same reason as the test above.
    @Test("the accessibility class is real exactly where the code says it is",
          .enabled(if: ProcessInfo.processInfo.environment["AKARI_KEYCHAIN_TEST"] == "1"))
    func accessibilityMatchesTheKeychainInUse() throws {
        let service = "me.eltonzheng.akari.test.\(UUID().uuidString)"
        let store = KeychainCredentialStore(service: service)
        let slot = CredentialSlotID.cloudflareAccountID
        defer { try? store.forget(slot) }
        try store.save(slot, value: "account-id-value")

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: slot,
            kSecUseDataProtectionKeychain as String: KeychainCredentialStore.dataProtectionAvailable,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        #expect(SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess)
        let attributes = try #require(out as? [String: Any])
        #expect((attributes["pdmn"] != nil) == KeychainCredentialStore.dataProtectionAvailable)
    }
}
