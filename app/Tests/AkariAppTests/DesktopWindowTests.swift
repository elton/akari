import AppKit
import Foundation
import Testing
@testable import AkariApp

// The window layer's decisions, minus the WindowServer.
//
// Two things are worth pinning down here. The layout arithmetic, because a wrong
// box does not crash — it strands her a few dozen points off the edge she was
// supposed to hug, which is exactly the bug the 926/994 aspect ratio produced and
// nobody noticed until they looked at the screen. And the two modes' window
// levels and collection behaviours, because those were chosen from measurements
// (see the file header of DesktopWindow.swift) and a later edit that quietly
// swaps `.fullScreenAuxiliary` back to `.fullScreenNone` would only show up when
// somebody goes full screen.
//
// Nothing here needs a display attached: the geometry is pure, and the levels are
// constants. The one test that builds a real `NSWindow` says so and skips itself
// when there is no screen to build it on.

@Suite("avatar placement")
struct AvatarPlacementTests {
    private let display = CGSize(width: 2560, height: 1440)

    @Test("the box matches the shipped clips' aspect ratio")
    func aspectRatioIsTheFootage() {
        let box = AvatarPlacement.default.frame(inDisplayOfSize: display)
        #expect(box.height == 792)   // 1440 * 0.55
        // 792 * 810/1080. The regression this guards: 926/994 would make it 738
        // wide, 144pt too much, and push her that far off the right edge.
        #expect(box.width == 594)
    }

    @Test("every anchor puts the box against the edges it names")
    func anchorsLandWhereTheyAreNamed() {
        var placement = AvatarPlacement.default
        placement.offset = CGSize(width: 48, height: 24)
        let w = placement.frame(inDisplayOfSize: display).width
        let h = placement.frame(inDisplayOfSize: display).height

        func box(_ anchor: AvatarPlacement.Anchor) -> CGRect {
            var value = placement
            value.anchor = anchor
            return value.frame(inDisplayOfSize: display)
        }

        // Horizontal: leading hugs x = offset, trailing hugs the far edge,
        // centre lands mid-display plus the nudge.
        #expect(box(.bottomLeading).minX == 48)
        #expect(box(.bottomTrailing).maxX == display.width - 48)
        #expect(box(.bottomCenter).minX == ((display.width - w) / 2).rounded() + 48)

        // Vertical: bottom hugs y = offset, top hugs the far edge.
        #expect(box(.bottomTrailing).minY == 24)
        #expect(box(.topTrailing).maxY == display.height - 24)
        #expect(box(.centerTrailing).minY == ((display.height - h) / 2).rounded() + 24)

        // And the nine really are nine distinct places.
        let origins = AvatarPlacement.Anchor.allCases.map { box($0).origin }
        #expect(Set(origins.map { "\($0.x)x\($0.y)" }).count == 9)
    }

    @Test("allCases is in reading order, so the settings grid can chunk it by three")
    func anchorsAreInReadingOrder() {
        let all = AvatarPlacement.Anchor.allCases
        #expect(all.count == 9)
        #expect(all.prefix(3).allSatisfy { $0.verticalPosition == 1 })
        #expect(all.dropFirst(3).prefix(3).allSatisfy { $0.verticalPosition == 0 })
        #expect(all.suffix(3).allSatisfy { $0.verticalPosition == -1 })
        #expect(all.map(\.horizontalPosition) == [-1, 0, 1, -1, 0, 1, -1, 0, 1])
    }

    @Test("no setting can push the box off the display")
    func everythingIsClamped() {
        var placement = AvatarPlacement.default

        // An offset larger than the room left over.
        placement.offset = CGSize(width: 100_000, height: 100_000)
        placement.anchor = .bottomLeading
        var box = placement.frame(inDisplayOfSize: display)
        #expect(box.maxX <= display.width)
        #expect(box.minX >= 0)
        #expect(box.minY >= 0)

        // A negative one, which would otherwise hang her off the left edge.
        placement.offset = CGSize(width: -500, height: -500)
        box = placement.frame(inDisplayOfSize: display)
        #expect(box.minX == 0)
        #expect(box.minY == 0)

        // A height fraction outside the allowed range.
        placement.heightFraction = 40
        placement.offset = .zero
        box = placement.frame(inDisplayOfSize: display)
        #expect(box.height <= display.height)
        #expect(box.width <= display.width)

        placement.heightFraction = -3
        box = placement.frame(inDisplayOfSize: display)
        #expect(box.height == (display.height * AvatarPlacement.heightFractionRange.lowerBound).rounded())

        // A degenerate display (nothing attached) is a no-op, not a crash.
        #expect(AvatarPlacement.default.frame(inDisplayOfSize: .zero) == .zero)
    }

    @Test("a tall narrow display shrinks the box instead of overflowing it")
    func boxNeverExceedsTheDisplay() {
        var placement = AvatarPlacement.default
        placement.heightFraction = 1.0
        let box = placement.frame(inDisplayOfSize: CGSize(width: 400, height: 1440))
        #expect(box.width <= 400)
        #expect(box.height <= 1440)
    }

    @Test("the two modes' defaults are actually different sizes")
    func modeDefaultsDiffer() {
        // The whole reason placement is remembered per mode: 55% of the screen
        // is right on the desktop layer and a wall in front of the user's work
        // on the floating one.
        #expect(AvatarPlacement.desktopDefault.heightFraction >
                AvatarPlacement.floatingDefault.heightFraction)
        #expect(AvatarLayerSettings.floatingDefault.displayScope == .mainDisplayOnly)
        #expect(AvatarLayerSettings.desktopDefault.displayScope == .allDisplays)
    }
}

@Suite("avatar presentation")
struct AvatarPresentationTests {
    @Test("editing one mode leaves the other alone")
    func modesRememberSeparately() {
        var presentation = AvatarPresentation.default
        presentation[.floating].placement.heightFraction = 0.12
        presentation[.floating].displayScope = .mainDisplayOnly
        #expect(presentation.desktop == .desktopDefault)
        #expect(presentation.active == presentation.desktop)

        presentation.mode = .floating
        #expect(presentation.active.placement.heightFraction == 0.12)
        #expect(presentation.active.displayScope == .mainDisplayOnly)
    }

    @Test("a stored value survives a round trip")
    func codableRoundTrips() throws {
        var presentation = AvatarPresentation.default
        presentation.mode = .floating
        presentation[.floating].placement.anchor = .topLeading
        presentation[.desktop].placement.offset = CGSize(width: 12, height: 4)
        let data = try JSONEncoder().encode(presentation)
        #expect(try JSONDecoder().decode(AvatarPresentation.self, from: data) == presentation)
    }

    @Test("a blob from an older build loads, with defaults for what it never had")
    func partialBlobDecodes() throws {
        // Exactly the failure this is here to prevent: a user upgrades, the
        // stored JSON has no `floating` key yet, and every avatar setting resets.
        let json = Data("""
        {"mode":"floating","desktop":{"placement":{"heightFraction":0.8}}}
        """.utf8)
        let decoded = try JSONDecoder().decode(AvatarPresentation.self, from: json)
        #expect(decoded.mode == .floating)
        #expect(decoded.desktop.placement.heightFraction == 0.8)
        #expect(decoded.desktop.placement.anchor == AvatarPlacement.default.anchor)
        #expect(decoded.desktop.displayScope == .allDisplays)
        #expect(decoded.floating == .floatingDefault)
    }

    @Test("a corrupt member still throws, so the caller can fall back deliberately")
    func nonsenseThrows() {
        let json = Data(#"{"mode":"sideways"}"#.utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(AvatarPresentation.self, from: json)
        }
    }
}

@Suite("avatar display scope")
struct AvatarDisplayScopeTests {
    @Test("main-only keeps the display the menu bar is on and drops the rest")
    func scopeSelectsDisplays() {
        let main: CGDirectDisplayID = 1
        let secondary: CGDirectDisplayID = 2
        #expect(AvatarDisplayScope.allDisplays.includes(main, mainDisplayID: main))
        #expect(AvatarDisplayScope.allDisplays.includes(secondary, mainDisplayID: main))
        #expect(AvatarDisplayScope.mainDisplayOnly.includes(main, mainDisplayID: main))
        #expect(!AvatarDisplayScope.mainDisplayOnly.includes(secondary, mainDisplayID: main))
    }
}

@Suite("avatar window geometry")
struct AvatarGeometryTests {
    // A second display to the right of the first, so a bug that forgets to offset
    // by the screen's origin shows up as her appearing on the wrong panel.
    private let screenFrame = CGRect(x: 2560, y: 0, width: 2560, height: 1440)

    @Test("desktop mode spans the display and places her inside it")
    func desktopWindowSpansTheScreen() {
        let placement = AvatarPlacement.desktopDefault
        let frames = AvatarGeometry.frames(mode: .desktop, placement: placement,
                                           screenFrame: screenFrame)
        #expect(frames.window == screenFrame)
        #expect(frames.layer == placement.frame(inDisplayOfSize: screenFrame.size))
    }

    @Test("floating mode is only as big as she is, on the right display")
    func floatingWindowIsTheBox() {
        let placement = AvatarPlacement.floatingDefault
        let box = placement.frame(inDisplayOfSize: screenFrame.size)
        let frames = AvatarGeometry.frames(mode: .floating, placement: placement,
                                           screenFrame: screenFrame)
        #expect(frames.window.size == box.size)
        #expect(frames.window.minX == screenFrame.minX + box.minX)
        #expect(frames.window.minY == screenFrame.minY + box.minY)
        // The layer fills the window: everything outside her is transparent and
        // there is no reason for the window to be bigger than she is.
        #expect(frames.layer == CGRect(origin: .zero, size: box.size))
        #expect(screenFrame.contains(frames.window))
    }

    @Test("a degenerate display falls back to the screen frame rather than a zero-size window")
    func emptyBoxDoesNotProduceAZeroWindow() {
        var placement = AvatarPlacement.default
        placement.aspectRatio = 0
        let frames = AvatarGeometry.frames(mode: .floating, placement: placement,
                                           screenFrame: .zero)
        #expect(frames.window == .zero)  // no display, no window
        let real = AvatarGeometry.frames(mode: .floating, placement: placement,
                                         screenFrame: screenFrame)
        #expect(!real.window.isEmpty)
    }
}

@MainActor
@Suite("avatar window level")
struct DesktopWindowLevelTests {
    @Test("the desktop level is the one gap between the wallpaper and the icons")
    func desktopLevelIsIconMinusOne() {
        #expect(DesktopWindow.desktopLevel.rawValue
                == Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
        // Above the level the wallpaper itself is drawn at (-2147483623 here),
        // below the Finder icons: the one slot the avatar is allowed to occupy.
        #expect(DesktopWindow.desktopLevel.rawValue > Int(CGWindowLevelForKey(.desktopWindow)))
        #expect(DesktopWindow.desktopLevel.rawValue < Int(CGWindowLevelForKey(.desktopIconWindow)))
    }

    @Test("the floating level clears ordinary windows and nothing the system owns")
    func floatingLevelSitsBelowTheSystemUI() {
        let floating = DesktopWindow.floatingLevel.rawValue
        #expect(floating == 3)
        #expect(floating > NSWindow.Level.normal.rawValue)
        // Dock 20, menu bar 24, status items 25 — measured on macOS 26.6.1 and
        // all deliberately in front of her. `.screenSaver` really is 1000, not
        // the 101 that gets repeated online (decisions.md).
        #expect(floating < Int(CGWindowLevelForKey(.dockWindow)))
        #expect(floating < NSWindow.Level.mainMenu.rawValue)
        #expect(floating < NSWindow.Level.statusBar.rawValue)
        #expect(NSWindow.Level.screenSaver.rawValue == 1000)
        #expect(DesktopWindow.desktopLevel.rawValue < floating)
    }

    @Test("floating survives another app going full screen; desktop deliberately does not")
    func collectionBehavioursMatchWhatWasMeasured() {
        // Measured with two processes (one overlay, one taking a window full
        // screen) sampling CGWindowListCopyWindowInfo: with `.fullScreenNone`
        // the overlay drops off screen entirely the moment the full-screen space
        // is active. That is right for a desktop-layer window and fatal for the
        // floating one, whose whole purpose is being visible then.
        #expect(DesktopWindow.floatingCollectionBehavior.contains(.fullScreenAuxiliary))
        #expect(!DesktopWindow.floatingCollectionBehavior.contains(.fullScreenNone))
        #expect(DesktopWindow.desktopCollectionBehavior.contains(.fullScreenNone))
        #expect(!DesktopWindow.desktopCollectionBehavior.contains(.fullScreenAuxiliary))

        for behavior in [DesktopWindow.desktopCollectionBehavior,
                         DesktopWindow.floatingCollectionBehavior] {
            #expect(behavior.contains(.canJoinAllSpaces))
            #expect(behavior.contains(.ignoresCycle))
            // `.stationary` makes the WindowServer apply a permanent 98% scale
            // about the window centre (file header). It stays out of both.
            #expect(!behavior.contains(.stationary))
        }
    }

    @Test("each mode maps to its own level and behaviour")
    func modeMapping() {
        #expect(DesktopWindow.windowLevel(for: .desktop) == DesktopWindow.desktopLevel)
        #expect(DesktopWindow.windowLevel(for: .floating) == DesktopWindow.floatingLevel)
        #expect(DesktopWindow.windowCollectionBehavior(for: .desktop)
                == DesktopWindow.desktopCollectionBehavior)
        #expect(DesktopWindow.windowCollectionBehavior(for: .floating)
                == DesktopWindow.floatingCollectionBehavior)
    }
}

/// The one suite that needs a real screen — it builds an actual `NSWindow` (never
/// ordered in, so nothing appears) to check that switching mode reconfigures the
/// live window rather than only the value objects. Skipped where there is no
/// display, so a headless run stays green instead of lying.
@MainActor
@Suite("desktop window, live", .enabled(if: NSScreen.main != nil))
struct DesktopWindowLiveTests {
    @Test("a new window is click-through, focus-proof and exactly where it was asked to be")
    func windowStartsCorrect() throws {
        let screen = try #require(NSScreen.main)
        let displayID = try #require(screen.displayID)
        let window = DesktopWindow(screen: screen, displayID: displayID)
        defer { window.teardown() }

        #expect(window.level == DesktopWindow.desktopLevel)
        #expect(window.collectionBehavior == DesktopWindow.desktopCollectionBehavior)
        #expect(window.ignoresMouseEvents)
        #expect(!window.canBecomeKey)
        #expect(!window.canBecomeMain)
        // The crash guard: true over-releases with a CA layer attached.
        #expect(!window.isReleasedWhenClosed)
        #expect(window.frame == screen.frame)
    }

    @Test("switching to floating changes level, behaviour and size in place")
    func modeSwitchReconfiguresTheSameWindow() throws {
        let screen = try #require(NSScreen.main)
        let displayID = try #require(screen.displayID)
        let window = DesktopWindow(screen: screen, displayID: displayID)
        defer { window.teardown() }
        let identity = ObjectIdentifier(window)

        window.apply(mode: .floating, placement: .floatingDefault, screen: screen)

        #expect(ObjectIdentifier(window) == identity)  // same window, no rebuild
        #expect(window.level == DesktopWindow.floatingLevel)
        #expect(window.collectionBehavior == DesktopWindow.floatingCollectionBehavior)
        #expect(window.ignoresMouseEvents)  // still click-through, in front of everything
        let expected = AvatarGeometry.frames(mode: .floating, placement: .floatingDefault,
                                             screenFrame: screen.frame).window
        #expect(window.frame == expected)
        #expect(window.frame.width < screen.frame.width)

        window.apply(mode: .desktop, placement: .desktopDefault, screen: screen)
        #expect(window.level == DesktopWindow.desktopLevel)
        #expect(window.frame == screen.frame)
    }
}

/// Opt-in, because it puts a real avatar on a real screen for a few seconds and
/// then asks the WindowServer what it sees. Compiling is not the same as being
/// visible: the whole point of floating mode is a level and a rectangle that only
/// the WindowServer can confirm.
///
///     AKARI_FLOATING_PREVIEW=1 swift test
///
@MainActor
@Suite("floating avatar, on screen",
       .enabled(if: ProcessInfo.processInfo.environment["AKARI_FLOATING_PREVIEW"] == "1"
                && NSScreen.main != nil))
struct FloatingAvatarPreviewTests {
    @Test("she is on screen at level 3, in a window the size of the box")
    func floatingWindowIsWhereItSaysItIs() async throws {
        _ = NSApplication.shared
        let screen = try #require(NSScreen.main)
        let displayID = try #require(screen.displayID)
        let assets = URL(filePath: ProcessInfo.processInfo.environment["AKARI_ASSETS_DIR"]
                         ?? "/Volumes/data/Dev/01-PWR/akari/assets/akari")

        let window = DesktopWindow(screen: screen, displayID: displayID,
                                   mode: .floating, placement: .floatingDefault)
        defer { window.teardown() }
        let player = AvatarPlayer(assetDirectory: assets)
        try player.preload()
        player.transition(to: .idle, duration: 0)
        window.attach(player.rootLayer)
        window.show()
        try await Task.sleep(for: .seconds(3))

        let onscreen = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let mine = onscreen.first { ($0[kCGWindowNumber as String] as? Int) == window.windowNumber }
        let entry = try #require(mine, "the floating window is not on screen at all")
        #expect(entry[kCGWindowLayer as String] as? Int == 3)

        let boundsDict = try #require(entry[kCGWindowBounds as String] as? NSDictionary)
        let bounds = try #require(CGRect(dictionaryRepresentation: boundsDict as CFDictionary))
        let expected = AvatarGeometry.frames(mode: .floating, placement: .floatingDefault,
                                             screenFrame: screen.frame).window
        // CGWindow bounds are top-left origin; only the size is directly comparable.
        #expect(bounds.size == expected.size)
        // And she is actually playing, not a transparent hole.
        #expect(player.frontClipURL != nil)
    }
}
