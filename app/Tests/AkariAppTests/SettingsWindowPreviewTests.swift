import AppKit
import Foundation
import Testing
@testable import AkariApp

/// Renders the settings window off-screen to a PNG, so it can be *looked at*
/// without launching the app — which would put the desktop avatar windows on
/// somebody's screen just to check a text field.
///
/// Opt-in, because it writes a file and nothing about it is an assertion:
///
///     AKARI_RENDER=1 AKARI_RENDER_OUT=/tmp/settings.png swift test
///
/// Everything it feeds in is a literal. The `.env` reader is a stub: a test must
/// not read the developer's real `.env`, even to fingerprint it.
@MainActor
@Suite("settings window preview")
struct SettingsWindowPreviewTests {
    private final class StubEnvReader: EnvFileReading {
        func value(forKey key: String, atPath path: String) throws -> String? {
            key == "DASHSCOPE_API_KEY" ? "sk-a-different-one" : nil
        }
    }

    @Test("render", .enabled(if: ProcessInfo.processInfo.environment["AKARI_RENDER"] == "1"))
    func render() throws {
        _ = NSApplication.shared
        let keychain = InMemoryCredentialStore()
        try keychain.save(CredentialSlotID.dashscopeAPIKey, value: "sk-example-value")
        try keychain.clear(CredentialSlotID.huggingFaceToken)
        let store = SettingsStore(store: keychain, envReader: StubEnvReader())
        store.coreConnected()
        let voice = RouteStatePayload(route: SettingsRoute.voice, selected: ProviderID.dashscopeRealtime,
            active: ProviderID.dashscopeRealtime, candidates: [
                ProviderHealthPayload(provider: ProviderID.dashscopeRealtime, status: "ok",
                    model: "qwen3.5-omni-flash-realtime", latencyMs: 473, checkedAt: 1_755_607_200_123)])
        let text = RouteStatePayload(route: SettingsRoute.text, selected: ProviderID.cloudflareWorkersAI,
            active: ProviderID.localMLX, candidates: [
                ProviderHealthPayload(provider: ProviderID.cloudflareWorkersAI, status: "unauthorized",
                    message: "token 只有 Workers AI「读取」权限，跑推理会 403。",
                    model: "@cf/qwen/qwen3.8-27b",
                    capabilities: ProviderCapabilitiesPayload(vision: true, tools: true, streaming: true,
                        contextTokens: 131_072, maxOutputTokens: 8192, local: false),
                    quota: QuotaSnapshotPayload(unit: "neurons", note: "额度数字要去 dashboard 看"),
                    latencyMs: 312, checkedAt: 1_755_607_200_123),
                ProviderHealthPayload(provider: ProviderID.localMLX, status: "ok",
                    model: "Qwen3.8-27B-Uncensored-MLX 6bit",
                    capabilities: ProviderCapabilitiesPayload(vision: true, tools: false, streaming: true,
                        contextTokens: 262_144, local: true),
                    latencyMs: 1900, checkedAt: 1_755_607_200_123)])
        store.handle(ControlMessage(body: .settingsState(SettingsStatePayload(
            routes: [voice, text],
            credentials: [
                CredentialSlotStatePayload(slot: CredentialSlotID.dashscopeAPIKey, source: "app",
                    present: true, fingerprint: CredentialFingerprint.of("sk-example-value"),
                    envVar: "DASHSCOPE_API_KEY"),
                CredentialSlotStatePayload(slot: CredentialSlotID.cloudflareAccountID, source: "env",
                    present: true, fingerprint: "aa11bb22", envVar: "CLOUDFLARE_ACCOUNT_ID"),
                CredentialSlotStatePayload(slot: CredentialSlotID.cloudflareAPIToken, source: "env",
                    present: true, fingerprint: "cc33dd44", envVar: "CLOUDFLARE_API_TOKEN"),
                CredentialSlotStatePayload(slot: CredentialSlotID.huggingFaceToken, source: "unset",
                    present: false, cleared: true, envVar: "HF_TOKEN"),
            ],
            envFiles: [EnvFileStatePayload(path: "/Volumes/data/Dev/01-PWR/akari/.env", loaded: true)]))))

        let controller = SettingsWindowController(store: store)
        let window = controller.prepareWindow()
        let view = try #require(window.contentView)
        view.frame = NSRect(x: 0, y: 0, width: 620, height: max(700, view.fittingSize.height))
        view.layoutSubtreeIfNeeded()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        let out = ProcessInfo.processInfo.environment["AKARI_RENDER_OUT"] ?? "/tmp/settings.png"
        try png.write(to: URL(filePath: out))
    }
}
