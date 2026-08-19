import Foundation
import Observation
import os

private let settingsLog = Logger(subsystem: "me.eltonzheng.akari", category: "settings")

/// One credential slot as the settings window sees it: what the Keychain holds,
/// what the core resolved, and — for the two things the wire cannot answer —
/// what `.env` holds, compared by fingerprint only.
struct CredentialRow: Equatable, Identifiable {
    var slot: String
    var envVar: String
    var stored: StoredCredential
    /// The core's own resolution for this slot; nil before the first
    /// `settings.state`.
    var core: CredentialSlotStatePayload?
    /// Fingerprint of the `.env` value, read locally. nil = no value there, or
    /// the file was not readable/allowed.
    var envFingerprint: String?
    /// Why the `.env` was not looked at, when it was not.
    var envRefusal: String?

    var id: String { slot }

    var title: String { SettingsStore.slotTitle(slot) }

    /// Which source is actually in effect. The core is authoritative because it
    /// is the one running inference; the local guess only covers the window
    /// before the first `settings.state` arrives.
    var effectiveSource: String {
        if let core { return core.source }
        switch stored {
        case .set: return "app"
        case .cleared: return "unset"
        case .unset, .denied: return envFingerprint == nil ? "unset" : "env"
        }
    }

    /// Both sides hold a value and they are *different* ones. This is the case
    /// `settings.state` cannot show on its own: it reports the winner, never the
    /// loser, so without the local `.env` read the ignored value would be
    /// invisible — which is precisely how a user ends up billing the wrong
    /// account and never finding out.
    var conflict: Bool {
        guard let mine = stored.fingerprint, let theirs = envFingerprint else { return false }
        return mine != theirs
    }

    var agreesWithEnv: Bool {
        guard let mine = stored.fingerprint, let theirs = envFingerprint else { return false }
        return mine == theirs
    }

    /// The core resolved this slot from the `env` tier, and the value actually
    /// in effect is provably **not** the one in the `.env` file.
    ///
    /// §8.4's `env` tier is `process.env`, and dotenv leaves an already-exported
    /// variable alone — so a shell profile that exports `CLOUDFLARE_API_TOKEN`
    /// silently outranks the `.env` sitting next to the repo. That is the
    /// afternoon recorded in docs/decisions.md ("curl 能跑、程序 401"): it looks
    /// exactly like a dead token, and it is real on this machine. The core warns
    /// about it in its startup log; this is the same fact in the one window
    /// whose entire fingerprint machinery exists for it.
    ///
    /// Two fingerprints are enough to prove it without either side sending a
    /// value: `core.fingerprint` is what is being used, `envFingerprint` is what
    /// the file says, and the app reads the file itself.
    var shellShadowsEnvFile: Bool {
        guard let core, core.source == "env", core.present else { return false }
        // The `.env` could not be read, so "it did not come from there" would be
        // a guess — and a guess is not worth an alarm on a screen about trust.
        guard envRefusal == nil else { return false }
        guard let effective = core.fingerprint else { return false }
        // No such variable in the `.env` the core loaded (or it loaded none):
        // then the environment is the only place the value can have come from.
        guard let file = envFingerprint else { return true }
        return effective != file
    }

    /// `.env` has it, the Keychain does not. The offer to copy it — never the
    /// copy itself.
    var canImportFromEnv: Bool {
        guard envFingerprint != nil else { return false }
        switch stored {
        case .unset: return true
        case .set, .cleared, .denied: return false
        }
    }

    /// Only a `cleared` slot needs the tombstone removed to get its `.env`
    /// fallback back.
    var canRestoreEnvFallback: Bool { stored == .cleared }

    /// Nothing to clear when the slot is already empty here — an unset slot has
    /// no item, and a cleared one is already the tombstone.
    var canClear: Bool {
        switch stored {
        case .set, .denied: true
        case .unset, .cleared: false
        }
    }

    /// The single line under the field. Says where the value comes from, and
    /// when two places disagree, which one lost.
    var statusLine: String {
        switch stored {
        case .denied:
            if shellShadowsEnvFile {
                return "钥匙串读不到（锁着或被拒）。core 回退到了 \(envVar)，"
                    + "而生效的那个值来自 shell 环境变量，不是 .env · 检查 shell 配置"
            }
            return "钥匙串读不到（锁着或被拒）。core 已回退 \(envVar)。"
        case .set(_):
            let fingerprint = stored.fingerprint ?? "?"
            if conflict {
                return "来自钥匙串 · 指纹 \(fingerprint) · .env 里的 \(envVar) 是另一个值，已被忽略"
            }
            if agreesWithEnv {
                return "来自钥匙串 · 指纹 \(fingerprint) · 与 .env 的 \(envVar) 相同"
            }
            return "来自钥匙串 · 指纹 \(fingerprint)"
        case .cleared:
            return "已在这里清空 · 不会回退 \(envVar)"
        case .unset:
            if shellShadowsEnvFile {
                // Deliberately not "来自 .env 的 X": that sentence is the bug.
                let suffix = core?.fingerprint.map { " · 指纹 \($0)" } ?? ""
                if let file = envFingerprint {
                    return "生效的 \(envVar) 来自 shell 环境变量\(suffix) · "
                        + ".env 里是另一个值（指纹 \(file)），已被忽略 · 检查你的 shell 配置"
                }
                return "生效的 \(envVar) 来自 shell 环境变量\(suffix) · "
                    + ".env 里没有这一项 · 检查你的 shell 配置"
            }
            if effectiveSource == "env" {
                let fingerprint = core?.fingerprint ?? envFingerprint
                let suffix = fingerprint.map { " · 指纹 \($0)" } ?? ""
                return "来自 .env 的 \(envVar)，没有存进钥匙串\(suffix)"
            }
            return "未配置 · 可以填在这里，或写进 .env 的 \(envVar)"
        }
    }
}

/// The credential fields that belong to one provider, and the route whose
/// "保存并测试" button they sit under.
struct CredentialGroup: Identifiable, Sendable {
    let id: String
    let title: String
    let slots: [String]
    /// Route to probe after saving. nil = nothing to test (the HF token is used
    /// when pulling weights, not by any provider at runtime).
    let route: String?
    let note: String
}

/// Everything the settings window knows, and everything it does.
///
/// The views are a function of this object; all the decisions live here so they
/// can be tested without a window, a Keychain or a core. The three injected
/// dependencies — credential store, `.env` reader, send closure — are the three
/// things a test cannot have for real.
@MainActor
@Observable
final class SettingsStore {
    private(set) var coreState: SettingsStatePayload?
    private(set) var connected = false
    private(set) var rows: [CredentialRow] = []
    /// Routes with a probe in flight, for the button spinners.
    private(set) var probing: Set<String> = []
    /// Last `settings.probeResult` per route. `settings.state` carries the
    /// durable picture; this is what the user just asked for.
    private(set) var lastProbe: [String: [ProviderHealthPayload]] = [:]
    /// One line of feedback for the last thing the user did.
    private(set) var notice: String?

    /// The first-run explanation, while it is still on screen.
    ///
    /// A banner inside this window rather than an `NSAlert` sheet. An
    /// `LSUIElement` app cannot take activation on macOS 26, so the window came
    /// up behind whatever the user was doing; the fix is to raise the window's
    /// level, and a banner is what survives that cleanly while sitting directly
    /// above the fields it is describing. See
    /// `AppDelegate.presentFirstRunOnboardingIfNeeded`.
    private(set) var onboarding: FirstRunOnboardingText?

    /// Called when the user dismisses the banner — the only evidence the
    /// explanation actually reached anybody. See `FirstRunOnboarding`.
    var onOnboardingDismissed: (() -> Void)?

    func presentOnboarding(_ text: FirstRunOnboardingText) {
        onboarding = text
    }

    func dismissOnboarding() {
        guard onboarding != nil else { return }
        onboarding = nil
        onOnboardingDismissed?()
    }

    /// Text fields. Empty means "leave this slot alone", never "clear it" —
    /// clearing is its own button, because the two must not be the same gesture.
    var drafts: [String: String] = [:]

    var send: ((ControlMessage) -> Void)?

    /// Whether the credential store behind this window actually gets the data
    /// protection keychain. The window says so out loud, because "已保存到钥匙串"
    /// promises more than an unsigned build can deliver
    /// (`KeychainCredentialStore.dataProtectionAvailable`).
    let keychainDataProtection: Bool

    private let store: any CredentialStore
    private let envReader: any EnvFileReading
    /// How long to wait for the `settings.state` that follows
    /// `credentials.updated` before probing anyway.
    private let probeGrace: Duration
    /// How long a probe may spin before the button is given back.
    private let probeTimeout: Duration

    private var pendingProbeRoute: String?
    private var graceTask: Task<Void, Never>?
    private var watchdogs: [String: Task<Void, Never>] = [:]

    init(store: any CredentialStore = KeychainCredentialStore(),
         envReader: any EnvFileReading = EnvFileReader(),
         keychainDataProtection: Bool = KeychainCredentialStore.dataProtectionAvailable,
         probeGrace: Duration = .seconds(3),
         probeTimeout: Duration = .seconds(20)) {
        self.store = store
        self.envReader = envReader
        self.keychainDataProtection = keychainDataProtection
        self.probeGrace = probeGrace
        self.probeTimeout = probeTimeout
        refreshRows()
    }

    // MARK: - Connection

    func coreConnected() {
        connected = true
        send?(ControlMessage(body: .settingsGet))
    }

    func coreDisconnected() {
        connected = false
        probing.removeAll()
        for task in watchdogs.values { task.cancel() }
        watchdogs.removeAll()
        graceTask?.cancel()
        graceTask = nil
        pendingProbeRoute = nil
        // `coreState` is kept on purpose: a stale picture with "core 未连接" on
        // top of it is more use than an empty window, and the credential rows
        // are still editable without a core.
    }

    // MARK: - Inbound

    /// Returns true when the message was a settings/credentials one and has been
    /// dealt with.
    @discardableResult
    func handle(_ message: ControlMessage) -> Bool {
        switch message.body {
        case .settingsState(let payload):
            coreState = payload
            refreshRows()
            // The probe deliberately waits for this: the core only applies a new
            // credential after asking for it, and probing in between would test
            // the value the user just replaced (docs/protocol.md §3.9).
            if let route = pendingProbeRoute {
                pendingProbeRoute = nil
                graceTask?.cancel()
                graceTask = nil
                sendProbe(route: route)
            }
            return true

        case .settingsProbeResult(let payload):
            lastProbe[payload.route] = payload.results
            probing.remove(payload.route)
            watchdogs.removeValue(forKey: payload.route)?.cancel()
            notice = Self.probeSummary(payload)
            return true

        case .credentialsRequest:
            // Answered by the caller, which owns the connection: the answer may
            // only go out on the app's own, SocketTrust-verified socket
            // (docs/protocol.md §3.10 rule 3).
            return false

        default:
            return false
        }
    }

    /// Build the one frame in the protocol that carries a secret.
    ///
    /// Only the slots the request named, and nothing else. A slot name this
    /// build does not know is answered `unset` rather than looked up: the
    /// account name would otherwise be attacker-chosen, and `unset` is the
    /// honest answer anyway ("never configured here").
    ///
    /// The result must not be logged at any level — `CredentialsProvidePayload`
    /// prints itself without the values so that `\(payload)` cannot leak.
    func answer(_ request: CredentialsRequestPayload) -> CredentialsProvidePayload {
        let values = request.slots.map { slot -> CredentialValuePayload in
            guard CredentialSlotID.all.contains(slot) else {
                settingsLog.warning("credentials.request names an unknown slot \(slot, privacy: .public)")
                return CredentialValuePayload(slot: slot, state: "unset")
            }
            let stored = store.load(slot)
            settingsLog.debug("credentials.request \(slot, privacy: .public) -> \(stored.wireState, privacy: .public)")
            return CredentialValuePayload(slot: slot, state: stored.wireState, value: stored.value)
        }
        return CredentialsProvidePayload(requestId: request.requestId, values: values)
    }

    // MARK: - Routes

    func route(_ id: String) -> RouteStatePayload? {
        coreState?.routes.first { $0.route == id }
    }

    /// The candidate rows to show: `settings.state` order, with any fresher
    /// `settings.probeResult` merged over it so a just-pressed test button
    /// updates the row it belongs to.
    func candidates(for route: String) -> [ProviderHealthPayload] {
        let base = self.route(route)?.candidates ?? []
        guard let fresh = lastProbe[route] else { return base }
        return base.map { candidate in
            fresh.first { $0.provider == candidate.provider } ?? candidate
        }
    }

    func select(route: String, provider: String) {
        guard provider != self.route(route)?.selected else { return }
        send?(ControlMessage(body: .settingsSet(SettingsSetPayload(route: route, provider: provider))))
    }

    func probe(route: String, provider: String? = nil) {
        sendProbe(route: route, provider: provider)
    }

    private func sendProbe(route: String, provider: String? = nil) {
        guard connected else {
            notice = "core 没连上，测不了。"
            return
        }
        probing.insert(route)
        send?(ControlMessage(body: .settingsProbe(
            SettingsProbePayload(route: route, provider: provider))))
        watchdogs.removeValue(forKey: route)?.cancel()
        watchdogs[route] = Task { [weak self, probeTimeout] in
            try? await Task.sleep(for: probeTimeout)
            guard !Task.isCancelled, let self else { return }
            guard self.probing.remove(route) != nil else { return }
            self.watchdogs.removeValue(forKey: route)
            // A button that spins forever is not a state the user can act on
            // (docs/protocol.md §3.9).
            self.notice = "\(SettingsDisplay.routeName(route))：探测没有回音。"
        }
    }

    // MARK: - Credentials

    /// Write every non-empty draft in the group, tell the core which slots moved,
    /// then test — in that order, because the probe tests what is *stored*, not
    /// what is typed (docs/protocol.md §3.9, "保存并测试").
    func saveAndTest(group: CredentialGroup) {
        let changed = flushDrafts(group.slots)
        guard let route = group.route else { return }
        if changed.isEmpty {
            sendProbe(route: route)
            return
        }
        pendingProbeRoute = route
        graceTask?.cancel()
        graceTask = Task { [weak self, probeGrace] in
            try? await Task.sleep(for: probeGrace)
            guard !Task.isCancelled, let self, let pending = self.pendingProbeRoute else { return }
            self.pendingProbeRoute = nil
            self.sendProbe(route: pending)
        }
    }

    /// Save without testing. Used for the slots no provider probes.
    func save(group: CredentialGroup) {
        _ = flushDrafts(group.slots)
    }

    /// Returns the slots whose stored value actually changed.
    @discardableResult
    func flushDrafts(_ slots: [String]) -> [String] {
        var changed: [String] = []
        var submitted = 0
        for slot in slots {
            let draft = (drafts[slot] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !draft.isEmpty else { continue }
            submitted += 1
            let before = store.load(slot).fingerprint
            do {
                try store.save(slot, value: draft)
            } catch {
                notice = "\(Self.slotTitle(slot))：\(error.localizedDescription)"
                settingsLog.error("keychain save failed for \(slot, privacy: .public)")
                continue
            }
            drafts[slot] = ""
            if store.load(slot).fingerprint != before { changed.append(slot) }
        }
        refreshRows()
        if submitted == 0 {
            // Every field was left blank, which means "test what is already
            // stored" — saying "已保存" here would be a lie.
            notice = nil
        } else if changed.isEmpty {
            notice = "已保存（值没有变化）。"
        } else {
            notice = "已保存到钥匙串。.env 没有被改动。"
            announce(changed)
        }
        return changed
    }

    /// Store a zero-length item: the user emptied this slot here, and the core
    /// must not fall back to `.env` for it.
    func clear(slot: String) {
        do {
            try store.clear(slot)
        } catch {
            notice = "\(Self.slotTitle(slot))：\(error.localizedDescription)"
            return
        }
        drafts[slot] = ""
        refreshRows()
        notice = "已清空 \(Self.slotTitle(slot))，且不会回退 .env。"
        announce([slot])
    }

    /// Remove the item, so the `.env` fallback applies again.
    func restoreEnvFallback(slot: String) {
        do {
            try store.forget(slot)
        } catch {
            notice = "\(Self.slotTitle(slot))：\(error.localizedDescription)"
            return
        }
        refreshRows()
        notice = "\(Self.slotTitle(slot)) 已交还给 .env。"
        announce([slot])
    }

    /// Copy one value out of `.env` into the Keychain, on an explicit press.
    /// Never automatic, and `.env` is only ever read.
    func importFromEnv(slot: String) {
        guard let path = envPath else {
            notice = "core 还没说 .env 在哪，导入不了。"
            return
        }
        let variable = envVar(for: slot)
        do {
            guard let value = try envReader.value(forKey: variable, atPath: path), !value.isEmpty else {
                notice = ".env 里没有 \(variable)。"
                refreshRows()
                return
            }
            try store.save(slot, value: value)
        } catch {
            notice = "\(Self.slotTitle(slot))：\(error.localizedDescription)"
            return
        }
        refreshRows()
        notice = "已把 \(variable) 复制进钥匙串。.env 原样保留。"
        announce([slot])
    }

    /// `credentials.updated` carries slot names only — never a value. This one
    /// is fine to log.
    private func announce(_ slots: [String]) {
        guard !slots.isEmpty else { return }
        settingsLog.info("credentials.updated: \(slots.joined(separator: ", "), privacy: .public)")
        send?(ControlMessage(body: .credentialsUpdated(CredentialsUpdatedPayload(slots: slots))))
    }

    // MARK: - Rows

    func refreshRows() {
        let path = envPath
        rows = CredentialSlotID.all.map { slot in
            var row = CredentialRow(slot: slot,
                                    envVar: envVar(for: slot),
                                    stored: store.load(slot),
                                    core: coreState?.credentials.first { $0.slot == slot })
            if let path {
                do {
                    row.envFingerprint = try envReader.value(forKey: row.envVar, atPath: path)
                        .map(CredentialFingerprint.of)
                } catch {
                    row.envRefusal = error.localizedDescription
                }
            }
            return row
        }
    }

    /// The `.env` the core said it loaded. The app does not go looking for one
    /// of its own: the file that matters is the one the core actually read.
    var envPath: String? {
        coreState?.envFiles.first { $0.loaded }?.path
    }

    func envVar(for slot: String) -> String {
        coreState?.credentials.first { $0.slot == slot }?.envVar ?? Self.defaultEnvVar(slot)
    }

    // MARK: - Static tables

    /// Mirrors `.env.example` and `CREDENTIAL_ENV_VARS` in
    /// core/src/credentials.ts. Only used before the first `settings.state`;
    /// after that the core's own answer wins.
    nonisolated static func defaultEnvVar(_ slot: String) -> String {
        switch slot {
        case CredentialSlotID.dashscopeAPIKey: "DASHSCOPE_API_KEY"
        case CredentialSlotID.cloudflareAccountID: "CLOUDFLARE_ACCOUNT_ID"
        case CredentialSlotID.cloudflareAPIToken: "CLOUDFLARE_API_TOKEN"
        case CredentialSlotID.huggingFaceToken: "HF_TOKEN"
        default: slot
        }
    }

    nonisolated static func slotTitle(_ slot: String) -> String {
        switch slot {
        case CredentialSlotID.dashscopeAPIKey: "DashScope API Key"
        case CredentialSlotID.cloudflareAccountID: "Cloudflare Account ID"
        case CredentialSlotID.cloudflareAPIToken: "Cloudflare API Token"
        case CredentialSlotID.huggingFaceToken: "Hugging Face Token"
        default: slot
        }
    }

    /// The account id is not a secret (§8.1) and being able to read it back is
    /// how a user checks they pasted the right account.
    nonisolated static func isSecret(_ slot: String) -> Bool {
        slot != CredentialSlotID.cloudflareAccountID
    }

    nonisolated static let groups: [CredentialGroup] = [
        CredentialGroup(
            id: "dashscope",
            title: "DashScope（语音）",
            slots: [CredentialSlotID.dashscopeAPIKey],
            route: SettingsRoute.voice,
            note: "百炼控制台 → API-KEY，形如 sk-…。语音这一路只有它。"),
        CredentialGroup(
            id: "cloudflare",
            title: "Cloudflare Workers AI（文本 / 看截图）",
            slots: [CredentialSlotID.cloudflareAccountID, CredentialSlotID.cloudflareAPIToken],
            route: SettingsRoute.text,
            note: "token 必须有 Workers AI「编辑」权限：只给「读取」时能列出模型，跑推理会 403。"),
        CredentialGroup(
            id: "huggingface",
            title: "Hugging Face（下载本地权重）",
            slots: [CredentialSlotID.huggingFaceToken],
            route: nil,
            note: "本地权重的 repo 是 gated，只在拉取时用得上，所以这里没有「测试」。"),
    ]

    nonisolated static func probeSummary(_ payload: SettingsProbeResultPayload) -> String {
        let name = SettingsDisplay.routeName(payload.route)
        guard !payload.results.isEmpty else { return "\(name)：没有候选可测。" }
        let parts = payload.results.map { result -> String in
            let status = SettingsDisplay.statusLabel(result.status)
            return "\(SettingsDisplay.providerName(result.provider)) \(status)"
        }
        return "\(name)：\(parts.joined(separator: "，"))"
    }
}
