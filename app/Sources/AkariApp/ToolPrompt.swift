import AppKit

/// The confirmation gate's UI half (ADR-002, protocol.md §3.5).
///
/// The core decides *that* a card is needed and *what* it says; this file only
/// draws it and reports the verdict back. Two shapes:
///
///   RED    a card with the verbatim command and 允许 / 拒绝. It must be answered.
///   YELLOW a toast saying the tool already ran, with 撤销 for `undoMs`.
///
/// Everything is a `.nonactivatingPanel`: akari is an `.accessory` app that
/// draws on the desktop, and a prompt must not yank focus out of whatever the
/// user is typing in. Clicks still land — only activation is suppressed.
@MainActor
final class ToolPromptPresenter {
    private var cards: [String: ConfirmCardWindow] = [:]
    private var toasts: [String: UndoToastWindow] = [:]

    /// Show a RED card. `decide` is called exactly once — by a button, by the
    /// timeout, or by `dismissAll()` when the socket drops.
    func showConfirm(_ payload: ToolConfirmRequestPayload,
                     decide: @escaping (ConfirmDecision) -> Void) {
        // A repeated requestId can only be a core-side bug; answering the old
        // card first keeps the executor from waiting forever on the loser.
        if let existing = cards.removeValue(forKey: payload.requestId) {
            existing.finish(.deny)
        }

        let card = ConfirmCardWindow(payload: payload) { [weak self] decision in
            guard let self else { return }
            self.cards.removeValue(forKey: payload.requestId)
            decide(decision)
        }
        cards[payload.requestId] = card
        card.present()
    }

    /// Show a YELLOW toast. `undo` fires only if the user clicks 撤销 inside the
    /// window; a toast that simply expires reports nothing (protocol.md §3.5).
    func showUndoable(_ payload: ToolUndoablePayload, undo: @escaping () -> Void) {
        if let existing = toasts.removeValue(forKey: payload.requestId) {
            existing.dismiss()
        }
        let toast = UndoToastWindow(payload: payload) { [weak self] undone in
            guard let self else { return }
            self.toasts.removeValue(forKey: payload.requestId)
            if undone { undo() }
        }
        toasts[payload.requestId] = toast
        toast.present()
    }

    /// protocol.md §六: a dropped connection settles every pending card as deny.
    func dismissAll() {
        for (_, card) in cards { card.finish(.deny) }
        cards.removeAll()
        for (_, toast) in toasts { toast.dismiss() }
        toasts.removeAll()
    }
}

// MARK: - RED card

/// Everything about "may this card be approved yet" that does not need an
/// `NSWindow`, so the rules can be exercised in tests.
///
/// The gate has two independent locks and approval needs both open:
///
///   * **anti-misclick** — the card appears under the pointer and the thing behind
///     it may be mid-double-click. A card that is instantly clickable turns a stray
///     second click into "yes, run that shell command".
///   * **fully read** — protocol.md §3.5 requires the command to be shown verbatim,
///     and a command taller than the box is not shown until it has been scrolled.
struct ConfirmGate {
    /// How long the card stays visible-but-unapprovable.
    static let armDelay: Duration = .milliseconds(600)

    /// A click landing this soon after the card appeared (or after the previous
    /// such click) is treated as spill-over from what the user was doing before.
    static let clickGuard: Duration = .milliseconds(300)

    static let minCommandBoxHeight: CGFloat = 96
    static let maxCommandBoxHeight: CGFloat = 320

    var isArmed = false
    var commandLineCount = 0
    /// The command is taller than the box, i.e. part of it is off-screen.
    var isCommandClipped = false
    /// The user has scrolled the command box to its end.
    var hasReadToEnd = true

    var canApprove: Bool { isArmed && (!isCommandClipped || hasReadToEnd) }

    /// Why 允许 is greyed out, or nil when it is not.
    var hint: String? {
        if isCommandClipped && !hasReadToEnd {
            return "命令共 \(commandLineCount) 行，请滚动看完"
        }
        if !isArmed { return "防误触保护中，稍候即可批准" }
        return nil
    }

    /// The command box grows with the command instead of cropping it at a fixed
    /// 96pt, but stops before the card outgrows the screen.
    static func commandBoxHeight(forContentHeight height: CGFloat) -> CGFloat {
        min(max(height.rounded(.up), minCommandBoxHeight), maxCommandBoxHeight)
    }
}

/// Panel that reports esc as a *denial*. `keyEquivalent` can only bind one key per
/// button and 拒绝 spends it on being the default button, so esc is picked up here.
@MainActor
private final class ConfirmPanel: NSPanel {
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

@MainActor
final class ConfirmCardWindow {
    private let panel: ConfirmPanel
    private let payload: ToolConfirmRequestPayload
    private let decide: (ConfirmDecision) -> Void
    private var timeoutTask: Task<Void, Never>?
    private var settled = false

    private let approve: NSButton
    private let deny: NSButton
    private let hintLabel: NSTextField
    private let commandScroll: NSScrollView?

    private var gate = ConfirmGate()
    private var armTask: Task<Void, Never>?
    private var armStartedAt = ContinuousClock.now
    private var clickMonitor: Any?
    private var scrollObserver: (any NSObjectProtocol)?

    /// Card is a fixed 420pt wide so the command box has a width to lay out
    /// against; without it `fittingSize` lets a long title stretch the card.
    private static let cardWidth: CGFloat = 420
    private static let cardInset: CGFloat = 18

    init(payload: ToolConfirmRequestPayload, decide: @escaping (ConfirmDecision) -> Void) {
        self.payload = payload
        self.decide = decide

        let contentWidth = Self.cardWidth - Self.cardInset * 2

        panel = ConfirmPanel(contentRect: NSRect(x: 0, y: 0, width: Self.cardWidth, height: 10),
                             styleMask: [.titled, .nonactivatingPanel, .utilityWindow],
                             backing: .buffered,
                             defer: false)
        // Same rule as the desktop windows: the default over-releases and
        // crashes on close with a layer-backed content view.
        panel.isReleasedWhenClosed = false
        panel.title = "akari 需要你确认"
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let title = NSTextField(labelWithString: payload.title)
        title.font = .boldSystemFont(ofSize: 14)
        title.lineBreakMode = .byWordWrapping
        // Not truncated: the title is the one-line summary of what is about to run.
        title.maximumNumberOfLines = 0
        title.preferredMaxLayoutWidth = contentWidth

        let stack = NSStackView(views: [title])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: Self.cardInset,
                                        bottom: 14, right: Self.cardInset)

        if let detail = payload.detail, !detail.isEmpty {
            let label = NSTextField(wrappingLabelWithString: detail)
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            label.preferredMaxLayoutWidth = contentWidth
            stack.addArrangedSubview(label)
        }

        var scroll: NSScrollView?
        if let command = payload.command, !command.isEmpty {
            // Verbatim, never trimmed or prettified: approving something other
            // than what runs is the whole failure mode this gate exists for.
            let text = NSTextView()
            text.string = command
            text.isEditable = false
            text.isSelectable = true
            text.drawsBackground = false
            text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            text.textContainerInset = NSSize(width: 8, height: 8)
            // Wrap to the card width and grow downwards, so `sizeToFit` reports the
            // height the whole command actually needs.
            text.isHorizontallyResizable = false
            text.isVerticallyResizable = true
            text.autoresizingMask = [.width]
            text.minSize = NSSize(width: 0, height: 0)
            text.maxSize = NSSize(width: contentWidth, height: .greatestFiniteMagnitude)
            text.textContainer?.widthTracksTextView = true
            text.textContainer?.containerSize =
                NSSize(width: contentWidth, height: .greatestFiniteMagnitude)
            text.frame = NSRect(x: 0, y: 0, width: contentWidth,
                                height: ConfirmGate.minCommandBoxHeight)
            text.sizeToFit()

            let box = NSScrollView()
            box.documentView = text
            box.hasVerticalScroller = true
            box.autohidesScrollers = false
            box.drawsBackground = true
            box.backgroundColor = .textBackgroundColor
            box.borderType = .lineBorder
            box.translatesAutoresizingMaskIntoConstraints = false
            box.heightAnchor.constraint(
                equalToConstant: ConfirmGate.commandBoxHeight(forContentHeight: text.frame.height)
            ).isActive = true
            box.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
            stack.addArrangedSubview(box)
            scroll = box

            gate.commandLineCount = command.split(separator: "\n", omittingEmptySubsequences: false).count
        }
        commandScroll = scroll

        deny = NSButton(title: "拒绝", target: nil, action: nil)
        // The destructive answer must never be the one the return key picks;
        // 拒绝 is both the default button and (via ConfirmPanel) the esc answer.
        deny.keyEquivalent = "\r"
        approve = NSButton(title: "允许", target: nil, action: nil)
        approve.isEnabled = false

        hintLabel = NSTextField(labelWithString: "")
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .systemOrange
        hintLabel.lineBreakMode = .byTruncatingTail
        hintLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let buttons = NSStackView(views: [hintLabel, NSView(), deny, approve])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(buttons)
        buttons.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true

        panel.contentView = stack
        panel.setContentSize(stack.fittingSize)

        deny.target = self
        deny.action = #selector(denyPressed)
        approve.target = self
        approve.action = #selector(approvePressed)
        panel.onCancel = { [weak self] in self?.finish(.deny) }

        if let scroll {
            scroll.contentView.postsBoundsChangedNotifications = true
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scroll.contentView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshScrollProgress() }
            }
        }
    }

    func present() {
        panel.center()
        panel.orderFrontRegardless()
        panel.contentView?.layoutSubtreeIfNeeded()

        startArming()
        watchForStrayClicks()
        refreshScrollProgress()

        // 0 = wait forever (protocol.md §3.5).
        guard payload.timeoutMs > 0 else { return }
        let millis = payload.timeoutMs
        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(millis))
            guard !Task.isCancelled else { return }
            self?.finish(.timeout)
        }
    }

    /// Idempotent: whichever of button, timeout or teardown gets here first wins.
    func finish(_ decision: ConfirmDecision) {
        guard !settled else { return }
        settled = true
        timeoutTask?.cancel()
        timeoutTask = nil
        armTask?.cancel()
        armTask = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        scrollObserver = nil
        panel.orderOut(nil)
        panel.close()
        decide(decision)
    }

    // MARK: Approval gate

    /// (Re)start the window during which the card is readable but not approvable.
    private func startArming() {
        armTask?.cancel()
        gate.isArmed = false
        armStartedAt = .now
        refreshApproveState()
        armTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: ConfirmGate.armDelay)
            guard !Task.isCancelled, let self, !self.settled else { return }
            self.gate.isArmed = true
            // Text layout has certainly happened by now, so this is the reliable
            // moment to decide whether the command is clipped.
            self.refreshScrollProgress()
        }
    }

    /// A click arriving in the first few hundred milliseconds is discarded and the
    /// arming window restarts, so the second half of a double-click aimed at
    /// something else can never approve anything.
    private func watchForStrayClicks() {
        clickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            MainActor.assumeIsolated { self?.handleStrayMouseDown() }
            return event
        }
    }

    /// Body of that monitor, named so the rule can be exercised without pushing a
    /// synthetic mouse event through the run loop.
    func handleStrayMouseDown() {
        guard !settled, !gate.isArmed else { return }
        guard ContinuousClock.now - armStartedAt < ConfirmGate.clickGuard else { return }
        startArming()
    }

    /// Recompute "is any of the command still off-screen, and has the user seen it".
    private func refreshScrollProgress() {
        if let scroll = commandScroll, let document = scroll.documentView {
            let visible = scroll.contentView.bounds
            let clipped = document.frame.height - visible.height > 1
            gate.isCommandClipped = clipped
            gate.hasReadToEnd = !clipped || visible.maxY >= document.frame.height - 2
        }
        refreshApproveState()
    }

    private func refreshApproveState() {
        approve.isEnabled = gate.canApprove
        let hint = gate.hint
        hintLabel.stringValue = hint ?? ""
        hintLabel.isHidden = hint == nil
    }

    @objc private func approvePressed() {
        // Belt and braces: the button is disabled until the gate opens, but a
        // synthesized or queued click must not slip past either.
        guard gate.canApprove else { return }
        finish(.approve)
    }

    @objc private func denyPressed() { finish(.deny) }

    // MARK: Test hooks

    var isApproveEnabled: Bool { approve.isEnabled }

    /// What the return key answers, if anything. Must never be `.approve`.
    ///
    /// AppKit moves a "\r" key equivalent off the button and onto the window as
    /// its `defaultButtonCell` once the button is installed, so both places count.
    var returnKeyAnswer: ConfirmDecision? {
        let defaultCell = panel.defaultButtonCell
        if approve.keyEquivalent == "\r" || defaultCell === approve.cell { return .approve }
        if deny.keyEquivalent == "\r" || defaultCell === deny.cell { return .deny }
        return nil
    }

    /// Same path esc takes.
    func cancelForTesting() { panel.cancelOperation(nil) }

    /// Same path a click on 允许 takes.
    func approveForTesting() { approvePressed() }
    var currentHint: String? { gate.hint }
    var commandBoxHeight: CGFloat { commandScroll?.frame.height ?? 0 }

    /// Scrolls the command box to its end, exactly as dragging the scroller would.
    func scrollCommandToEnd() {
        guard let scroll = commandScroll, let document = scroll.documentView else { return }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.frame.height - scroll.contentView.bounds.height)))
        scroll.reflectScrolledClipView(scroll.contentView)
        refreshScrollProgress()
    }
}

// MARK: - YELLOW toast

@MainActor
private final class UndoToastWindow {
    private let panel: NSPanel
    private let payload: ToolUndoablePayload
    private let done: (Bool) -> Void
    private var timer: Task<Void, Never>?
    private var settled = false

    init(payload: ToolUndoablePayload, done: @escaping (Bool) -> Void) {
        self.payload = payload
        self.done = done

        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 10),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered,
                        defer: false)
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let label = NSTextField(labelWithString: payload.title)
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail

        let button = NSButton(title: "撤销", target: nil, action: nil)
        button.bezelStyle = .accessoryBarAction

        let row = NSStackView(views: [label, NSView(), button])
        row.orientation = .horizontal
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 12)

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true

        row.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            row.topAnchor.constraint(equalTo: background.topAnchor),
            row.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])

        panel.contentView = background
        panel.setContentSize(NSSize(width: 320, height: row.fittingSize.height))

        button.target = self
        button.action = #selector(undoPressed)
    }

    func present() {
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 24,
                                         y: visible.minY + 24))
        }
        panel.orderFrontRegardless()

        let millis = max(0, payload.undoMs)
        timer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(millis))
            guard !Task.isCancelled else { return }
            self?.settle(false)
        }
    }

    func dismiss() { settle(false) }

    private func settle(_ undone: Bool) {
        guard !settled else { return }
        settled = true
        timer?.cancel()
        timer = nil
        panel.orderOut(nil)
        panel.close()
        done(undone)
    }

    @objc private func undoPressed() { settle(true) }
}
