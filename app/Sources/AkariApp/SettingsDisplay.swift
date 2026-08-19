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
