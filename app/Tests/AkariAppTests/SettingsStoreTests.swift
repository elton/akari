import Foundation
import Testing
@testable import AkariApp

// What the settings window decides, without a window, a Keychain or a core.
// Every credential here is a literal like "token-a"; nothing reads a real one.

@MainActor
private final class FakeEnvReader: EnvFileReading {
    var values: [String: String] = [:]
    var failure: (any Error)?
    private(set) var reads: [String] = []

    func value(forKey key: String, atPath path: String) throws -> String? {
        reads.append(key)
        if let failure { throw failure }
        return values[key]
    }
}

@MainActor
private struct Harness {
    let keychain = InMemoryCredentialStore()
    let env = FakeEnvReader()
    let store: SettingsStore
    private let box = SentBox()

    init(probeGrace: Duration = .seconds(60), keychainDataProtection: Bool = false) {
        // Passed explicitly so no unit test depends on the machine's Security
        // framework answering; the real measurement has its own opt-in test.
        store = SettingsStore(store: keychain, envReader: env,
                              keychainDataProtection: keychainDataProtection,
                              probeGrace: probeGrace)
        let box = self.box
        store.send = { box.messages.append($0) }
    }

    var sent: [ControlMessage] { box.messages }
    var sentTypes: [MessageType] { box.messages.map(\.body.type) }
    func reset() { box.messages.removeAll() }

    @MainActor final class SentBox { var messages: [ControlMessage] = [] }
}

@MainActor
private func stateMessage(credentials: [CredentialSlotStatePayload] = [],
                          routes: [RouteStatePayload] = [],
                          envPath: String = "/tmp/akari-test/.env") -> ControlMessage {
    ControlMessage(body: .settingsState(SettingsStatePayload(
        routes: routes,
        credentials: credentials,
        envFiles: [EnvFileStatePayload(path: envPath, loaded: true)])))
}

private func slotState(_ slot: String, source: String, present: Bool,
                       fingerprint: String? = nil, envVar: String) -> CredentialSlotStatePayload {
    CredentialSlotStatePayload(slot: slot, source: source, present: present,
                               fingerprint: fingerprint, envVar: envVar)
}

private let textRoute = RouteStatePayload(
    route: SettingsRoute.text,
    selected: ProviderID.auto,
    active: ProviderID.cloudflareWorkersAI,
    candidates: [
        ProviderHealthPayload(provider: ProviderID.cloudflareWorkersAI, status: "ok", checkedAt: 1),
        ProviderHealthPayload(provider: ProviderID.localMLX, status: "model_missing", checkedAt: 1),
    ])

@Suite("settings store")
@MainActor
struct SettingsStoreTests {
    // MARK: credentials.provide

    @Test("answers only the slots the request named, with the stored state")
    func answersRequestedSlots() {
        let harness = Harness()
        try? harness.keychain.save(CredentialSlotID.dashscopeAPIKey, value: "sk-a")
        try? harness.keychain.clear(CredentialSlotID.cloudflareAPIToken)

        let answer = harness.store.answer(CredentialsRequestPayload(
            requestId: "cr-1",
            slots: [CredentialSlotID.dashscopeAPIKey,
                    CredentialSlotID.cloudflareAPIToken,
                    CredentialSlotID.huggingFaceToken]))

        #expect(answer.requestId == "cr-1")
        #expect(answer.values.count == 3)
        #expect(answer.values[0].state == "set")
        #expect(answer.values[0].value == "sk-a")
        // Emptied here, so the core must not fall back to `.env` for it.
        #expect(answer.values[1].state == "cleared")
        #expect(answer.values[1].value == nil)
        #expect(answer.values[2].state == "unset")
        // The slot nobody asked about is not in the answer at all.
        #expect(!answer.values.contains { $0.slot == CredentialSlotID.cloudflareAccountID })
    }

    @Test("a slot name this build does not know is answered unset, not looked up")
    func unknownSlotIsUnset() {
        let harness = Harness()
        let answer = harness.store.answer(CredentialsRequestPayload(
            requestId: "cr-2", slots: ["../../etc/passwd"]))
        #expect(answer.values.count == 1)
        #expect(answer.values[0].state == "unset")
        #expect(answer.values[0].value == nil)
    }

    @Test("a locked Keychain answers denied, so the core falls back instead of losing voice")
    func lockedKeychainAnswersDenied() {
        let harness = Harness()
        try? harness.keychain.save(CredentialSlotID.dashscopeAPIKey, value: "sk-a")
        harness.keychain.isLocked = true

        let answer = harness.store.answer(CredentialsRequestPayload(
            requestId: "cr-3", slots: [CredentialSlotID.dashscopeAPIKey]))
        #expect(answer.values[0].state == "denied")
        #expect(answer.values[0].value == nil)
    }

    // MARK: rows and precedence

    @Test("the Keychain wins, and a different .env value is called out as ignored")
    func conflictIsVisible() {
        let harness = Harness()
        try? harness.keychain.save(CredentialSlotID.cloudflareAPIToken, value: "token-a")
        harness.env.values["CLOUDFLARE_API_TOKEN"] = "token-b"
        harness.store.handle(stateMessage(credentials: [
            slotState(CredentialSlotID.cloudflareAPIToken, source: "app", present: true,
                      fingerprint: CredentialFingerprint.of("token-a"),
                      envVar: "CLOUDFLARE_API_TOKEN"),
        ]))

        let row = harness.store.rows.first { $0.slot == CredentialSlotID.cloudflareAPIToken }
        #expect(row?.conflict == true)
        #expect(row?.effectiveSource == "app")
        #expect(row?.statusLine.contains("已被忽略") == true)
        // The losing value never appears, only the winner's fingerprint.
        #expect(row?.statusLine.contains("token-b") == false)
        #expect(row?.statusLine.contains("token-a") == false)
    }

    @Test("the same value in both places is not a conflict")
    func agreementIsNotConflict() {
        let harness = Harness()
        try? harness.keychain.save(CredentialSlotID.cloudflareAPIToken, value: "token-a")
        harness.env.values["CLOUDFLARE_API_TOKEN"] = "token-a"
        harness.store.handle(stateMessage())

        let row = harness.store.rows.first { $0.slot == CredentialSlotID.cloudflareAPIToken }
        #expect(row?.conflict == false)
        #expect(row?.agreesWithEnv == true)
        #expect(row?.statusLine.contains("相同") == true)
    }

    @Test("a slot only in .env offers an import and says where it comes from")
    func envOnlyOffersImport() {
        let harness = Harness()
        harness.env.values["DASHSCOPE_API_KEY"] = "sk-from-env"
        harness.store.handle(stateMessage(credentials: [
            slotState(CredentialSlotID.dashscopeAPIKey, source: "env", present: true,
                      fingerprint: CredentialFingerprint.of("sk-from-env"),
                      envVar: "DASHSCOPE_API_KEY"),
        ]))

        let row = harness.store.rows.first { $0.slot == CredentialSlotID.dashscopeAPIKey }
        #expect(row?.canImportFromEnv == true)
        #expect(row?.effectiveSource == "env")
        #expect(row?.statusLine.contains("DASHSCOPE_API_KEY") == true)
    }

    /// The failure docs/decisions.md spent an afternoon on: a shell profile
    /// exports the same variable, dotenv leaves it alone, and the program uses a
    /// credential nobody can see. The window used to answer "来自 .env 的
    /// CLOUDFLARE_API_TOKEN" — pointing at the file that lost.
    @Test("a shell-exported variable is named as such, not reported as .env")
    func shellEnvIsNotCalledDotEnv() {
        let harness = Harness()
        // `.env` holds A; the value the core actually resolved is B.
        harness.env.values["CLOUDFLARE_API_TOKEN"] = "token-a"
        harness.store.handle(stateMessage(credentials: [
            slotState(CredentialSlotID.cloudflareAPIToken, source: "env", present: true,
                      fingerprint: CredentialFingerprint.of("token-b"),
                      envVar: "CLOUDFLARE_API_TOKEN"),
        ]))

        let row = try! #require(harness.store.rows.first { $0.slot == CredentialSlotID.cloudflareAPIToken })
        #expect(row.shellShadowsEnvFile)
        #expect(row.statusLine.contains("shell"))
        #expect(!row.statusLine.contains("来自 .env"))
        // Both fingerprints, so the user can tell which value is which — and
        // neither of the values themselves.
        #expect(row.statusLine.contains(CredentialFingerprint.of("token-b")))
        #expect(row.statusLine.contains(CredentialFingerprint.of("token-a")))
        #expect(!row.statusLine.contains("token-a"))
        #expect(!row.statusLine.contains("token-b"))
    }

    @Test("a variable that is not in the .env at all is also the shell's")
    func shellEnvWithoutAnyEnvFileEntry() {
        let harness = Harness()
        // Nothing in the `.env` for this slot, yet the core resolved one.
        harness.store.handle(stateMessage(credentials: [
            slotState(CredentialSlotID.cloudflareAccountID, source: "env", present: true,
                      fingerprint: "aa11bb22", envVar: "CLOUDFLARE_ACCOUNT_ID"),
        ]))

        let row = harness.store.rows.first { $0.slot == CredentialSlotID.cloudflareAccountID }
        #expect(row?.shellShadowsEnvFile == true)
        #expect(row?.statusLine.contains("shell") == true)
        #expect(row?.statusLine.contains(".env 里没有这一项") == true)
    }

    @Test("the same value in the .env and in effect is not a shell override")
    func envFileAgreementIsNotShadowed() {
        let harness = Harness()
        harness.env.values["DASHSCOPE_API_KEY"] = "sk-from-env"
        harness.store.handle(stateMessage(credentials: [
            slotState(CredentialSlotID.dashscopeAPIKey, source: "env", present: true,
                      fingerprint: CredentialFingerprint.of("sk-from-env"),
                      envVar: "DASHSCOPE_API_KEY"),
        ]))

        let row = harness.store.rows.first { $0.slot == CredentialSlotID.dashscopeAPIKey }
        #expect(row?.shellShadowsEnvFile == false)
        #expect(row?.statusLine.contains("来自 .env") == true)
        #expect(row?.statusLine.contains("shell") == false)
    }

    @Test("an unreadable .env is not evidence of anything, so it raises no alarm")
    func unreadableEnvFileDoesNotAccuseTheShell() {
        let harness = Harness()
        harness.env.failure = CocoaError(.fileReadNoPermission)
        harness.store.handle(stateMessage(credentials: [
            slotState(CredentialSlotID.cloudflareAPIToken, source: "env", present: true,
                      fingerprint: "aa11bb22", envVar: "CLOUDFLARE_API_TOKEN"),
        ]))

        let row = harness.store.rows.first { $0.slot == CredentialSlotID.cloudflareAPIToken }
        #expect(row?.envRefusal != nil)
        #expect(row?.shellShadowsEnvFile == false)
        #expect(row?.statusLine.contains("shell") == false)
    }

    @Test("a locked Keychain plus a shell override says both things")
    func deniedAndShadowed() {
        let harness = Harness()
        harness.env.values["DASHSCOPE_API_KEY"] = "sk-from-env"
        harness.keychain.isLocked = true
        harness.store.handle(stateMessage(credentials: [
            slotState(CredentialSlotID.dashscopeAPIKey, source: "env", present: true,
                      fingerprint: CredentialFingerprint.of("sk-from-shell"),
                      envVar: "DASHSCOPE_API_KEY"),
        ]))

        let row = harness.store.rows.first { $0.slot == CredentialSlotID.dashscopeAPIKey }
        #expect(row?.stored == .denied)
        #expect(row?.statusLine.contains("钥匙串读不到") == true)
        #expect(row?.statusLine.contains("shell") == true)
    }

    @Test("the window is told which keychain is really in force")
    func keychainProtectionIsCarried() {
        #expect(Harness(keychainDataProtection: false).store.keychainDataProtection == false)
        #expect(Harness(keychainDataProtection: true).store.keychainDataProtection == true)
    }

    @Test("a cleared slot suppresses the fallback and offers to hand it back")
    func clearedSuppressesFallback() {
        let harness = Harness()
        harness.env.values["HF_TOKEN"] = "hf-from-env"
        harness.store.handle(stateMessage())
        harness.reset()

        harness.store.clear(slot: CredentialSlotID.huggingFaceToken)
        var row = harness.store.rows.first { $0.slot == CredentialSlotID.huggingFaceToken }
        #expect(row?.stored == .cleared)
        #expect(row?.canImportFromEnv == false)
        #expect(row?.canRestoreEnvFallback == true)
        // Already the tombstone: offering "清空" again would be a button that
        // does nothing.
        #expect(row?.canClear == false)
        #expect(row?.statusLine.contains("不会回退") == true)
        #expect(harness.sentTypes == [.credentialsUpdated])

        harness.store.restoreEnvFallback(slot: CredentialSlotID.huggingFaceToken)
        row = harness.store.rows.first { $0.slot == CredentialSlotID.huggingFaceToken }
        #expect(row?.stored == .unset)
        #expect(row?.canImportFromEnv == true)
    }

    @Test("a refused .env read is reported, not silently treated as absent")
    func envRefusalSurfaces() {
        let harness = Harness()
        harness.env.failure = EnvFileError.refused("不是普通文件（软链接也不行）")
        harness.store.handle(stateMessage())

        let row = harness.store.rows.first { $0.slot == CredentialSlotID.dashscopeAPIKey }
        #expect(row?.envFingerprint == nil)
        #expect(row?.envRefusal?.contains("软链接") == true)
    }

    // MARK: writes

    @Test("import copies from .env into the Keychain and tells the core which slot moved")
    func importFromEnv() {
        let harness = Harness()
        harness.env.values["CLOUDFLARE_ACCOUNT_ID"] = "account-123"
        harness.store.handle(stateMessage())
        harness.reset()

        harness.store.importFromEnv(slot: CredentialSlotID.cloudflareAccountID)

        #expect(harness.keychain.load(CredentialSlotID.cloudflareAccountID) == .set("account-123"))
        #expect(harness.sentTypes == [.credentialsUpdated])
        if case .credentialsUpdated(let payload)? = harness.sent.first?.body {
            #expect(payload.slots == [CredentialSlotID.cloudflareAccountID])
        } else {
            Issue.record("expected credentials.updated")
        }
        // `.env` is read-only to this app: `EnvFileReading` has no write at all.
        #expect(harness.env.reads.contains("CLOUDFLARE_ACCOUNT_ID"))
    }

    @Test("saving an unchanged value does not tell the core anything changed")
    func unchangedSaveIsSilent() {
        let harness = Harness()
        try? harness.keychain.save(CredentialSlotID.dashscopeAPIKey, value: "sk-a")
        harness.store.handle(stateMessage())
        harness.reset()

        harness.store.drafts[CredentialSlotID.dashscopeAPIKey] = "sk-a"
        let changed = harness.store.flushDrafts([CredentialSlotID.dashscopeAPIKey])

        // Re-announcing would make the core renew a live Realtime session to
        // arrive at exactly the same session (docs/protocol.md §8.5).
        #expect(changed.isEmpty)
        #expect(harness.sent.isEmpty)
    }

    @Test("an empty field means leave it alone, never clear it")
    func emptyDraftIsNoOp() {
        let harness = Harness()
        try? harness.keychain.save(CredentialSlotID.dashscopeAPIKey, value: "sk-a")
        harness.reset()

        harness.store.drafts[CredentialSlotID.dashscopeAPIKey] = "   "
        #expect(harness.store.flushDrafts([CredentialSlotID.dashscopeAPIKey]).isEmpty)
        #expect(harness.keychain.load(CredentialSlotID.dashscopeAPIKey) == .set("sk-a"))
    }

    @Test("a saved draft is wiped from memory once it is in the Keychain")
    func draftIsWiped() {
        let harness = Harness()
        harness.store.drafts[CredentialSlotID.cloudflareAPIToken] = "token-a"
        _ = harness.store.flushDrafts([CredentialSlotID.cloudflareAPIToken])
        #expect(harness.store.drafts[CredentialSlotID.cloudflareAPIToken] == "")
    }

    @Test("a Keychain that refuses the write reports it and stores nothing")
    func writeFailureIsReported() {
        let harness = Harness()
        harness.keychain.writeFailure = errSecInteractionNotAllowed
        harness.store.drafts[CredentialSlotID.dashscopeAPIKey] = "sk-a"

        #expect(harness.store.flushDrafts([CredentialSlotID.dashscopeAPIKey]).isEmpty)
        #expect(harness.keychain.load(CredentialSlotID.dashscopeAPIKey) == .unset)
        #expect(harness.store.notice?.isEmpty == false)
        #expect(harness.sent.isEmpty)
    }

    // MARK: routes and probing

    @Test("save-and-test saves, announces, then waits for settings.state before probing")
    func saveThenProbeOrder() {
        let harness = Harness()
        harness.store.coreConnected()
        harness.reset()

        harness.store.drafts[CredentialSlotID.cloudflareAPIToken] = "token-a"
        let group = SettingsStore.groups.first { $0.id == "cloudflare" }!
        harness.store.saveAndTest(group: group)

        // The probe tests what is *stored*, and the core only stores it after it
        // has asked for it — so probing here would test the old value.
        #expect(harness.sentTypes == [.credentialsUpdated])

        harness.store.handle(stateMessage(routes: [textRoute]))
        #expect(harness.sentTypes == [.credentialsUpdated, .settingsProbe])
        #expect(harness.store.probing.contains(SettingsRoute.text))
    }

    @Test("save-and-test with nothing changed probes straight away")
    func unchangedSaveProbesImmediately() {
        let harness = Harness()
        harness.store.coreConnected()
        harness.reset()

        let group = SettingsStore.groups.first { $0.id == "cloudflare" }!
        harness.store.saveAndTest(group: group)
        #expect(harness.sentTypes == [.settingsProbe])
    }

    @Test("a probe result clears the spinner and merges over the state's candidates")
    func probeResultMerges() {
        let harness = Harness()
        harness.store.coreConnected()
        harness.store.handle(stateMessage(routes: [textRoute]))
        harness.store.probe(route: SettingsRoute.text)
        #expect(harness.store.probing.contains(SettingsRoute.text))

        harness.store.handle(ControlMessage(body: .settingsProbeResult(
            SettingsProbeResultPayload(route: SettingsRoute.text, results: [
                ProviderHealthPayload(provider: ProviderID.cloudflareWorkersAI,
                                      status: "unauthorized",
                                      message: "token 只给了读取权限。",
                                      latencyMs: 120, checkedAt: 2),
            ]))))

        #expect(!harness.store.probing.contains(SettingsRoute.text))
        let merged = harness.store.candidates(for: SettingsRoute.text)
        #expect(merged.count == 2)
        #expect(merged[0].status == "unauthorized")
        // Untouched candidates keep whatever `settings.state` last said.
        #expect(merged[1].status == "model_missing")
        #expect(harness.store.notice?.contains("凭据被拒") == true)
    }

    @Test("picking the provider that is already selected sends nothing")
    func selectingTheSameProviderIsANoOp() {
        let harness = Harness()
        harness.store.coreConnected()
        harness.store.handle(stateMessage(routes: [textRoute]))
        harness.reset()

        harness.store.select(route: SettingsRoute.text, provider: ProviderID.auto)
        #expect(harness.sent.isEmpty)

        harness.store.select(route: SettingsRoute.text, provider: ProviderID.localMLX)
        #expect(harness.sentTypes == [.settingsSet])
    }

    @Test("connecting asks for the state; disconnecting keeps it but stops the spinners")
    func connectionLifecycle() {
        let harness = Harness()
        harness.store.coreConnected()
        #expect(harness.sentTypes == [.settingsGet])

        harness.store.handle(stateMessage(routes: [textRoute]))
        harness.store.probe(route: SettingsRoute.text)
        harness.store.coreDisconnected()

        #expect(harness.store.connected == false)
        #expect(harness.store.probing.isEmpty)
        // The last known picture is more use than a blank window.
        #expect(harness.store.route(SettingsRoute.text)?.active == ProviderID.cloudflareWorkersAI)
    }

    @Test("probing without a core says so instead of spinning")
    func probeWithoutCore() {
        let harness = Harness()
        harness.store.probe(route: SettingsRoute.text)
        #expect(harness.sent.isEmpty)
        #expect(harness.store.probing.isEmpty)
        #expect(harness.store.notice?.contains("没连上") == true)
    }

    @Test("messages that are not settings ones are left to the caller")
    func ignoresOtherMessages() {
        let harness = Harness()
        #expect(harness.store.handle(ControlMessage(body: .ping)) == false)
        // credentials.request is answered by the connection owner, not here.
        #expect(harness.store.handle(ControlMessage(body: .credentialsRequest(
            CredentialsRequestPayload(requestId: "cr-1", slots: [])))) == false)
    }
}
