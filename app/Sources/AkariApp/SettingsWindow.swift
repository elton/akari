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
                AvatarSection(store: store)
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

// MARK: - Avatar

/// Renders a `String` that carries markdown emphasis.
///
/// `Text("literal")` parses markdown because the literal becomes a
/// `LocalizedStringKey`; `Text(someString)` does not, and would print the
/// asterisks. The explanation strings live in `SettingsDisplay` as data, so they
/// take this route.
private struct MarkdownText: View {
    let string: String
    init(_ string: String) { self.string = string }
    var body: some View { Text(LocalizedStringKey(string)) }
}

/// 形态 / 位置与大小 / 多显示器 / 配套壁纸.
///
/// The section exists because of a trade-off that was never put to the user: the
/// desktop layer puts her under every window, which is exactly where an "AI
/// companion" stops being company. Everything here is a preference this window
/// owns end to end — no core round-trip — so it keeps working with `core 未连接`.
private struct AvatarSection: View {
    let store: SettingsStore
    @State private var previewState: AvatarState = .idle
    @State private var showGroundingDetail = false

    var body: some View {
        SectionBox(title: "形象", subtitle: "她画在哪一层、站在哪里、多大，以及要不要配套壁纸。") {
            ModePicker(store: store)
            Divider()
            PlacementEditor(store: store,
                            previewState: $previewState,
                            showGroundingDetail: $showGroundingDetail)
            Divider()
            DisplayScopePicker(store: store)
            Divider()
            WallpaperControls(store: store)
        }
        .confirmationDialog(
            SettingsDisplay.wallpaperConsentTitle,
            isPresented: Binding(get: { store.wallpaperConsentPending },
                                 set: { if !$0 { store.cancelWallpaperConsent() } }),
            titleVisibility: .visible
        ) {
            Button("换掉，并记住我原来那张") { store.confirmWallpaperConsent() }
            Button("取消", role: .cancel) { store.cancelWallpaperConsent() }
        } message: {
            // `LocalizedStringKey`, not the bare `String`: `Text(someString)` does
            // not parse markdown, and this body carries emphasis — it printed the
            // asterisks verbatim in the one dialog that must read cleanly.
            Text(LocalizedStringKey(SettingsDisplay.wallpaperConsentBody))
        }
    }
}

/// The screen the settings window quotes its numbers against.
///
/// `NSScreen.main` is the screen the key window is on, which is the one the user
/// is looking at while dragging the slider. Deliberately *not* the same call the
/// window controller uses to decide "which display is the main one" — that one is
/// `CGMainDisplayID()`, because for a background app `NSScreen.main` follows
/// whatever app is frontmost. Here it is only used for a preview and a "约 NNNpt"
/// label, where following the user's gaze is the right answer.
@MainActor
private var previewDisplaySize: CGSize {
    NSScreen.main?.frame.size ?? CGSize(width: 2560, height: 1440)
}

/// Desktop layer vs floating layer, each with the sentence that says what it
/// actually costs. Two cards rather than a `Picker`: the two words on their own
/// are meaningless to anybody who has not read the window-level dump, and this
/// choice is the point of the whole round.
private struct ModePicker: View {
    let store: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("形态").font(.callout.weight(.medium))
            ForEach(AvatarLayerMode.allCases, id: \.self) { mode in
                ModeCard(mode: mode, isSelected: store.avatar.mode == mode) {
                    store.setAvatarMode(mode)
                }
            }
        }
    }
}

private struct ModeCard: View {
    let mode: AvatarLayerMode
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(SettingsDisplay.avatarModeHeadline(mode))
                        .font(.body.weight(.medium))
                    MarkdownText(SettingsDisplay.avatarModeExplanation(mode))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.10) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.45)
                                         : Color.secondary.opacity(0.25)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Anchor grid + size slider + the live preview they both feed.
private struct PlacementEditor: View {
    let store: SettingsStore
    @Binding var previewState: AvatarState
    @Binding var showGroundingDetail: Bool

    private var mode: AvatarLayerMode { store.avatar.mode }
    private var placement: AvatarPlacement { store.avatar.current.placement }
    private var boxHeight: CGFloat { placement.frame(inDisplayOfSize: previewDisplaySize).height }

    private var heightBinding: Binding<Double> {
        Binding(get: { Double(placement.heightFraction) },
                set: { store.setAvatarHeightFraction(CGFloat($0)) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("位置").font(.callout.weight(.medium))
                    AnchorGrid(selected: placement.anchor) { store.setAvatarAnchor($0) }
                    if let note = SettingsDisplay.anchorNote(placement.anchor) {
                        Text(note)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 200, alignment: .leading)
                    }
                }
                Spacer(minLength: 0)
                AvatarPreview(placement: placement, mode: mode, state: previewState)
                    .frame(width: 230)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("大小").font(.callout.weight(.medium))
                Slider(value: heightBinding,
                       in: Double(SettingsDisplay.avatarHeightRange(mode).lowerBound)
                           ... Double(SettingsDisplay.avatarHeightRange(mode).upperBound))
                Text(SettingsDisplay.avatarHeightLabel(placement.heightFraction,
                                                       displayHeight: previewDisplaySize.height))
                    .font(.caption).foregroundStyle(.secondary)
                Text("桌面层与浮动层各记各的位置、大小和多显示器设置 —— 切回来还是你上次调的那个。")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            // One state at a time on purpose: the four do not line up at the
            // bottom, and letting the user flip between them is the only way to
            // see that before choosing a size.
            VStack(alignment: .leading, spacing: 4) {
                Picker("预览状态", selection: $previewState) {
                    ForEach(AvatarGrounding.previewStates, id: \.self) { state in
                        Text(AvatarGrounding.stateName(state)).tag(state)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(AvatarGrounding.gapLine(previewState, boxHeight: boxHeight))
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                DisclosureGroup("为什么各状态不一样高？", isExpanded: $showGroundingDetail) {
                    MarkdownText(AvatarGrounding.caveat)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                }
                .font(.caption2)
            }
        }
    }
}

/// The nine anchors laid out where they sit on a screen.
private struct AnchorGrid: View {
    let selected: AvatarPlacement.Anchor
    let select: (AvatarPlacement.Anchor) -> Void

    var body: some View {
        VStack(spacing: 4) {
            ForEach(Array(SettingsDisplay.anchorGrid.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 4) {
                    ForEach(row, id: \.self) { anchor in
                        AnchorCell(anchor: anchor, isSelected: anchor == selected) {
                            select(anchor)
                        }
                    }
                }
            }
        }
        .padding(5)
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
    }
}

private struct AnchorCell: View {
    let anchor: AvatarPlacement.Anchor
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            Text(SettingsDisplay.anchorName(anchor))
                .font(.caption2)
                .frame(width: 56, height: 30)
                .background(RoundedRectangle(cornerRadius: 5)
                    .fill(isSelected ? Color.accentColor.opacity(0.22)
                                     : Color.secondary.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(SettingsDisplay.anchorName(anchor))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A schematic screen with her real geometry on it.
///
/// **The geometry is not a drawing.** The avatar box comes from
/// `AvatarPlacement.frame(inDisplayOfSize:)` — the same function the window uses
/// — computed at the real display size and then scaled down, so anchors and
/// offsets are exactly what will happen. Her body inside that box comes from
/// `AvatarGrounding`, i.e. the measured `anchors.json` boxes, which is why she
/// visibly lifts off the bottom edge in 在听 and 在想. Only the silhouette itself
/// is schematic, and it is drawn to fill the measured box exactly.
private struct AvatarPreview: View {
    let placement: AvatarPlacement
    let mode: AvatarLayerMode
    let state: AvatarState

    var body: some View {
        let display = previewDisplaySize
        GeometryReader { geo in
            let scale = display.width > 0 ? geo.size.width / display.width : 0
            let box = flipped(placement.frame(inDisplayOfSize: display), in: display, scale: scale)
            ZStack(alignment: .topLeading) {
                wallpaper
                menuBar(width: geo.size.width)
                desktopIcons(in: geo.size)

                // Draw order *is* the explanation: on the desktop layer the mock
                // window goes over her, on the floating layer it goes under.
                if mode == .floating { mockWindow(in: geo.size) }
                figure(in: box)
                if mode == .desktop { mockWindow(in: geo.size) }

                clipFrame(box)
                idleBaseline(box)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.35)))
        }
        .aspectRatio(display.height > 0 ? display.width / display.height : 16.0 / 9.0,
                     contentMode: .fit)
    }

    /// `AvatarPlacement` works bottom-left (unflipped `NSView`); SwiftUI is
    /// top-left.
    private func flipped(_ rect: CGRect, in size: CGSize, scale: CGFloat) -> CGRect {
        CGRect(x: rect.minX * scale,
               y: (size.height - rect.maxY) * scale,
               width: rect.width * scale,
               height: rect.height * scale)
    }

    private var wallpaper: some View {
        LinearGradient(colors: [Color(red: 0.16, green: 0.18, blue: 0.26),
                                Color(red: 0.30, green: 0.24, blue: 0.34)],
                       startPoint: .top, endPoint: .bottom)
    }

    private func menuBar(width: CGFloat) -> some View {
        Rectangle().fill(Color.white.opacity(0.16)).frame(width: width, height: 6)
    }

    private func desktopIcons(in size: CGSize) -> some View {
        VStack(spacing: 4) {
            ForEach(0..<2, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white.opacity(0.22))
                    .frame(width: 9, height: 9)
            }
        }
        .position(x: size.width - 12, y: 24)
    }

    /// A stand-in for "the user is working".
    ///
    /// Two things about it are load-bearing. It is big enough to reach every
    /// anchor — a window that stopped short of the corner she is in would show
    /// the desktop layer *not* being covered, which is the opposite of the
    /// point. And it is fully opaque, with a title bar, so that where it covers
    /// her there is nothing left to see; a translucent rectangle over a pale
    /// silhouette reads as "still visible".
    private func mockWindow(in size: CGSize) -> some View {
        let width = size.width * 0.84
        let height = size.height * 0.70
        return VStack(spacing: 0) {
            ZStack(alignment: .leading) {
                Rectangle().fill(Color(white: 0.86))
                HStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle().fill(Color(white: 0.62)).frame(width: 3, height: 3)
                    }
                }
                .padding(.leading, 5)
            }
            .frame(height: 9)
            Rectangle().fill(Color(white: 0.96))
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.black.opacity(0.20)))
        .position(x: size.width * 0.5, y: size.height * 0.56)
    }

    /// The clip's own frame — the 810x1080 box the video is drawn into. Dashed and
    /// faint, so the empty space under her body reads as part of the footage
    /// rather than as a layout mistake.
    private func clipFrame(_ box: CGRect) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .strokeBorder(Color.white.opacity(0.35),
                          style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .frame(width: box.width, height: box.height)
            .offset(x: box.minX, y: box.minY)
    }

    /// Where `idle` ends, so the lift in the other states has something to be
    /// measured against.
    private func idleBaseline(_ box: CGRect) -> some View {
        let idleBottom = AvatarGrounding.box(.idle).map { idle in
            box.minY + box.height * ((idle.y + idle.height) / AvatarBodyBox.canvas.height)
        }
        return Rectangle()
            .fill(Color.accentColor.opacity(idleBottom == nil ? 0 : 0.7))
            .frame(width: box.width, height: 1)
            .offset(x: box.minX, y: (idleBottom ?? 0) - 0.5)
    }

    @ViewBuilder
    private func figure(in box: CGRect) -> some View {
        if let body = AvatarGrounding.box(state) {
            let normalized = body.normalized()
            let rect = CGRect(x: box.minX + box.width * normalized.minX,
                              y: box.minY + box.height * normalized.minY,
                              width: box.width * normalized.width,
                              height: box.height * normalized.height)
            let head = min(rect.width * 0.46, rect.height * 0.30)
            ZStack(alignment: .topLeading) {
                Circle()
                    .fill(Color.white.opacity(0.82))
                    .frame(width: head, height: head)
                    .offset(x: rect.midX - head / 2, y: rect.minY)
                RoundedRectangle(cornerRadius: rect.width * 0.30)
                    .fill(Color.white.opacity(0.82))
                    .frame(width: rect.width * 0.92,
                           height: max(rect.height - head * 0.82, 1))
                    .offset(x: rect.midX - rect.width * 0.46,
                            y: rect.minY + head * 0.82)
            }
        }
    }
}

/// Per mode, because the two want different answers: two always-on-top
/// companions on a two-panel desk is twice the interruption, while two desktop
/// ones cost nothing but decoding.
private struct DisplayScopePicker: View {
    let store: SettingsStore

    private var selection: Binding<AvatarDisplayScope> {
        Binding(get: { store.avatar.current.displayScope },
                set: { store.setAvatarDisplayScope($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("多显示器").font(.callout.weight(.medium))
            Picker("多显示器", selection: selection) {
                ForEach(AvatarDisplayScope.allCases, id: \.self) { scope in
                    Text(SettingsDisplay.avatarScopeName(scope)).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 260)
            Text(SettingsDisplay.avatarScopeExplanation(store.avatar.current.displayScope,
                                                        mode: store.avatar.mode))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct WallpaperControls: View {
    let store: SettingsStore

    private var toggle: Binding<Bool> {
        // Reads the stored value, never the pending one: while consent is on
        // screen the switch stays off, so cancelling leaves the desktop alone and
        // the switch honest about it.
        Binding(get: { store.avatar.wallpaperEnabled },
                set: { store.setWallpaperEnabled($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("配套壁纸").font(.callout.weight(.medium))
            Toggle("启动时应用配套壁纸", isOn: toggle)
            Text(SettingsDisplay.wallpaperStatusLine(
                enabled: store.avatar.wallpaperEnabled,
                canRestore: store.canRestoreWallpaper,
                replaced: store.hasReplacedWallpaper,
                wired: store.isWallpaperWired))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("恢复我原来的壁纸") { store.restoreOriginalWallpaper() }
                    .disabled(!store.canRestoreWallpaper)
                Spacer()
            }
        }
    }
}
