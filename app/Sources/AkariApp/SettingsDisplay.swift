import Foundation

/// Every string the settings window shows about a provider, a status or a
/// quota, as pure functions of the wire payloads.
///
/// They are separate from the views because this is the part worth testing: the
/// nine `ProviderStatus` values each map to a different instruction for the
/// user (docs/protocol.md §3.9), and the whole reason `status` is a `String`
/// rather than an enum is that a tenth value must render as a row, not as a
/// decoding failure.
enum SettingsDisplay {
    static func providerName(_ id: String) -> String {
        switch id {
        case ProviderID.dashscopeRealtime: "DashScope Realtime"
        case ProviderID.cloudflareWorkersAI: "Cloudflare Workers AI"
        case ProviderID.localMLX: "本地 MLX"
        case ProviderID.auto: "自动（按顺序降级）"
        default: id
        }
    }

    static func routeName(_ id: String) -> String {
        switch id {
        case SettingsRoute.voice: "语音对话"
        case SettingsRoute.text: "文本 / 看截图"
        default: id
        }
    }

    static func routeSubtitle(_ id: String) -> String {
        switch id {
        case SettingsRoute.voice:
            "端到端 Realtime：服务端管 VAD 与打断，所以这一路不能走 Cloudflare。"
                + "只有一个候选，没有可切换的选项 —— 这里显示的是它通不通、凭据配没配好。"
        case SettingsRoute.text:
            "按下面的顺序降级；「自动」表示由 core 挑第一个能用的。"
        default: ""
        }
    }

    /// One line per status, saying what the user should do about it.
    static func statusLabel(_ status: String) -> String {
        switch status {
        case "ok": "可用"
        case "unconfigured": "缺凭据"
        case "unauthorized": "凭据被拒"
        case "quota_exhausted": "额度用尽"
        case "unreachable": "连不上"
        case "model_missing": "模型不在"
        case "starting": "正在启动"
        case "error": "出错"
        case "unknown": "未探测"
        default: "未知状态"
        }
    }

    /// The remedy, shown under the status when the core did not send a message
    /// of its own.
    static func statusAdvice(_ status: String) -> String? {
        switch status {
        case "ok", "unknown": nil
        case "unconfigured": "把凭据填在下面。"
        case "unauthorized": "换一个 token，或者补上权限。"
        case "quota_exhausted": "等额度重置，或者切到本地。"
        case "unreachable": "检查网络。"
        case "model_missing": "换个模型 id，或者等权重下载完。"
        case "starting": "正在加载权重，稍后再试。"
        case "error": "看上面这一行。"
        default: "core 报了一个这个版本不认识的状态：\(status)。"
        }
    }

    /// Traffic-light bucket. `unknown`/unrecognised deliberately land in the
    /// neutral bucket rather than the red one — never having probed is not a
    /// failure, and neither is a status this build predates.
    enum Severity { case good, warn, bad, neutral }

    static func severity(_ status: String) -> Severity {
        switch status {
        case "ok": .good
        case "starting": .warn
        case "unconfigured", "unauthorized", "quota_exhausted", "unreachable", "model_missing", "error": .bad
        default: .neutral
        }
    }

    static func capabilityLine(_ capabilities: ProviderCapabilitiesPayload?) -> String? {
        guard let capabilities else { return nil }
        var parts: [String] = []
        parts.append(capabilities.vision ? "能看图" : "只有文本")
        if capabilities.tools { parts.append("工具调用") }
        if capabilities.streaming { parts.append("流式") }
        parts.append("上下文 \(compactTokens(capabilities.contextTokens))")
        if let maximum = capabilities.maxOutputTokens {
            parts.append("单次输出 \(compactTokens(maximum))")
        }
        parts.append(capabilities.local ? "本机推理" : "走网络")
        return parts.joined(separator: " · ")
    }

    static func compactTokens(_ tokens: Int) -> String {
        if tokens >= 1000, tokens % 1024 == 0 { return "\(tokens / 1024)K" }
        if tokens >= 1000 { return "\(tokens / 1000)K" }
        return "\(tokens)"
    }

    /// Quota, with every field optional: the CF numbers may not be reachable at
    /// all, in which case the core sends only `unit` and `note` (§3.9).
    static func quotaLine(_ quota: QuotaSnapshotPayload?) -> String? {
        guard let quota else { return nil }
        var parts: [String] = []
        if let remaining = quota.remaining {
            if let limit = quota.limit {
                parts.append("剩余 \(number(remaining)) / \(number(limit)) \(quota.unit)")
            } else {
                parts.append("剩余 \(number(remaining)) \(quota.unit)")
            }
        } else if let used = quota.used {
            if let limit = quota.limit {
                parts.append("已用 \(number(used)) / \(number(limit)) \(quota.unit)")
            } else {
                parts.append("已用 \(number(used)) \(quota.unit)")
            }
        }
        if let resetsAt = quota.resetsAt, resetsAt > 0 {
            let date = Date(timeIntervalSince1970: Double(resetsAt) / 1000)
            parts.append("\(Self.stamp(date)) 重置")
        }
        if let note = quota.note, !note.isEmpty { parts.append(note) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func number(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15
            ? String(Int64(value))
            : String(format: "%.1f", value)
    }

    /// "从没探测过" is a different sentence from a timestamp, and `checkedAt: 0`
    /// is how the protocol says it.
    static func checkedLine(_ checkedAt: Int64, latencyMs: Int?) -> String {
        guard checkedAt > 0 else { return "还没探测过" }
        let date = Date(timeIntervalSince1970: Double(checkedAt) / 1000)
        let stamp = Self.stamp(date)
        if let latencyMs { return "\(stamp) 探测 · \(latencyMs)ms" }
        return "\(stamp) 探测"
    }

    /// The provider picker's entries for a route: `auto`, then the candidates in
    /// fallback order, plus a `selected` the core reports that is not among them
    /// (otherwise showing the picker would silently move the user's choice).
    static func providerOptions(candidates: [String], selected: String?) -> [String] {
        var ids = [ProviderID.auto]
        ids.append(contentsOf: candidates)
        if let selected, !ids.contains(selected) { ids.append(selected) }
        return ids
    }

    /// Whether the route has anything to choose *between*.
    ///
    /// A one-candidate route offers two entries that mean the same thing —
    /// "自动（按顺序降级）" and the only provider there is. That is the switch
    /// docs/protocol.md §3.9 argues against building, in its worst form: the
    /// user reads two names, assumes they differ, and goes looking for which one
    /// is better. Voice is that route today (`dashscope-realtime` is its only
    /// candidate, and §3.9 says the row exists to show connectivity and whether
    /// the credential is set, not to switch anything). The rule is on the shape
    /// of the data rather than on the route id, so the picker comes back by
    /// itself if a second voice provider ever does.
    static func offersProviderChoice(candidates: [String], selected: String?) -> Bool {
        providerOptions(candidates: candidates, selected: selected).count > 2
    }

    /// What the user picked versus what is actually serving. They differ after
    /// an automatic fallback, and that difference is the thing the settings
    /// window exists to make visible.
    ///
    /// **`auto` is the case that has to work**, because it is the default: under
    /// `auto` the user never named a provider, so "当前在用：本地 MLX" has
    /// nothing to be surprising against and a silent fallback reads as a normal
    /// day. The comparison that does exist is against the head of `candidates`,
    /// which the protocol defines as the fallback order (docs/protocol.md §3.9)
    /// — so under `auto`, "serving anyone but the first candidate" *is* the
    /// fallback, and gets said out loud.
    static func activeLine(selected: String, active: String?,
                           candidates: [ProviderHealthPayload]) -> String {
        guard let active else { return "当前没有可用的 provider。" }
        if selected == ProviderID.auto {
            guard let preferred = candidates.first, preferred.provider != active else {
                return "当前在用：\(providerName(active))"
            }
            return "\(providerName(preferred.provider))\(demotionReason(preferred.status))，"
                + "已自动降级到 \(providerName(active))。当前在用：\(providerName(active))"
        }
        if selected == active {
            return "当前在用：\(providerName(active))"
        }
        return "当前在用：\(providerName(active))（你选的是 \(providerName(selected))，已自动降级）"
    }

    /// Why the head of the fallback order is not the one serving.
    ///
    /// `ok` and `unknown` are reachable here and are not a contradiction: the
    /// router demotes on a live failure, and `status` is the last thing that was
    /// actually *observed* — a probe that has not run yet has not caught up.
    /// They get a sentence that claims no more than is known.
    static func demotionReason(_ status: String) -> String {
        switch status {
        case "ok", "unknown": "暂时用不了"
        default: statusLabel(status)
        }
    }

    /// What the Keychain items are actually protected by, which is not what the
    /// code asks for unless the build is signed.
    ///
    /// This is in the window rather than only in a comment because it is the
    /// window that makes the user believe something: they type a token into it,
    /// it says "已保存到钥匙串", and every ordinary reading of that sentence is
    /// stronger than what an unsigned build can deliver.
    static func keychainProtectionLine(dataProtection: Bool) -> String {
        dataProtection
            ? "凭据在数据保护钥匙串里：仅本机、解锁后可读（kSecAttrAccessible 生效）。"
            : "凭据在登录钥匙串里。这份构建没有 Apple Developer 签名，用不了数据保护钥匙串，"
                + "所以 kSecAttrAccessible（仅本机、解锁后可读）实际不生效，"
                + "保护退化成按代码签名匹配的 ACL —— 重新编译一次就会变，"
                + "也是每次弹「akari 想访问钥匙串」的原因。跟 core 的对端校验卡在同一件事上：缺 Team ID。"
    }

    /// `Date.FormatStyle` rather than a shared `DateFormatter`: a static
    /// formatter is mutable shared state that Swift 6 would have to be told to
    /// ignore, and this one is not on any hot path.
    private static func stamp(_ date: Date) -> String {
        date.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute())
    }
}

// MARK: - Avatar

/// Where her body actually sits inside one clip's frame, measured.
///
/// Copied from `assets/akari/anchors.json`, in the normalised 810x1080 canvas
/// every clip shares after `tools/anchor/normalize`. `y` is measured from the
/// **top** of the canvas, the way the anchor tool reports it.
///
/// This table exists so the settings preview can be honest. See
/// `AvatarGrounding.caveat`: the four states do not end at the same height, and
/// a preview that drew one idealised rectangle would be promising an alignment
/// the footage does not have.
struct AvatarBodyBox: Equatable, Sendable {
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat

    /// The canvas the numbers are expressed in.
    static let canvas = CGSize(width: 810, height: 1080)

    /// Empty space between the bottom of her body and the bottom of the frame,
    /// in canvas units. This is the whole problem: 1 for `idle`, 111 for
    /// `listening`.
    var bottomGap: CGFloat { Self.canvas.height - (y + height) }

    /// The same box as fractions of the canvas, ready to multiply by a drawn box.
    func normalized() -> CGRect {
        CGRect(x: x / Self.canvas.width, y: y / Self.canvas.height,
               width: width / Self.canvas.width, height: height / Self.canvas.height)
    }
}

/// The known, unfixed alignment defect and the numbers behind it.
enum AvatarGrounding {
    /// Measured bodies, per state. `talking` is absent because there is no
    /// `talking.mov` in the shipped assets (`AvatarPlayer` falls back to another
    /// clip for it), and inventing a row for it would be inventing a measurement.
    static let boxes: [AvatarState: AvatarBodyBox] = [
        .idle: AvatarBodyBox(x: 124, y: 152, width: 617, height: 927),
        .greeting: AvatarBodyBox(x: 188, y: 164, width: 547, height: 889),
        .listening: AvatarBodyBox(x: 114, y: 152, width: 645, height: 817),
        .thinking: AvatarBodyBox(x: 142, y: 164, width: 569, height: 819),
    ]

    /// The states the preview can draw truthfully, in the order they read best.
    static let previewStates: [AvatarState] = [.idle, .greeting, .listening, .thinking]

    static func box(_ state: AvatarState) -> AvatarBodyBox? { boxes[state] }

    static func stateName(_ state: AvatarState) -> String {
        switch state {
        case .idle: "待机"
        case .listening: "在听你说"
        case .thinking: "在想"
        case .talking: "在说话"
        case .greeting: "打招呼"
        }
    }

    /// How far off the bottom of her box she floats, in screen points, for an
    /// avatar box of `boxHeight` points.
    static func gapPoints(_ state: AvatarState, boxHeight: CGFloat) -> CGFloat {
        guard let box = box(state), boxHeight > 0 else { return 0 }
        return (box.bottomGap / AvatarBodyBox.canvas.height * boxHeight).rounded()
    }

    /// The one line under the preview. Always a number, never an adjective — the
    /// point is that the user can compare states before choosing a size.
    static func gapLine(_ state: AvatarState, boxHeight: CGFloat) -> String {
        guard box(state) != nil else {
            return "\(stateName(state))：没有实测数据（素材里没有这一段，播放时会回退到别的片子）。"
        }
        let gap = gapPoints(state, boxHeight: boxHeight)
        let idle = gapPoints(.idle, boxHeight: boxHeight)
        if state == .idle {
            return "待机：脚底离画面底边约 \(Int(gap))pt，基本贴住。"
        }
        return "\(stateName(state))：脚底离画面底边约 \(Int(gap))pt，"
            + "比待机高 \(Int(max(gap - idle, 0)))pt —— 切过来时她会往上抬这么多。"
    }

    /// Why it is like that, and that it is not being fixed this round.
    ///
    /// Kept out of the main flow (it lives under a disclosure in the preview) but
    /// present in full: the preview draws the real numbers, so the user *will*
    /// see her lift between states, and an unexplained jump reads as a bug the
    /// user should report.
    static let caveat =
        "四段素材是按**人脸**对齐归一化的，而每段里她的身体长度不一样，"
        + "所以人脸对齐与底部对齐没法同时成立 —— 这是素材层面的取舍，本轮不修。"
        + "实测底部留白：待机 1px、打招呼 27px、在想 97px、在听 111px（以 1080 高的画面计）。"
        + "上面的预览按这些实测值画，不会替它遮掩。"
}

extension SettingsDisplay {
    // MARK: Layer mode

    static func avatarModeName(_ mode: AvatarLayerMode) -> String {
        switch mode {
        case .desktop: "桌面层"
        case .floating: "浮动层"
        }
    }

    /// The line next to the radio button. Never the bare noun: "桌面层" means
    /// nothing to somebody who has not read the window-level dump.
    static func avatarModeHeadline(_ mode: AvatarLayerMode) -> String {
        switch mode {
        case .desktop: "桌面层 · 像壁纸的一部分"
        case .floating: "浮动层 · 始终浮在最上面"
        }
    }

    static func avatarModeExplanation(_ mode: AvatarLayerMode) -> String {
        switch mode {
        case .desktop:
            "她画在壁纸和桌面图标之间，所以**任何窗口都会盖住她**。"
                + "屏幕被窗口占满的时候，她等于不在。好处是她不占用任何可用空间，"
                + "回到空桌面就又看见她。"
        case .floating:
            // "全屏时也在" is stated narrowly on purpose: DesktopWindow.swift measured
            // `.fullScreenAuxiliary` over an ordinary AppKit full-screen space, and
            // says full-screen *app bundles* and games are not verified yet.
            "她浮在所有普通窗口之上，**不会被挡住**，普通 App 全屏时也在。"
                + "代价是她一直占住屏幕的一角，压在底下的窗口内容上面。"
                + "鼠标点击照常穿过她落到下面的窗口上，她不会抢焦点。"
                + "（Dock、菜单栏、通知横幅仍然在她前面。）"
        }
    }

    // MARK: Anchor

    static func anchorName(_ anchor: AvatarPlacement.Anchor) -> String {
        switch anchor {
        case .topLeading: "左上"
        case .topCenter: "顶部居中"
        case .topTrailing: "右上"
        case .centerLeading: "左侧居中"
        case .center: "正中"
        case .centerTrailing: "右侧居中"
        case .bottomLeading: "左下"
        case .bottomCenter: "底部居中"
        case .bottomTrailing: "右下"
        }
    }

    /// The nine anchors laid out the way they sit on screen, so the picker can be
    /// a grid rather than a list. Chunked from `allCases`, which
    /// `AvatarPlacement.Anchor` declares in reading order for exactly this.
    static var anchorGrid: [[AvatarPlacement.Anchor]] {
        let all = AvatarPlacement.Anchor.allCases
        return stride(from: 0, to: all.count, by: 3).map { start in
            Array(all[start..<min(start + 3, all.count)])
        }
    }

    /// The one caveat worth stating about an anchor, when there is one.
    static func anchorNote(_ anchor: AvatarPlacement.Anchor) -> String? {
        switch anchor.verticalPosition {
        case -1 where anchor == .bottomTrailing:
            "右下角与桌面图标冲突最少：macOS 的图标是从右上往下排的。"
        case -1:
            nil
        default:
            "素材是半身像，本来靠跑出屏幕下边缘来藏住腰以下。"
                + "离开底边会把整个人挪进画面里，下缘会看到切口。"
        }
    }

    // MARK: Size

    /// Sensible slider bounds per mode. Two ranges rather than one because 55%
    /// is right on the desktop layer and absurd on top of everything.
    static func avatarHeightRange(_ mode: AvatarLayerMode) -> ClosedRange<CGFloat> {
        switch mode {
        case .desktop: 0.20...1.0
        case .floating: 0.08...0.50
        }
    }

    static func avatarHeightLabel(_ fraction: CGFloat, displayHeight: CGFloat) -> String {
        let percent = Int((fraction * 100).rounded())
        guard displayHeight > 0 else { return "屏幕高度的 \(percent)%" }
        return "屏幕高度的 \(percent)% · 约 \(Int((displayHeight * fraction).rounded()))pt 高"
    }

    // MARK: Displays

    static func avatarScopeName(_ scope: AvatarDisplayScope) -> String {
        switch scope {
        case .allDisplays: "每块屏都有"
        case .mainDisplayOnly: "只在主屏"
        }
    }

    static func avatarScopeExplanation(_ scope: AvatarDisplayScope, mode: AvatarLayerMode) -> String {
        switch scope {
        case .allDisplays:
            "每块显示器上都有一个她。每块屏各自解码一路视频，CPU 大致按屏数翻倍"
                + "（实测单屏 2.3–5.2%）；被完全挡住的那块会自动暂停。"
                + (mode == .floating ? "浮动形态下，这意味着两块屏各被占掉一角。" : "")
        case .mainDisplayOnly:
            "只出现在菜单栏所在的那块屏上，其余屏幕完全干净。"
        }
    }

    // MARK: Wallpaper

    static let wallpaperConsentTitle = "让 akari 换掉你现在的桌面壁纸？"

    static let wallpaperConsentBody =
        "akari 会把桌面壁纸换成配套的那张，并先把你**现在这张**记下来。"
        + "之后随时可以按「恢复我原来的壁纸」换回去。"
        + "这会真的改动系统的桌面图片设置，不只是 akari 自己的显示。"

    /// - Parameters:
    ///   - canRestore: pressing 恢复 would really put the user's wallpaper back.
    ///   - replaced: akari's artwork is on the desktop as far as the app knows.
    ///
    /// The two are not the same, and the gap between them is the only state this
    /// line must never fudge: over a dynamic wallpaper akari *did* change the
    /// desktop and *cannot* change it back, so neither "备份好了，随时换回去"
    /// nor "还没换过你的壁纸" is true.
    static func wallpaperStatusLine(enabled: Bool, canRestore: Bool,
                                    replaced: Bool, wired: Bool) -> String {
        if !wired {
            return "壁纸功能在这份构建里还没接上：开关只会记住你的偏好，桌面不会真的改变。"
        }
        if canRestore {
            return enabled
                ? "正在用配套壁纸。你原来那张已经备份，随时可以换回去。"
                : "已经不再自动应用配套壁纸，但桌面上现在这张是 akari 换的 —— 要换回你自己的，按下面的按钮。"
        }
        if replaced {
            return "桌面上现在这张是 akari 换的。你换之前用的是动态壁纸，"
                + "macOS 不允许第三方 App 设置它 —— akari 恢复不了，"
                + "请去「系统设置 › 墙纸」自己重新选一次。"
        }
        return enabled
            ? "还没有备份记录：akari 在这台机器上还没有换过壁纸。"
            : "不会碰你的桌面壁纸。"
    }
}
