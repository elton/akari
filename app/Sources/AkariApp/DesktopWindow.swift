//
//  DesktopWindow.swift — the wallpaper-layer window, and the set of them.
//
//  # Why level == CGWindowLevelForKey(.desktopIconWindow) - 1
//
//  macOS exposes no documented "wallpaper" window level, so the layer the avatar
//  has to live in can only be derived from what actually draws the desktop today.
//  Dumped from an external process with CGWindowListCopyWindowInfo on macOS 26.6.1
//  (M4 Max, two 5K displays) and cross-checked against ScreenCaptureKit's SCWindow:
//
//      Dock, window "Wallpaper-<UUID>"   -2147483624   the real wallpaper picture
//      〔the one gap we can occupy〕      -2147483604   .desktopIconWindow - 1
//      Finder desktop icons              -2147483603   .desktopIconWindow
//
//  Anything at or above the icon level draws on top of the user's desktop icons,
//  which reads as a floating pet rather than part of the desktop; anything at or
//  below the Dock's wallpaper window is painted over by the wallpaper itself. The
//  single slot between them is the product requirement, and it is exactly one
//  level wide — hence the literal `- 1` rather than a named constant.
//
//  The value is computed, never hard-coded: -2147483604 is what the arithmetic
//  happens to produce on this OS build, not a contract Apple publishes.
//
//  # Non-obvious constraints baked into this file (all measured, see RISK-2)
//
//  * `isReleasedWhenClosed` must be false. Its default is true, and with a
//    CoreAnimation layer attached the close path over-releases: a 28-round
//    teardown+rebuild stress run SIGSEGVs on round 2 with true and survives all
//    28 rounds with false. Display hot-plug and lid close/open take that path.
//  * `.stationary` is deliberately absent from collectionBehavior. With it, the
//    WindowServer applies a permanent uniform 98% scale about the window centre
//    (2560x1440 comes back as 2510x1412 @ 25,14; 1000x1000 becomes 980x980 —
//    scale, not inset). Without it the geometry is exact. That measurement was
//    taken on a locked machine, so it is not yet fully isolated; `.stationary`
//    stays out until the unlocked retest says otherwise.
//  * `constrainFrameRect` is overridden as cheap insurance only. It is NOT the
//    cure for the 98% scale — a window with no collectionBehavior at all got an
//    exact frame without the override.
//  * Occlusion must be sampled explicitly right after the window is ordered in.
//    `didChangeOcclusionStateNotification` only fires on a *change*, so a window
//    created while already covered never receives one and power saving would
//    silently never engage.
//

import AppKit
import QuartzCore

// MARK: - Placement

/// Where the avatar sits inside one display, and how big it is.
///
/// Expressed relative to the display rather than in absolute points so a single
/// value looks the same on a 5K panel and on the built-in laptop screen.
/// `frame(inDisplayOfSize:)` is pure — no AppKit or WindowServer state — so the
/// layout rules can be exercised in a test without a display attached.
struct AvatarPlacement: Equatable {
    enum Anchor: String, CaseIterable, Equatable {
        case bottomTrailing, bottomLeading, bottomCenter, topTrailing, topLeading
    }

    /// Which corner (or bottom edge) the avatar hugs. Bottom-right by default:
    /// it is the corner least likely to collide with desktop icons, which macOS
    /// fills from the top-right down.
    var anchor: Anchor = .bottomTrailing

    /// Avatar box height as a fraction of the display's height, clamped to
    /// 0.05...1.0 when the frame is computed.
    var heightFraction: CGFloat = 0.55

    /// width / height of the box. The default matches the shipped clips
    /// (926x994 after the bottom crop described in avatar-states.md §2.5).
    /// A mismatch is harmless: `AVPlayerLayer` uses `.resizeAspect`, so this only
    /// decides how much room the avatar is given, not how it is stretched.
    var aspectRatio: CGFloat = 926.0 / 994.0

    /// Distance from the anchored edges, in points. Ignored on the axis a
    /// centered anchor centers on.
    var margin: CGSize = CGSize(width: 48, height: 32)

    static let `default` = AvatarPlacement()

    /// The avatar's frame in the window's content coordinates (origin bottom-left,
    /// matching an unflipped layer-backed `NSView`).
    func frame(inDisplayOfSize size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }

        let fraction = min(max(heightFraction, 0.05), 1.0)
        let ratio = max(aspectRatio, 0.01)

        var height = (size.height * fraction).rounded()
        var width = (height * ratio).rounded()
        // Never let the box grow past the display it sits on, whatever was asked for.
        if width > size.width {
            width = size.width
            height = (width / ratio).rounded()
        }
        if height > size.height {
            height = size.height
            width = (height * ratio).rounded()
        }

        let insetX = min(margin.width, max(size.width - width, 0))
        let insetY = min(margin.height, max(size.height - height, 0))

        let x: CGFloat
        let y: CGFloat
        switch anchor {
        case .bottomTrailing:
            x = size.width - width - insetX
            y = insetY
        case .bottomLeading:
            x = insetX
            y = insetY
        case .bottomCenter:
            x = ((size.width - width) / 2).rounded()
            y = insetY
        case .topTrailing:
            x = size.width - width - insetX
            y = size.height - height - insetY
        case .topLeading:
            x = insetX
            y = size.height - height - insetY
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

// MARK: - Power-save gate

/// Everything that can make rendering pointless, in one value.
///
/// Pure and `Equatable` on purpose: the "should this display be decoding video
/// right now" decision is the part worth testing, and it needs no window server.
///
/// Rendering while nothing can be seen is not free — measured 3.77% CPU per
/// occluded display against 0.07% once the player is paused, and `AVQueuePlayer`
/// keeps decoding (its `currentTime` keeps advancing) unless it is told to stop.
struct RenderGate: Equatable {
    /// Set by the menu bar / battery policy through `DesktopWindowController.setPaused`.
    var isManuallyPaused = false
    var isScreenLocked = false
    var isScreenSaverRunning = false
    var areDisplaysAsleep = false

    private(set) var occludedDisplays: Set<CGDirectDisplayID> = []

    /// True when the session as a whole could show something.
    var isSessionRenderable: Bool {
        !isManuallyPaused && !isScreenLocked && !isScreenSaverRunning && !areDisplaysAsleep
    }

    func shouldRender(_ displayID: CGDirectDisplayID) -> Bool {
        isSessionRenderable && !occludedDisplays.contains(displayID)
    }

    mutating func setOccluded(_ occluded: Bool, for displayID: CGDirectDisplayID) {
        if occluded {
            occludedDisplays.insert(displayID)
        } else {
            occludedDisplays.remove(displayID)
        }
    }

    mutating func forget(_ displayID: CGDirectDisplayID) {
        occludedDisplays.remove(displayID)
    }
}

// MARK: - The window

/// Borderless, transparent, click-through window pinned to one display and sitting
/// on the desktop wallpaper layer. See the file header for why that level.
@MainActor
final class DesktopWindow: NSWindow {
    /// `.desktopIconWindow - 1`: below the Finder icons, above the wallpaper.
    static let desktopLevel = NSWindow.Level(
        rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)

    /// `.stationary` is intentionally not in this set — see the file header.
    static let desktopCollectionBehavior: NSWindow.CollectionBehavior =
        [.canJoinAllSpaces, .ignoresCycle, .fullScreenNone]

    /// The display this window is pinned to.
    let displayID: CGDirectDisplayID

    /// Changing this re-lays out the attached avatar layer immediately.
    var placement: AvatarPlacement {
        didSet {
            guard placement != oldValue else { return }
            layoutAvatarLayer()
        }
    }

    /// Owned by `AvatarPlayer`, not by us: held weakly so tearing the window down
    /// never decides the player's lifetime.
    private weak var avatarLayer: CALayer?

    init(screen: NSScreen, displayID: CGDirectDisplayID, placement: AvatarPlacement = .default) {
        self.displayID = displayID
        self.placement = placement
        super.init(contentRect: screen.frame,
                   styleMask: [.borderless],
                   backing: .buffered,
                   defer: false)

        level = Self.desktopLevel
        collectionBehavior = Self.desktopCollectionBehavior

        // Transparent: only the avatar's own pixels should be visible.
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false

        // Click-through and focus-proof. `ignoresMouseEvents` covers the whole
        // window rather than relying on per-pixel alpha hit testing (RISK-3), and
        // `canBecomeKey/Main` below keep it out of the responder chain entirely.
        ignoresMouseEvents = true
        isMovable = false
        isMovableByWindowBackground = false
        animationBehavior = .none

        // Non-negotiable — the default (true) over-releases with a CA layer
        // attached and crashes on the teardown path that display hot-plug uses.
        isReleasedWhenClosed = false

        // Lets external verification tools (CGWindowListCopyWindowInfo, SCWindow)
        // pick our windows out by name.
        title = "akari-desktop-\(displayID)"

        let content = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        content.wantsLayer = true
        content.layer?.isOpaque = false
        content.layer?.backgroundColor = NSColor.clear.cgColor
        contentView = content

        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Cheap insurance against AppKit shrinking a borderless frame to the "usable"
    /// area. Not the fix for the `.stationary` 98% scale — see the file header.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    /// Host `layer` as the content view's backing layer.
    ///
    /// Contract: we set the layer's `frame` and `contentsScale`. Laying out
    /// whatever is inside it (`AvatarPlayer` keeps two `AVPlayerLayer`s there) is
    /// the layer's own job — a plain `CALayer` does not resize its sublayers.
    func attach(_ layer: CALayer) {
        guard let host = contentView?.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let previous = avatarLayer, previous !== layer {
            previous.removeFromSuperlayer()
        }
        layer.removeFromSuperlayer()
        host.addSublayer(layer)
        avatarLayer = layer
        apply(placement, to: layer)
        CATransaction.commit()
    }

    /// Give the layer back to its owner without closing the window.
    func detachAvatarLayer() {
        avatarLayer?.removeFromSuperlayer()
        avatarLayer = nil
    }

    /// Re-apply the frame after a resolution or arrangement change.
    func updateFrame(for screen: NSScreen) {
        setFrame(screen.frame, display: true)
        contentView?.frame = CGRect(origin: .zero, size: screen.frame.size)
        layoutAvatarLayer()
    }

    /// Show without activating the app or taking focus.
    func show() {
        orderFrontRegardless()
    }

    /// Order out and close. Safe only because `isReleasedWhenClosed` is false.
    func teardown() {
        detachAvatarLayer()
        orderOut(nil)
        close()
    }

    /// The authoritative "is anything of this window on screen" reading.
    var isRenderVisible: Bool {
        occlusionState.contains(.visible)
    }

    private func layoutAvatarLayer() {
        guard let layer = avatarLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        apply(placement, to: layer)
        CATransaction.commit()
    }

    private func apply(_ placement: AvatarPlacement, to layer: CALayer) {
        // Without this the video is rendered at 1x and looks soft on the 2x panels.
        layer.contentsScale = backingScaleFactor
        let size = contentView?.bounds.size ?? frame.size
        layer.frame = placement.frame(inDisplayOfSize: size)
    }
}

// MARK: - The set of windows

/// Owns one `DesktopWindow` per physical display and keeps the set in sync with
/// screen changes, the lock screen, and window occlusion.
///
/// `NSObject` because `DistributedNotificationCenter` only accepts
/// `.deliverImmediately` through its selector-based overload, which needs an
/// Objective-C observer.
@MainActor
final class DesktopWindowController: NSObject {
    /// Keyed by `CGDirectDisplayID`, never by `NSScreen` — `NSScreen` objects are
    /// recreated on lid-close/open and stale keys crash (spec.md §6 P3).
    private var windows: [CGDirectDisplayID: DesktopWindow] = [:]

    /// Last value handed to `onRenderingChanged`, so the callback only fires on
    /// an actual transition.
    private var reportedRenderState: [CGDirectDisplayID: Bool] = [:]

    private var isRunning = false

    /// Readable for tests and for the menu bar's status text; only this class mutates it.
    private(set) var gate = RenderGate()

    /// Called when a display appears and needs its own avatar layer.
    var makeLayer: ((CGDirectDisplayID) -> CALayer)?

    /// Called after a display's window is gone, so the owner can drop the player
    /// it built in `makeLayer`.
    var disposeLayer: ((CGDirectDisplayID) -> Void)?

    /// `true` = this display should be decoding, `false` = pause it now.
    /// Fires once per display on `start()` and then only on transitions.
    var onRenderingChanged: ((CGDirectDisplayID, Bool) -> Void)?

    /// Where the avatar sits on every display. Applied to existing windows
    /// immediately and to any window created later.
    var placement: AvatarPlacement = .default {
        didSet {
            guard placement != oldValue else { return }
            for window in windows.values {
                window.placement = placement
            }
        }
    }

    /// Create windows for the current screens and start observing changes.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        installObservers()
        rebuild()
    }

    /// Tear every window down.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        removeObservers()
        for (displayID, window) in windows {
            window.teardown()
            disposeLayer?(displayID)
        }
        windows.removeAll()
        reportedRenderState.removeAll()
        gate = RenderGate()
    }

    func window(for displayID: CGDirectDisplayID) -> DesktopWindow? {
        windows[displayID]
    }

    var allWindows: [DesktopWindow] { Array(windows.values) }

    func shouldRender(_ displayID: CGDirectDisplayID) -> Bool {
        gate.shouldRender(displayID)
    }

    /// `NSApplication.didChangeScreenParametersNotification` handler.
    /// Also safe to call directly (integration code, tests).
    func handleScreenConfigurationChange() {
        rebuild()
    }

    /// Manual pause — battery policy, or the user hiding the avatar from the menu.
    /// Folded into the same gate as occlusion and the lock screen.
    func setPaused(_ paused: Bool) {
        guard gate.isManuallyPaused != paused else { return }
        gate.isManuallyPaused = paused
        publishRenderStates()
    }

    var isPaused: Bool { gate.isManuallyPaused }

    // MARK: Window set

    private func rebuild() {
        var live = Set<CGDirectDisplayID>()

        // NSScreen is the right source for *which windows to build*: it still lists
        // sleeping displays, and their windows must survive the sleep. It is the
        // wrong source for "is anything awake" — CGGetActiveDisplayList returns 0
        // while NSScreen.screens still returns 2 — so sleep is handled by the
        // workspace notifications below, not by counting screens.
        for screen in NSScreen.screens {
            guard let displayID = screen.displayID else { continue }
            live.insert(displayID)

            if let existing = windows[displayID] {
                existing.updateFrame(for: screen)
                continue
            }

            let window = DesktopWindow(screen: screen, displayID: displayID, placement: placement)
            if let layer = makeLayer?(displayID) {
                window.attach(layer)
            }
            window.show()
            windows[displayID] = window
        }

        for (displayID, window) in windows where !live.contains(displayID) {
            window.teardown()
            windows.removeValue(forKey: displayID)
            gate.forget(displayID)
            reportedRenderState.removeValue(forKey: displayID)
            disposeLayer?(displayID)
        }

        resampleOcclusion()
        publishRenderStates()
    }

    /// Read every window's occlusion straight from AppKit instead of trusting the
    /// value cached from the last notification.
    ///
    /// Needed in two places. On window creation, because the occlusion
    /// *notification* only fires on a change — a window that is already covered
    /// when it is born never receives one, and power saving would silently never
    /// engage. On unlock/wake, because a missed edge there is the worst failure
    /// this file can produce: the avatar stays paused forever, looking dead. The
    /// reliability of occlusion reporting on this window level is explicitly
    /// flagged as unverified in spec.md §8, so it is not trusted as the only path.
    private func resampleOcclusion() {
        for (displayID, window) in windows {
            gate.setOccluded(!window.isRenderVisible, for: displayID)
        }
    }

    /// Resample once more after the WindowServer has had a moment to settle — right
    /// at unlock/wake the state AppKit reports is often still the stale one.
    private func resampleOcclusionAfterSettling() {
        resampleOcclusion()
        publishRenderStates()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, self.isRunning else { return }
            self.resampleOcclusion()
            self.publishRenderStates()
        }
    }

    private func publishRenderStates() {
        for displayID in windows.keys {
            let shouldRender = gate.shouldRender(displayID)
            guard reportedRenderState[displayID] != shouldRender else { continue }
            reportedRenderState[displayID] = shouldRender
            onRenderingChanged?(displayID, shouldRender)
        }
    }

    // MARK: Observers

    /// Cross-process session notices. They are only delivered on
    /// `DistributedNotificationCenter`; the same names on
    /// `NotificationCenter.default` never arrive (measured).
    private static let sessionNotificationNames = [
        "com.apple.screenIsLocked",
        "com.apple.screenIsUnlocked",
        "com.apple.screensaver.didstart",
        "com.apple.screensaver.didstop",
    ]

    private func installObservers() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(screenParametersChanged(_:)),
                           name: NSApplication.didChangeScreenParametersNotification, object: nil)
        // object: nil and filter by identity — registering per window would mean
        // tracking one observer token per display for no benefit.
        center.addObserver(self, selector: #selector(occlusionStateChanged(_:)),
                           name: NSWindow.didChangeOcclusionStateNotification, object: nil)

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(displaysDidSleep(_:)),
                              name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(displaysDidWake(_:)),
                              name: NSWorkspace.screensDidWakeNotification, object: nil)

        // `.deliverImmediately` is only reachable from this selector-based overload;
        // the block-based `addObserver` has no `suspensionBehavior` parameter at all.
        // It matters once the app is suspended — an unsuspended app receives the
        // notification either way.
        let distributed = DistributedNotificationCenter.default()
        for name in Self.sessionNotificationNames {
            distributed.addObserver(self, selector: #selector(sessionStateChanged(_:)),
                                    name: NSNotification.Name(name), object: nil,
                                    suspensionBehavior: .deliverImmediately)
        }
    }

    private func removeObservers() {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc private func screenParametersChanged(_ notification: Notification) {
        handleScreenConfigurationChange()
    }

    @objc private func occlusionStateChanged(_ notification: Notification) {
        guard let window = notification.object as? DesktopWindow,
              windows[window.displayID] === window else { return }
        gate.setOccluded(!window.isRenderVisible, for: window.displayID)
        publishRenderStates()
    }

    @objc private func displaysDidSleep(_ notification: Notification) {
        gate.areDisplaysAsleep = true
        publishRenderStates()
    }

    @objc private func displaysDidWake(_ notification: Notification) {
        gate.areDisplaysAsleep = false
        resampleOcclusionAfterSettling()
    }

    @objc private func sessionStateChanged(_ notification: Notification) {
        switch notification.name.rawValue {
        case "com.apple.screenIsLocked": gate.isScreenLocked = true
        case "com.apple.screenIsUnlocked": gate.isScreenLocked = false
        case "com.apple.screensaver.didstart": gate.isScreenSaverRunning = true
        case "com.apple.screensaver.didstop": gate.isScreenSaverRunning = false
        default: return
        }
        if gate.isSessionRenderable {
            resampleOcclusionAfterSettling()
        } else {
            publishRenderStates()
        }
    }
}

extension NSScreen {
    /// nil only if the screen was disconnected between enumeration and lookup.
    var displayID: CGDirectDisplayID? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }
        return CGDirectDisplayID(number.uint32Value)
    }
}
