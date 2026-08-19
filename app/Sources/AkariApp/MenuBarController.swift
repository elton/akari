import AppKit

/// The `NSStatusItem` and its menu. Pure UI: it reports intent through the
/// callbacks and holds no business state.
@MainActor
final class MenuBarController: NSObject {
    var onQuit: (() -> Void)?
    var onToggleVisible: ((Bool) -> Void)?
    var onOpenSettings: (() -> Void)?
    /// Menu-driven push-to-talk, for when the hotkey is unavailable.
    var onTalkPressed: (() -> Void)?
    var onTalkReleased: (() -> Void)?

    private var statusItem: NSStatusItem?
    private let statusLine = NSMenuItem(title: "core: 未连接", action: nil, keyEquivalent: "")
    private let talkItem = NSMenuItem(title: "开始说话", action: nil, keyEquivalent: "")
    private let visibilityItem = NSMenuItem(title: "隐藏她", action: nil, keyEquivalent: "")

    /// A menu cannot report key-down and key-up separately, so menu-driven
    /// push-to-talk is a toggle: the item starts the turn and ends it.
    private var isTalking = false
    private var isVisible = true

    /// What the status line says when no notice is on screen.
    private var coreStatus = "core: 未连接"
    private var noticeTimer: Timer?

    /// Install the status item. Call once, on the main thread, after launch.
    func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = Self.icon(for: .idle)
        item.button?.image?.isTemplate = true
        item.button?.toolTip = "akari"

        let menu = NSMenu()
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        talkItem.target = self
        talkItem.action = #selector(toggleTalk)
        talkItem.keyEquivalent = " "
        talkItem.keyEquivalentModifierMask = [.option]
        menu.addItem(talkItem)

        visibilityItem.target = self
        visibilityItem.action = #selector(toggleVisible)
        menu.addItem(visibilityItem)

        let settings = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 akari", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
    }

    func remove() {
        noticeTimer?.invalidate()
        noticeTimer = nil
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    /// Reflect the connection state of the core in the menu (e.g. "core: 未连接").
    func setCoreStatus(_ text: String) {
        coreStatus = text
        if noticeTimer == nil { statusLine.title = text }
    }

    /// Put a core-sent line (`ui.notice`) in front of the user for a few
    /// seconds, then fall back to the connection status.
    ///
    /// The status line is the only text surface the app has, so a notice
    /// borrows it rather than adding a second one. The connection status is
    /// remembered — a notice arriving while the core is down must not leave the
    /// menu claiming everything is fine once it expires.
    func showNotice(_ text: String, for seconds: TimeInterval = 5) {
        statusLine.title = text
        noticeTimer?.invalidate()
        noticeTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
            MainActor.assumeIsolated {
                self.noticeTimer = nil
                self.statusLine.title = self.coreStatus
            }
        }
    }

    /// Reflect the avatar state in the status icon.
    func setAvatarState(_ state: AvatarState) {
        let image = Self.icon(for: state)
        image?.isTemplate = true
        statusItem?.button?.image = image
    }

    /// Called when the hotkey (not the menu) drives a turn, so the menu item
    /// title does not go stale.
    func setTalking(_ talking: Bool) {
        isTalking = talking
        talkItem.title = talking ? "停止说话" : "开始说话"
    }

    // MARK: Actions

    @objc private func toggleTalk() {
        setTalking(!isTalking)
        if isTalking { onTalkPressed?() } else { onTalkReleased?() }
    }

    @objc private func toggleVisible() {
        isVisible.toggle()
        visibilityItem.title = isVisible ? "隐藏她" : "显示她"
        onToggleVisible?(isVisible)
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }

    @objc private func quit() {
        onQuit?()
    }

    /// SF Symbols, so the icon follows the menu bar's own light/dark rendering.
    private static func icon(for state: AvatarState) -> NSImage? {
        let name: String
        switch state {
        case .idle: name = "moon.zzz"
        case .listening: name = "waveform"
        case .thinking: name = "ellipsis.circle"
        case .talking: name = "bubble.left.and.bubble.right"
        case .greeting: name = "hand.wave"
        }
        return NSImage(systemSymbolName: name, accessibilityDescription: "akari \(state.rawValue)")
    }
}
