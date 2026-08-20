//
//  DesktopWindow.swift — the window the avatar lives in, and the set of them.
//
//  There are two shapes (`AvatarLayerMode`), and the whole point of the file is
//  that they differ in exactly three things: window level, collection behaviour,
//  and how big the window itself is.
//
//  # Desktop mode — why level == CGWindowLevelForKey(.desktopIconWindow) - 1
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
//  # Floating mode — why level == .floating (3)
//
//  Desktop mode has one cost the user found in daily use: a full screen of windows
//  means she is not there at all. Floating mode buys presence, and the price is
//  that she is now in front of the user's work — so the level has to be the
//  *lowest* one that still clears ordinary windows.
//
//  Measured ladder (same machine, printed from a live process alongside a
//  CGWindowListCopyWindowInfo dump of what actually sits where):
//
//      normal windows                        0
//      .floating                             3   ← ours
//      "always on top" helper panels         8   (whatever the user runs)
//      Dock                                 20
//      menu bar                             24
//      status items / Control Centre        25
//      .screenSaver                       1000   (NOT 101 — see decisions.md)
//
//  At 3 she covers every ordinary window and nothing the system owns: the Dock,
//  the menu bar, Control Centre and notifications all stay in front of her, which
//  is the behaviour you want from a companion that is never clicked. `.statusBar`
//  (25) would put her over the menu bar and over notification banners, and
//  `.screenSaver` (1000) over the lock/screensaver UI itself. Both trade a real
//  regression for a benefit we do not need.
//
//  The accepted cost of 3: another app's own always-on-top panel (level 8 in the
//  dump above) covers her. That is the right outcome — a palette the user
//  deliberately pinned outranks a companion.
//
//  # Floating mode — full-screen apps
//
//  Measured, one process holding the overlay and a *second* process taking a
//  window full screen (so it is a genuine cross-app full-screen space), sampling
//  `CGWindowListCopyWindowInfo(.optionOnScreenOnly)` once a second:
//
//      [.canJoinAllSpaces, .ignoresCycle, .fullScreenAuxiliary]  overlay on screen,
//                                                               in front of the
//                                                               full-screen window
//      [.canJoinAllSpaces, .ignoresCycle]                       identical result
//      [.canJoinAllSpaces, .ignoresCycle, .fullScreenNone]      overlay drops off
//                                                               screen entirely
//
//  So `.fullScreenNone` is exactly wrong for floating mode — the moment the user
//  goes full screen (the case that motivated this whole feature) she disappears.
//  `.fullScreenAuxiliary` is what ships: it measured the same as declaring nothing
//  and it says what we mean, so the behaviour does not rest on a default.
//  `.fullScreenNone` stays on desktop mode, where vanishing with the desktop is
//  the correct thing to do.
//
//  Not yet measured: a real full-screen *app bundle* (Safari, a video player,
//  Xcode) rather than the two-process probe, and full-screen games that take the
//  display exclusively. Treat "floats over full screen" as verified for ordinary
//  AppKit full screen only.
//
//  # Mouse events
//
//  `ignoresMouseEvents = true` in both modes, always. Per-pixel alpha hit testing
//  ("transparent pixels fall through by themselves") is recorded in decisions.md
//  at *medium* confidence only — the original measurement had wantsLayer/SwiftUI
//  background as uncontrolled variables and was never reproduced. In desktop mode
//  a wrong guess there is invisible; in floating mode it would mean a companion
//  that eats clicks aimed at the user's work. So it is stated explicitly instead
//  of inferred. Nothing in this file can become key or main either, so the window
//  never takes focus and `NSPanel`/`.nonactivatingPanel` buys nothing today — see
//  the note on dragging in `AvatarPlacement`.
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

// MARK: - Layer mode

/// The two shapes the avatar can wear. See the file header for the level and
/// collection-behaviour evidence behind each.
enum AvatarLayerMode: String, CaseIterable, Codable, Equatable, Sendable {
    /// Between the wallpaper and the desktop icons. Every window covers her.
    case desktop
    /// Above ordinary windows, below the Dock and the menu bar. Always visible.
    case floating
}

/// Which displays get an avatar when more than one is attached.
enum AvatarDisplayScope: String, CaseIterable, Codable, Equatable, Sendable {
    case allDisplays
    case mainDisplayOnly

    /// Pure so the multi-display rule can be tested with no second display.
    ///
    /// `mainDisplayID` is `CGMainDisplayID()` in production — the display the
    /// menu bar is on. Deliberately not `NSScreen.main`, which for a background
    /// app means "wherever the frontmost *other* app happens to be" and would
    /// make her jump between panels as the user works.
    func includes(_ displayID: CGDirectDisplayID, mainDisplayID: CGDirectDisplayID) -> Bool {
        switch self {
        case .allDisplays: return true
        case .mainDisplayOnly: return displayID == mainDisplayID
        }
    }
}

// MARK: - Placement

/// Where the avatar sits inside one display, and how big it is.
///
/// Expressed relative to the display rather than in absolute points so a single
/// value looks the same on a 5K panel and on the built-in laptop screen.
/// `frame(inDisplayOfSize:)` is pure — no AppKit or WindowServer state — so the
/// layout rules can be exercised in a test without a display attached.
///
/// # Dragging her to move her (not in this build)
///
/// Direct dragging and click-through are the same switch: a window that can be
/// dragged is a window that eats mouse events. Nothing here blocks it later —
/// `DesktopWindowController.presentation` is live-settable, so any drag
/// implementation only has to turn a dragged point back into `anchor` + `offset`
/// and assign. The three candidates, cheapest first: a drag handle in the
/// settings window's preview (no permissions, no event conflict); an explicit
/// "调整位置" mode from the menu bar that flips `ignoresMouseEvents` off until the
/// user is done; and modifier-key dragging, which needs `NSEvent.modifierFlags`
/// polling (spec.md RISK-3's fallback) because a global `.flagsChanged` monitor
/// requires Accessibility trust. None of them is built yet.
struct AvatarPlacement: Equatable, Codable, Sendable {
    /// The nine-square grid, declared in reading order: chunk `allCases` by three
    /// and it is the settings window's 3×3 picker, top row first.
    enum Anchor: String, CaseIterable, Codable, Equatable, Sendable {
        case topLeading, topCenter, topTrailing
        case centerLeading, center, centerTrailing
        case bottomLeading, bottomCenter, bottomTrailing

        /// -1 leading, 0 centre, +1 trailing.
        var horizontalPosition: Int {
            switch self {
            case .topLeading, .centerLeading, .bottomLeading: -1
            case .topCenter, .center, .bottomCenter: 0
            case .topTrailing, .centerTrailing, .bottomTrailing: 1
            }
        }

        /// -1 bottom, 0 centre, +1 top.
        var verticalPosition: Int {
            switch self {
            case .bottomLeading, .bottomCenter, .bottomTrailing: -1
            case .centerLeading, .center, .centerTrailing: 0
            case .topLeading, .topCenter, .topTrailing: 1
            }
        }
    }

    /// Which corner, edge centre, or the middle of the display the avatar hugs.
    /// Bottom-right by default: it is the corner least likely to collide with
    /// desktop icons, which macOS fills from the top-right down.
    var anchor: Anchor = .bottomTrailing

    /// Avatar box height as a fraction of the display's height, clamped to
    /// `heightFractionRange` when the frame is computed.
    ///
    /// One number with two very different right answers — 0.55 is right when she
    /// is part of the scenery and absurd when she is on top of the user's work —
    /// which is why `AvatarPresentation` remembers one per mode.
    var heightFraction: CGFloat = 0.55

    /// width / height of the box. Must match the shipped clips, which are all
    /// 810x1080 after `tools/anchor/normalize` (avatar-states.md §六).
    ///
    /// Not a user setting: it is a property of the footage. A mismatch does not
    /// distort her (`AVPlayerLayer` uses `.resizeAspect`) but it does strand her:
    /// a box wider than the footage leaves her floating off the anchored edge by
    /// half the difference. The previous value (926/994, from clips that predate
    /// normalisation) was 24% too wide, which pushed her 72pt clear of the right
    /// margin she was supposed to hug.
    var aspectRatio: CGFloat = 810.0 / 1080.0

    /// How far she sits from where the anchor alone would put her, in points.
    ///
    /// * against an edge (leading/trailing/top/bottom): distance from that edge.
    /// * on an axis the anchor centres: a signed nudge, `+x` right, `+y` up.
    ///
    /// Clamped either way to 0...(free space), so no value can push the box off
    /// the display.
    ///
    /// Height is 0 by design for the bottom anchors: the clips are half-body
    /// portraits that are meant to run off the bottom of the screen, the way a
    /// person standing just past the edge of a desk would. Any bottom margin
    /// makes her hover instead.
    var offset: CGSize = CGSize(width: 48, height: 0)

    /// What the settings window's slider may offer. Enforced here rather than
    /// only there, so a hand-edited plist cannot produce a size the window
    /// silently corrects behind the user's back.
    static let heightFractionRange: ClosedRange<CGFloat> = 0.05...1.0

    /// Big and hugging an edge: on the desktop layer nothing covers her that the
    /// desktop would not, so size costs the user nothing.
    static let `default` = AvatarPlacement()

    /// Alias for `default`, for code that names both modes side by side.
    static let desktopDefault = AvatarPlacement()

    /// Small and out of the way — floating, she is in front of the user's work,
    /// so the default has to cost less screen than the desktop one does.
    static let floatingDefault = AvatarPlacement(
        anchor: .bottomTrailing, heightFraction: 0.30, offset: CGSize(width: 24, height: 0))

    init(anchor: Anchor = .bottomTrailing,
         heightFraction: CGFloat = 0.55,
         aspectRatio: CGFloat = 810.0 / 1080.0,
         offset: CGSize = CGSize(width: 48, height: 0)) {
        self.anchor = anchor
        self.heightFraction = heightFraction
        self.aspectRatio = aspectRatio
        self.offset = offset
    }

    /// Lenient on purpose: this comes back from whatever the settings window
    /// persisted, possibly written by an older build. A *missing* member falls
    /// back to the default instead of failing the decode and losing the lot.
    /// A member that is present but nonsense still throws — that is a corrupt
    /// blob, and the caller's fallback is the honest answer to it.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = AvatarPlacement()
        anchor = try container.decodeIfPresent(Anchor.self, forKey: .anchor) ?? fallback.anchor
        heightFraction = try container.decodeIfPresent(CGFloat.self, forKey: .heightFraction)
            ?? fallback.heightFraction
        aspectRatio = try container.decodeIfPresent(CGFloat.self, forKey: .aspectRatio)
            ?? fallback.aspectRatio
        offset = try container.decodeIfPresent(CGSize.self, forKey: .offset) ?? fallback.offset
    }

    /// The avatar's frame in display-local coordinates (origin bottom-left,
    /// matching an unflipped layer-backed `NSView`).
    func frame(inDisplayOfSize size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }

        let fraction = min(max(heightFraction, Self.heightFractionRange.lowerBound),
                           Self.heightFractionRange.upperBound)
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

        let x = Self.origin(position: anchor.horizontalPosition,
                            free: max(size.width - width, 0), offset: offset.width)
        let y = Self.origin(position: anchor.verticalPosition,
                            free: max(size.height - height, 0), offset: offset.height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// One axis of the layout. `position` is -1 low edge, 0 centre, +1 high edge;
    /// `free` is the room left over once the box is sized.
    private static func origin(position: Int, free: CGFloat, offset: CGFloat) -> CGFloat {
        let clamp = { (value: CGFloat) in min(max(value, 0), free) }
        switch position {
        case -1: return clamp(offset)
        case 1: return free - clamp(offset)
        default: return clamp((free / 2).rounded() + offset)
        }
    }
}

/// One mode's worth of user settings: everything remembered separately for the
/// desktop layer and for the floating layer.
///
/// Separate on purpose. A desktop avatar wants to be large and hug an edge; a
/// floating one wants to be small and stay out of the way, and probably on one
/// screen rather than every screen. Sharing one set of numbers would make every
/// mode switch a layout the user has to redo.
struct AvatarLayerSettings: Equatable, Codable, Sendable {
    var placement: AvatarPlacement
    var displayScope: AvatarDisplayScope

    static let desktopDefault = AvatarLayerSettings(
        placement: .desktopDefault, displayScope: .allDisplays)

    /// Main display only. Two always-on-top companions on a two-panel desk is
    /// twice the interruption and twice the video decoding for no extra company.
    static let floatingDefault = AvatarLayerSettings(
        placement: .floatingDefault, displayScope: .mainDisplayOnly)

    init(placement: AvatarPlacement, displayScope: AvatarDisplayScope) {
        self.placement = placement
        self.displayScope = displayScope
    }

    /// Lenient for the same reason as `AvatarPlacement.init(from:)`.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        placement = try container.decodeIfPresent(AvatarPlacement.self, forKey: .placement)
            ?? .desktopDefault
        displayScope = try container.decodeIfPresent(AvatarDisplayScope.self, forKey: .displayScope)
            ?? .allDisplays
    }
}

/// The whole of what the settings window owns about how the avatar is shown:
/// which mode is live, plus both modes' remembered settings.
///
/// Assign it to `DesktopWindowController.presentation` and every window catches
/// up in place — no teardown, so a mode switch does not restart playback.
struct AvatarPresentation: Equatable, Codable, Sendable {
    var mode: AvatarLayerMode
    var desktop: AvatarLayerSettings
    var floating: AvatarLayerSettings

    /// Desktop stays the default: it is the shape that has been shipping, and
    /// the only one that cannot get in the user's way.
    static let `default` = AvatarPresentation()

    init(mode: AvatarLayerMode = .desktop,
         desktop: AvatarLayerSettings = .desktopDefault,
         floating: AvatarLayerSettings = .floatingDefault) {
        self.mode = mode
        self.desktop = desktop
        self.floating = floating
    }

    /// Lenient for the same reason as `AvatarPlacement.init(from:)`.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decodeIfPresent(AvatarLayerMode.self, forKey: .mode) ?? .desktop
        desktop = try container.decodeIfPresent(AvatarLayerSettings.self, forKey: .desktop)
            ?? .desktopDefault
        floating = try container.decodeIfPresent(AvatarLayerSettings.self, forKey: .floating)
            ?? .floatingDefault
    }

    /// The settings actually on screen right now.
    var active: AvatarLayerSettings { self[mode] }

    /// Read or edit one mode's settings, including the one that is not live —
    /// which is what the settings window does while the user sets up the other
    /// shape before switching to it.
    subscript(mode: AvatarLayerMode) -> AvatarLayerSettings {
        get { mode == .desktop ? desktop : floating }
        set {
            switch mode {
            case .desktop: desktop = newValue
            case .floating: floating = newValue
            }
        }
    }
}

// MARK: - Geometry

/// How a mode plus a placement turn into an actual window.
///
/// Pure, and split out from `DesktopWindow` so the part worth checking can be
/// checked without a display: given a screen, what rectangle does the window
/// occupy and where does the avatar layer sit inside it.
enum AvatarGeometry {
    /// - Returns: `window` in global screen coordinates (what `setFrame` takes),
    ///   `layer` in the content view's coordinates.
    static func frames(mode: AvatarLayerMode,
                       placement: AvatarPlacement,
                       screenFrame: CGRect) -> (window: CGRect, layer: CGRect) {
        let box = placement.frame(inDisplayOfSize: screenFrame.size)
        switch mode {
        case .desktop:
            // Full-screen window. It sits under every other window anyway, and a
            // window that already spans the display never has to be moved when
            // the user drags the sliders.
            return (screenFrame, box)
        case .floating:
            // Only as big as she is. A transparent full-screen window at level 3
            // is in front of everything the user works with: it would be what the
            // screenshot picker highlights and what window managers see, for no
            // gain, since nothing but her pixels is ever drawn.
            guard !box.isEmpty else { return (screenFrame, box) }
            let window = CGRect(x: screenFrame.minX + box.minX,
                                y: screenFrame.minY + box.minY,
                                width: box.width, height: box.height)
            return (window, CGRect(origin: .zero, size: box.size))
        }
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

/// Borderless, transparent, click-through window pinned to one display, sitting
/// either on the desktop wallpaper layer or above ordinary windows. See the file
/// header for why those two levels.
@MainActor
final class DesktopWindow: NSWindow {
    /// `.desktopIconWindow - 1`: below the Finder icons, above the wallpaper.
    static let desktopLevel = NSWindow.Level(
        rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)

    /// Raw value 3: above every ordinary window, below the Dock (20), the menu
    /// bar (24) and status items (25).
    static let floatingLevel = NSWindow.Level.floating

    /// `.stationary` is intentionally not in this set — see the file header.
    static let desktopCollectionBehavior: NSWindow.CollectionBehavior =
        [.canJoinAllSpaces, .ignoresCycle, .fullScreenNone]

    /// `.fullScreenAuxiliary`, not `.fullScreenNone`: measured, `.fullScreenNone`
    /// takes the window off screen the moment any app goes full screen.
    static let floatingCollectionBehavior: NSWindow.CollectionBehavior =
        [.canJoinAllSpaces, .ignoresCycle, .fullScreenAuxiliary]

    static func windowLevel(for mode: AvatarLayerMode) -> NSWindow.Level {
        mode == .desktop ? desktopLevel : floatingLevel
    }

    static func windowCollectionBehavior(for mode: AvatarLayerMode) -> NSWindow.CollectionBehavior {
        mode == .desktop ? desktopCollectionBehavior : floatingCollectionBehavior
    }

    /// The display this window is pinned to.
    let displayID: CGDirectDisplayID

    /// Both are changed together through `apply(mode:placement:screen:)`; keeping
    /// them read-only from outside is what makes "the window matches the settings"
    /// a single code path.
    private(set) var mode: AvatarLayerMode
    private(set) var placement: AvatarPlacement

    /// The frame of the display we are pinned to, remembered so a settings change
    /// can be re-laid-out without waiting for a screen notification.
    private var screenFrame: CGRect

    /// Owned by `AvatarPlayer`, not by us: held weakly so tearing the window down
    /// never decides the player's lifetime.
    private weak var avatarLayer: CALayer?

    init(screen: NSScreen,
         displayID: CGDirectDisplayID,
         mode: AvatarLayerMode = .desktop,
         placement: AvatarPlacement = .default) {
        self.displayID = displayID
        self.mode = mode
        self.placement = placement
        self.screenFrame = screen.frame
        let frames = AvatarGeometry.frames(mode: mode, placement: placement,
                                           screenFrame: screen.frame)
        super.init(contentRect: frames.window,
                   styleMask: [.borderless],
                   backing: .buffered,
                   defer: false)

        level = Self.windowLevel(for: mode)
        collectionBehavior = Self.windowCollectionBehavior(for: mode)

        // Transparent: only the avatar's own pixels should be visible.
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false

        // Click-through and focus-proof in both modes. `ignoresMouseEvents` covers
        // the whole window rather than relying on per-pixel alpha hit testing
        // (RISK-3), and `canBecomeKey/Main` below keep it out of the responder
        // chain entirely.
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

        let content = NSView(frame: CGRect(origin: .zero, size: frames.window.size))
        content.wantsLayer = true
        content.layer?.isOpaque = false
        content.layer?.backgroundColor = NSColor.clear.cgColor
        contentView = content

        setFrame(frames.window, display: false)
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
        layoutAvatarLayer()
        CATransaction.commit()
    }

    /// Give the layer back to its owner without closing the window.
    func detachAvatarLayer() {
        avatarLayer?.removeFromSuperlayer()
        avatarLayer = nil
    }

    /// The one way anything about this window's shape changes: a new mode, new
    /// user settings, or a new screen geometry all land here.
    ///
    /// In place, never teardown-and-rebuild: the avatar layer keeps its player, so
    /// switching modes does not restart the clip she is in the middle of.
    func apply(mode newMode: AvatarLayerMode, placement newPlacement: AvatarPlacement,
               screen: NSScreen) {
        let modeChanged = newMode != mode
        mode = newMode
        placement = newPlacement
        screenFrame = screen.frame

        if modeChanged {
            level = Self.windowLevel(for: mode)
            collectionBehavior = Self.windowCollectionBehavior(for: mode)
        }

        let frames = AvatarGeometry.frames(mode: mode, placement: placement,
                                           screenFrame: screenFrame)
        if frame != frames.window {
            setFrame(frames.window, display: true)
        }
        contentView?.frame = CGRect(origin: .zero, size: frames.window.size)
        layoutAvatarLayer()

        // Setting `level` moves the window between the WindowServer's per-level
        // lists; ordering it front again keeps it in front *within* its new level
        // rather than wherever the move happened to leave it.
        if modeChanged, isVisible {
            orderFrontRegardless()
        }
    }

    /// Re-apply the frame after a resolution or arrangement change.
    func updateFrame(for screen: NSScreen) {
        apply(mode: mode, placement: placement, screen: screen)
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
        // Without this the video is rendered at 1x and looks soft on the 2x panels.
        layer.contentsScale = backingScaleFactor
        layer.frame = AvatarGeometry.frames(mode: mode, placement: placement,
                                            screenFrame: screenFrame).layer
        CATransaction.commit()
    }
}

// MARK: - The set of windows

/// Owns one `DesktopWindow` per participating display and keeps the set in sync
/// with screen changes, the user's settings, the lock screen, and occlusion.
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

    /// Everything the settings window controls: which layer she is on, where and
    /// how big she is on each of them, and which displays take part. Applied to
    /// the existing windows immediately — a mode switch reconfigures them in
    /// place rather than rebuilding them, so playback does not restart — and to
    /// any window created later.
    var presentation: AvatarPresentation = .default {
        didSet {
            guard presentation != oldValue, isRunning else { return }
            rebuild()
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
        let settings = presentation.active
        let mainDisplayID = CGMainDisplayID()
        var live = Set<CGDirectDisplayID>()

        // NSScreen is the right source for *which windows to build*: it still lists
        // sleeping displays, and their windows must survive the sleep. It is the
        // wrong source for "is anything awake" — CGGetActiveDisplayList returns 0
        // while NSScreen.screens still returns 2 — so sleep is handled by the
        // workspace notifications below, not by counting screens.
        for screen in NSScreen.screens {
            guard let displayID = screen.displayID else { continue }
            // A display the user excluded is handled exactly like a disconnected
            // one: no window, and the loop below disposes of any it used to have.
            guard settings.displayScope.includes(displayID, mainDisplayID: mainDisplayID)
            else { continue }
            live.insert(displayID)

            if let existing = windows[displayID] {
                existing.apply(mode: presentation.mode, placement: settings.placement,
                               screen: screen)
                continue
            }

            let window = DesktopWindow(screen: screen, displayID: displayID,
                                       mode: presentation.mode, placement: settings.placement)
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
