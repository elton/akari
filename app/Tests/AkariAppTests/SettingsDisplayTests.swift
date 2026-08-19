import AppKit
import Foundation
import Testing
@testable import AkariApp

// The strings the settings window shows. The point of testing them is that the
// nine statuses each mean a different thing for the user, and that a status this
// build has never heard of has to render as a row rather than blow up.

@Suite("settings display")
struct SettingsDisplayTests {
    @Test("every protocol status has its own label and its own remedy")
    func statusesAreDistinct() {
        let statuses = ["ok", "unconfigured", "unauthorized", "quota_exhausted",
                        "unreachable", "model_missing", "starting", "error", "unknown"]
        let labels = statuses.map(SettingsDisplay.statusLabel)
        #expect(Set(labels).count == statuses.count)
        // `ok` and `unknown` need no instruction; the other seven do.
        #expect(SettingsDisplay.statusAdvice("ok") == nil)
        #expect(SettingsDisplay.statusAdvice("unknown") == nil)
        for status in statuses where status != "ok" && status != "unknown" {
            #expect(SettingsDisplay.statusAdvice(status) != nil)
        }
    }

    @Test("an unrecognised status renders instead of disappearing")
    func unknownStatusRenders() {
        // This is what `status` being a String rather than a Codable enum buys:
        // the core can learn a new one and the window still draws the row.
        #expect(SettingsDisplay.statusLabel("teapot") == "未知状态")
        #expect(SettingsDisplay.statusAdvice("teapot")?.contains("teapot") == true)
        #expect(SettingsDisplay.severity("teapot") == .neutral)
        #expect(SettingsDisplay.providerName("brand-new-provider") == "brand-new-provider")
    }

    @Test("never-probed is neutral, not a failure")
    func unknownIsNotRed() {
        #expect(SettingsDisplay.severity("unknown") == .neutral)
        #expect(SettingsDisplay.severity("ok") == .good)
        #expect(SettingsDisplay.severity("starting") == .warn)
        #expect(SettingsDisplay.severity("unauthorized") == .bad)
    }

    @Test("an automatic fallback is spelled out, not hidden")
    func fallbackIsVisible() {
        let line = SettingsDisplay.activeLine(selected: ProviderID.cloudflareWorkersAI,
                                              active: ProviderID.localMLX,
                                              candidates: Self.textCandidates(cfStatus: "unreachable"))
        #expect(line.contains("本地 MLX"))
        #expect(line.contains("已自动降级"))

        let matched = SettingsDisplay.activeLine(selected: ProviderID.localMLX,
                                                 active: ProviderID.localMLX,
                                                 candidates: Self.textCandidates())
        #expect(!matched.contains("降级"))

        #expect(SettingsDisplay.activeLine(selected: ProviderID.auto, active: nil,
                                           candidates: Self.textCandidates())
                    .contains("没有可用"))
    }

    /// `auto` is the default, so this is the branch that decides whether a
    /// fallback is ever visible at all — and it used to say "当前在用：本地 MLX"
    /// and stop there.
    @Test("under auto a fallback still says it fell back, and why")
    func autoFallbackIsSpelledOut() {
        let line = SettingsDisplay.activeLine(selected: ProviderID.auto,
                                              active: ProviderID.localMLX,
                                              candidates: Self.textCandidates(cfStatus: "unreachable"))
        #expect(line.contains("已自动降级"))
        #expect(line.contains("Cloudflare Workers AI"))
        #expect(line.contains("连不上"))
        #expect(line.contains("本地 MLX"))

        // The head of the fallback order is the one serving: nothing fell back.
        let head = SettingsDisplay.activeLine(selected: ProviderID.auto,
                                              active: ProviderID.cloudflareWorkersAI,
                                              candidates: Self.textCandidates())
        #expect(!head.contains("降级"))
        #expect(head.contains("当前在用：Cloudflare Workers AI"))

        // A live demotion happens before the next probe rewrites `status`, so
        // "ok" is reachable here and must not read as "CF 可用，已自动降级".
        let stale = SettingsDisplay.activeLine(selected: ProviderID.auto,
                                               active: ProviderID.localMLX,
                                               candidates: Self.textCandidates(cfStatus: "ok"))
        #expect(stale.contains("已自动降级"))
        #expect(stale.contains("暂时用不了"))
        #expect(!stale.contains("可用，"))

        // No candidate list to compare against: say what is true, no more.
        let bare = SettingsDisplay.activeLine(selected: ProviderID.auto,
                                              active: ProviderID.localMLX, candidates: [])
        #expect(bare == "当前在用：本地 MLX")
    }

    /// docs/protocol.md §3.9: the voice row shows connectivity and whether the
    /// credential is set. It is not a switch — its only two entries would be
    /// "自动" and the single provider, which are the same thing.
    @Test("a one-candidate route gets no picker")
    func singleCandidateHasNoPicker() {
        #expect(!SettingsDisplay.offersProviderChoice(
            candidates: [ProviderID.dashscopeRealtime], selected: ProviderID.dashscopeRealtime))
        #expect(!SettingsDisplay.offersProviderChoice(
            candidates: [ProviderID.dashscopeRealtime], selected: ProviderID.auto))
        #expect(!SettingsDisplay.offersProviderChoice(candidates: [], selected: ProviderID.auto))

        // Two real candidates is a real choice.
        #expect(SettingsDisplay.offersProviderChoice(
            candidates: [ProviderID.cloudflareWorkersAI, ProviderID.localMLX],
            selected: ProviderID.auto))
        // A `selected` the core reports outside `candidates` has to stay
        // selectable, and that is a choice too.
        #expect(SettingsDisplay.offersProviderChoice(
            candidates: [ProviderID.dashscopeRealtime], selected: "some-new-provider"))
    }

    /// The window must not describe a protection the build does not have.
    @Test("the keychain line says which keychain, and does not overclaim")
    func keychainProtectionIsHonest() {
        let degraded = SettingsDisplay.keychainProtectionLine(dataProtection: false)
        #expect(degraded.contains("登录钥匙串"))
        #expect(degraded.contains("不生效"))
        #expect(degraded.contains("签名"))
        #expect(!degraded.contains("仅本机、解锁后可读（"))

        let real = SettingsDisplay.keychainProtectionLine(dataProtection: true)
        #expect(real.contains("数据保护钥匙串"))
        #expect(!real.contains("不生效"))
    }

    private static func textCandidates(cfStatus: String = "ok") -> [ProviderHealthPayload] {
        [ProviderHealthPayload(provider: ProviderID.cloudflareWorkersAI, status: cfStatus, checkedAt: 1),
         ProviderHealthPayload(provider: ProviderID.localMLX, status: "ok", checkedAt: 1)]
    }

    @Test("checkedAt 0 reads as never probed rather than as 1970")
    func neverProbed() {
        #expect(SettingsDisplay.checkedLine(0, latencyMs: nil) == "还没探测过")
        #expect(SettingsDisplay.checkedLine(1_755_607_200_123, latencyMs: 312).contains("312ms"))
    }

    @Test("quota renders from whatever subset of the numbers arrived")
    func quotaSubsets() {
        #expect(SettingsDisplay.quotaLine(nil) == nil)
        // The case the CF provider is most likely to be in: no numbers at all.
        let noteOnly = QuotaSnapshotPayload(unit: "neurons", note: "额度看 dashboard")
        #expect(SettingsDisplay.quotaLine(noteOnly) == "额度看 dashboard")

        let full = QuotaSnapshotPayload(unit: "neurons", used: 1234, limit: 10_000,
                                        remaining: 8766)
        let line = SettingsDisplay.quotaLine(full)
        #expect(line?.contains("剩余 8766 / 10000 neurons") == true)

        let usedOnly = QuotaSnapshotPayload(unit: "requests", used: 12)
        #expect(SettingsDisplay.quotaLine(usedOnly) == "已用 12 requests")
    }

    @Test("capabilities say the two things that decide behaviour: images and where it runs")
    func capabilityLine() {
        let line = SettingsDisplay.capabilityLine(ProviderCapabilitiesPayload(
            vision: true, tools: true, streaming: true, contextTokens: 131_072, local: false))
        #expect(line?.contains("能看图") == true)
        #expect(line?.contains("走网络") == true)
        #expect(line?.contains("128K") == true)

        let local = SettingsDisplay.capabilityLine(ProviderCapabilitiesPayload(
            vision: false, tools: false, streaming: false, contextTokens: 8000, local: true))
        #expect(local?.contains("只有文本") == true)
        #expect(local?.contains("本机推理") == true)
        #expect(SettingsDisplay.capabilityLine(nil) == nil)
    }

    @Test("route names cover both routes; there is no third one")
    func routes() {
        #expect(SettingsDisplay.routeName(SettingsRoute.voice) == "语音对话")
        #expect(SettingsDisplay.routeName(SettingsRoute.text) == "文本 / 看截图")
        // The "兜底" row of ADR-009 is not a route: it is the order of the text
        // route's candidates (docs/protocol.md §3.9).
        #expect(SettingsDisplay.routeName("fallback") == "fallback")
    }
}

@MainActor
@Suite("settings window")
struct SettingsWindowTests {
    /// The pitfall this guards is specific and already cost this project once:
    /// on macOS 26, a *titled* window with `backgroundColor = .clear` and
    /// `isOpaque = false` loses its traffic lights. The desktop avatar windows
    /// need exactly that pair; this window must never inherit it.
    @Test("the settings window keeps its chrome — titled, opaque, not clear")
    func windowKeepsItsTrafficLights() {
        _ = NSApplication.shared
        let controller = SettingsWindowController(store: SettingsStore(store: InMemoryCredentialStore()))
        let window = controller.prepareWindow()

        #expect(window.styleMask.contains(.titled))
        #expect(window.styleMask.contains(.closable))
        #expect(window.styleMask.contains(.miniaturizable))
        #expect(window.isOpaque)
        #expect(window.backgroundColor != .clear)
        #expect(window.standardWindowButton(.closeButton) != nil)
        #expect(window.isReleasedWhenClosed == false)
    }

    @Test("the SwiftUI tree actually builds and lays out")
    func contentLaysOut() {
        _ = NSApplication.shared
        let store = SettingsStore(store: InMemoryCredentialStore())
        let controller = SettingsWindowController(store: store)
        let window = controller.prepareWindow()
        // Not a screenshot, but it does prove every view in the tree can be
        // constructed and measured — which "it compiled" does not.
        let content = window.contentView
        content?.layoutSubtreeIfNeeded()
        #expect((content?.fittingSize.height ?? 0) > 0)
    }

    @Test("closing the window drops whatever was typed but not saved")
    func closingWipesDrafts() {
        _ = NSApplication.shared
        let store = SettingsStore(store: InMemoryCredentialStore())
        let controller = SettingsWindowController(store: store)
        let window = controller.prepareWindow()
        store.drafts[CredentialSlotID.dashscopeAPIKey] = "sk-typed-not-saved"

        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
        #expect(store.drafts.isEmpty)
    }
}
