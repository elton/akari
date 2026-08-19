import AppKit
import SwiftUI

/// The settings window.
///
/// **SwiftUI, hosted in a plain `NSWindow`.** The rest of the app is hand-built
/// AppKit, and that stays true where it has to be — the desktop windows, the
/// avatar layers and the confirm panel all do things AppKit does and SwiftUI
/// does not. This window is the opposite case: its entire content is a function
/// of one payload the core can push at any moment (`settings.state`), with a
/// candidate list whose length is not known in advance. In AppKit that means
/// hand-writing the diff between the old and new view tree; in SwiftUI it is the
/// default behaviour. The SwiftUI App lifecycle is *not* adopted — this is an
/// `LSUIElement` AppKit app with an `NSApplicationDelegate` — so the view is
/// mounted in an `NSHostingView` inside a window this file owns.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let store: SettingsStore
    /// Built lazily on the first `show()`. Not private so a test can build the
    /// window and inspect it without putting it on screen.
    private(set) var window: NSWindow?

    init(store: SettingsStore) {
        self.store = store
    }

    func show() {
        let window = prepareWindow()
        // The app is an accessory (`LSUIElement`), so it has to be activated
        // explicitly or the window opens behind whatever the user was using.
        //
        // `NSApp.activate()` alone is not enough. Activation on macOS 26 is
        // cooperative: an accessory app that the user did not just click on
        // does not get to take the front, and `activate()` fails silently.
        // Measured 2026-08-19 on a real first launch with another app frontmost
        // — the window existed, the onboarding sheet was attached to it, and
        // both stayed behind that app for the whole session while the "already
        // shown" preference was consumed anyway.
        //
        // `orderFrontRegardless()` is the call that does not ask: it puts the
        // window on screen whoever owns activation. `activate()` still runs
        // first so that keyboard focus follows in the ordinary case where the
        // system does grant it (opening settings from the menu bar).
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func close() {
        window?.close()
    }

    @discardableResult
    func prepareWindow() -> NSWindow {
        if let window { return window }
        let window = makeWindow()
        self.window = window
        return window
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "akari 设置"
        // Same reason as the desktop windows and the confirm panel: the default
        // over-releases a window with a layer-backed content view and crashes on
        // close.
        window.isReleasedWhenClosed = false
        // Deliberately NOT `backgroundColor = .clear` + `isOpaque = false`.
        // That pair is what the desktop window needs and what a titled window
        // must never get: on macOS 26 it makes the traffic lights disappear.
        // This is an ordinary titled window and keeps the system's own chrome.
        window.contentMinSize = NSSize(width: 560, height: 420)
        window.setFrameAutosaveName("akari.settings")
        window.delegate = self
        window.contentView = NSHostingView(rootView: SettingsRootView(store: store))
        window.center()
        return window
    }

    func windowWillClose(_ notification: Notification) {
        // Drop whatever was typed but not saved. Leaving a secret in a text
        // field of a hidden window is not a state worth keeping around.
        store.drafts.removeAll()
    }
}

// MARK: - Views

private struct SettingsRootView: View {
    let store: SettingsStore
    @State private var importSlot: String?

    private var routeIDs: [String] {
        let known = store.coreState?.routes.map(\.route) ?? []
        return known.isEmpty ? [SettingsRoute.voice, SettingsRoute.text] : known
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let onboarding = store.onboarding {
                    OnboardingBanner(text: onboarding) { store.dismissOnboarding() }
                }
                HeaderView(store: store)
                ForEach(routeIDs, id: \.self) { route in
                    RouteSection(store: store, route: route)
                }
                ForEach(SettingsStore.groups) { group in
                    CredentialGroupSection(store: store, group: group, importSlot: $importSlot)
                }
                LocalModelSection(store: store)
                SourcesSection(store: store)
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 560, minHeight: 420)
        .confirmationDialog(
            importSlot.map { "把 \(store.envVar(for: $0)) 从 .env 复制进钥匙串？" } ?? "",
            isPresented: Binding(get: { importSlot != nil }, set: { if !$0 { importSlot = nil } }),
            titleVisibility: .visible
        ) {
            Button("复制进钥匙串") {
                if let slot = importSlot { store.importFromEnv(slot: slot) }
                importSlot = nil
            }
            Button("取消", role: .cancel) { importSlot = nil }
        } message: {
            Text(".env 文件不会被修改，也不会被删除。复制之后钥匙串里的值优先。")
        }
    }
}

/// The first-run explanation (ADR-009: two sets of credentials, and configuring
/// one does not get you the other). Shown once, in the window rather than as a
/// sheet — see `AppDelegate.presentFirstRunOnboardingIfNeeded` for why.
private struct OnboardingBanner: View {
    let text: FirstRunOnboardingText
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(text.title)
                .font(.headline)
            Text(text.body)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(text.dismissTitle, action: dismiss)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.35)))
    }
}

private struct HeaderView: View {
    let store: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(store.connected ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                Text(store.connected ? "core 已连接" : "core 未连接")
                    .font(.headline)
                Spacer()
            }
            if !store.connected {
                Text("凭据仍然可以在这里编辑并存进钥匙串；core 一连上就会来取。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let notice = store.notice {
                Text(notice)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }
}

private struct RouteSection: View {
    let store: SettingsStore
    let route: String

    private var state: RouteStatePayload? { store.route(route) }

    private var options: [String] {
        SettingsDisplay.providerOptions(candidates: store.candidates(for: route).map(\.provider),
                                        selected: state?.selected)
    }

    private var selection: Binding<String> {
        Binding(get: { state?.selected ?? ProviderID.auto },
                set: { store.select(route: route, provider: $0) })
    }

    /// See `SettingsDisplay.offersProviderChoice`: voice has one candidate, so
    /// its picker would be two synonyms and no choice.
    private var offersChoice: Bool {
        SettingsDisplay.offersProviderChoice(
            candidates: store.candidates(for: route).map(\.provider),
            selected: state?.selected)
    }

    var body: some View {
        SectionBox(title: SettingsDisplay.routeName(route),
                   subtitle: SettingsDisplay.routeSubtitle(route)) {
            if state == nil {
                Text("还没收到 core 的设置状态。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    if offersChoice {
                        Picker("你选的", selection: selection) {
                            ForEach(options, id: \.self) { id in
                                Text(SettingsDisplay.providerName(id)).tag(id)
                            }
                        }
                        .frame(maxWidth: 340)
                        .disabled(!store.connected)
                    }
                    Spacer()
                    Button(store.probing.contains(route) ? "测试中…" : "测试这一路") {
                        store.probe(route: route)
                    }
                    .disabled(!store.connected || store.probing.contains(route))
                }
                Text(SettingsDisplay.activeLine(selected: state?.selected ?? ProviderID.auto,
                                                active: state?.active,
                                                candidates: store.candidates(for: route)))
                    .font(.callout)
                ForEach(store.candidates(for: route), id: \.provider) { candidate in
                    CandidateRow(health: candidate,
                                 isActive: candidate.provider == state?.active)
                }
            }
        }
    }
}

private struct CandidateRow: View {
    let health: ProviderHealthPayload
    let isActive: Bool

    private var tint: Color {
        switch SettingsDisplay.severity(health.status) {
        case .good: .green
        case .warn: .orange
        case .bad: .red
        case .neutral: .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Circle().fill(tint).frame(width: 7, height: 7)
                Text(SettingsDisplay.providerName(health.provider)).font(.body.weight(.medium))
                Text(SettingsDisplay.statusLabel(health.status))
                    .font(.caption)
                    .foregroundStyle(tint)
                if isActive {
                    Text("在用")
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.18), in: Capsule())
                }
                Spacer()
                Text(SettingsDisplay.checkedLine(health.checkedAt, latencyMs: health.latencyMs))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let message = health.message, !message.isEmpty {
                Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            } else if let advice = SettingsDisplay.statusAdvice(health.status) {
                Text(advice).font(.caption).foregroundStyle(.secondary)
            }
            if let missing = health.missing, !missing.isEmpty {
                Text("缺：" + missing.map(SettingsStore.slotTitle).joined(separator: "、"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let model = health.model {
                Text(model).font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
            if let capabilities = SettingsDisplay.capabilityLine(health.capabilities) {
                Text(capabilities).font(.caption2).foregroundStyle(.secondary)
            }
            if let quota = SettingsDisplay.quotaLine(health.quota) {
                Text("额度：" + quota).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
    }
}

private struct CredentialGroupSection: View {
    let store: SettingsStore
    let group: CredentialGroup
    @Binding var importSlot: String?

    private var rows: [CredentialRow] {
        group.slots.compactMap { slot in store.rows.first { $0.slot == slot } }
    }

    var body: some View {
        SectionBox(title: group.title, subtitle: group.note) {
            ForEach(rows) { row in
                CredentialFieldView(store: store, row: row, importSlot: $importSlot)
            }
            HStack {
                Spacer()
                if group.route != nil {
                    Button("保存并测试") { store.saveAndTest(group: group) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!store.connected)
                } else {
                    Button("保存") { store.save(group: group) }
                }
            }
        }
    }
}

private struct CredentialFieldView: View {
    let store: SettingsStore
    let row: CredentialRow
    @Binding var importSlot: String?

    private var draft: Binding<String> {
        Binding(get: { store.drafts[row.slot] ?? "" },
                set: { store.drafts[row.slot] = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(row.title).font(.callout.weight(.medium))
            // Never pre-filled with the stored value: the field is an input, and
            // a window that displays the credential is one screen-share away
            // from handing it out. What it shows instead is the fingerprint.
            if SettingsStore.isSecret(row.slot) {
                SecureField("留空表示不改动", text: draft)
                    .textFieldStyle(.roundedBorder)
            } else {
                TextField("留空表示不改动", text: draft)
                    .textFieldStyle(.roundedBorder)
            }
            Text(row.statusLine).font(.caption).foregroundStyle(.secondary)
            if let refusal = row.envRefusal {
                Text(refusal).font(.caption2).foregroundStyle(.orange)
            }
            // Orange rather than secondary: this one looks like "the token
            // expired" for an afternoon before anybody thinks of the shell
            // (docs/decisions.md, ADR-009 接线时发现的第 1 个问题).
            if row.shellShadowsEnvFile {
                Text("shell 里导出的同名变量压过了 .env。改 .env 不会有任何效果，"
                     + "先 `unset \(row.envVar)` 或者改你的 shell 配置。")
                    .font(.caption2).foregroundStyle(.orange).textSelection(.enabled)
            }
            if row.core?.denied == true {
                Text("core 那边也标了 denied。").font(.caption2).foregroundStyle(.orange)
            }
            HStack(spacing: 10) {
                if row.canImportFromEnv {
                    Button("从 .env 导入…") { importSlot = row.slot }
                        .buttonStyle(.link)
                }
                if row.canRestoreEnvFallback {
                    Button("恢复 .env 回退") { store.restoreEnvFallback(slot: row.slot) }
                        .buttonStyle(.link)
                }
                if row.canClear {
                    Button("清空") { store.clear(slot: row.slot) }
                        .buttonStyle(.link)
                }
                Spacer()
            }
            .font(.caption)
        }
    }
}

private struct LocalModelSection: View {
    let store: SettingsStore

    private var health: ProviderHealthPayload? {
        store.candidates(for: SettingsRoute.text).first { $0.provider == ProviderID.localMLX }
    }

    var body: some View {
        SectionBox(title: "本地模型（兜底）",
                   subtitle: "网络那一路全挂时接手。权重与运行时都在本机。") {
            if let health {
                CandidateRow(health: health,
                             isActive: store.route(SettingsRoute.text)?.active == ProviderID.localMLX)
                Button("重新探测") { store.probe(route: SettingsRoute.text, provider: ProviderID.localMLX) }
                    .disabled(!store.connected || store.probing.contains(SettingsRoute.text))
            } else {
                Text("core 还没报告本地 provider。").font(.callout).foregroundStyle(.secondary)
            }
            // Stated rather than faked: the frozen protocol has no message for
            // weight size, load progress or unloading, so this window has no
            // honest way to show or drive them. A dead button would be worse
            // than this line.
            Text("下载大小、加载进度与「卸载以释放内存」还没接线：协议里没有对应的消息，"
                 + "现在能显示的只有 core 探测出来的状态。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct SourcesSection: View {
    let store: SettingsStore

    var body: some View {
        SectionBox(title: "配置来源",
                   subtitle: "优先级按槽算：钥匙串 → .env → 未配置。只填了一半也不会作废另一半。") {
            if let files = store.coreState?.envFiles, !files.isEmpty {
                ForEach(files, id: \.path) { file in
                    HStack(spacing: 8) {
                        Circle().fill(file.loaded ? Color.green : Color.secondary)
                            .frame(width: 7, height: 7)
                        Text(file.path).font(.caption.monospaced()).textSelection(.enabled)
                        Text(file.loaded ? "已加载" : "不存在").font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            } else {
                Text("core 还没报告它读了哪些 .env。").font(.callout).foregroundStyle(.secondary)
            }
            Text("这个窗口永远不会修改或删除 .env。")
                .font(.caption).foregroundStyle(.secondary)
            Text(SettingsDisplay.keychainProtectionLine(
                    dataProtection: store.keychainDataProtection))
                .font(.caption)
                .foregroundStyle(store.keychainDataProtection ? AnyShapeStyle(.secondary)
                                                              : AnyShapeStyle(Color.orange))
                .textSelection(.enabled)
        }
    }
}

private struct SectionBox<Content: View>: View {
    let title: String
    var subtitle: String = ""
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title3.weight(.semibold))
                if !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
