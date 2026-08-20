import Foundation
import Testing
@testable import AkariApp

// The 形象 section: the two layer modes, the per-mode placement, and the
// wallpaper switch that costs the user their desktop picture.
//
// Nothing here touches a screen or the real desktop. `UserDefaults` is a
// throwaway suite, and the wallpaper is a fake — a unit test that could repaint
// the developer's desktop is not a test anybody would run twice.

/// A `UserDefaults` suite that exists for one test and is removed afterwards.
private final class ScratchDefaults {
    let name = "me.eltonzheng.akari.tests.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() { defaults = UserDefaults(suiteName: name)! }
    deinit { UserDefaults().removePersistentDomain(forName: name) }
}

@MainActor
private final class FakeWallpaper: WallpaperControlling {
    var hasBackup = false
    var hasReplacedWallpaper = false
    var applyCount = 0
    var restoreCount = 0
    var applyError: (any Error)?
    var restoreError: (any Error)?

    struct Failure: LocalizedError {
        var errorDescription: String? { "壁纸接口没答应" }
    }

    func applyBundledWallpaper() throws {
        if let applyError { throw applyError }
        applyCount += 1
        hasBackup = true
        hasReplacedWallpaper = true
    }

    func restoreOriginal() throws {
        if let restoreError { throw restoreError }
        restoreCount += 1
        hasBackup = false
        hasReplacedWallpaper = false
    }
}

/// A `.env` reader that never reads anything. These tests have no business
/// touching the developer's `.env`, not even to fingerprint it.
private final class NoEnvFileReader: EnvFileReading {
    func value(forKey key: String, atPath path: String) throws -> String? { nil }
}

@MainActor
private func makeStore(_ scratch: ScratchDefaults,
                       wallpaper: (any WallpaperControlling)? = nil) -> SettingsStore {
    SettingsStore(store: InMemoryCredentialStore(),
                  envReader: NoEnvFileReader(),
                  keychainDataProtection: false,
                  avatarDefaults: scratch.defaults,
                  wallpaper: wallpaper)
}

@MainActor
@Suite("avatar settings")
struct AvatarSettingsTests {

    // MARK: Placement

    @Test("the two modes remember their own position, size and display scope")
    func modesAreRememberedSeparately() {
        let scratch = ScratchDefaults()
        let store = makeStore(scratch)

        #expect(store.avatar.mode == .desktop)
        store.setAvatarHeightFraction(0.8)
        store.setAvatarAnchor(.bottomLeading)
        store.setAvatarDisplayScope(.mainDisplayOnly)

        store.setAvatarMode(.floating)
        // Untouched: floating still has its own (small, main-display) defaults.
        #expect(store.avatar.current == AvatarLayerSettings.floatingDefault)
        store.setAvatarHeightFraction(0.15)
        store.setAvatarAnchor(.topTrailing)
        store.setAvatarDisplayScope(.allDisplays)

        store.setAvatarMode(.desktop)
        #expect(store.avatar.current.placement.heightFraction == 0.8)
        #expect(store.avatar.current.placement.anchor == .bottomLeading)
        #expect(store.avatar.current.displayScope == .mainDisplayOnly)
        #expect(store.avatar.presentation.floating.placement.heightFraction == 0.15)
        #expect(store.avatar.presentation.floating.placement.anchor == .topTrailing)
        #expect(store.avatar.presentation.floating.displayScope == .allDisplays)
    }

    @Test("what the window gets is the presentation, mode and all")
    func presentationFollowsMode() {
        let scratch = ScratchDefaults()
        let store = makeStore(scratch)
        store.setAvatarAnchor(.center)
        store.setAvatarHeightFraction(0.7)

        #expect(store.avatar.presentation.active.placement.anchor == .center)
        #expect(store.avatar.presentation.active.placement.heightFraction == 0.7)
        // The aspect ratio is a property of the clips, not of the user's choice.
        #expect(store.avatar.presentation.active.placement.aspectRatio
                == AvatarPlacement.default.aspectRatio)

        store.setAvatarMode(.floating)
        #expect(store.avatar.presentation.mode == .floating)
        #expect(store.avatar.presentation.active.placement == AvatarPlacement.floatingDefault)
    }

    @Test("a height outside the range never reaches the window")
    func heightIsClamped() {
        let scratch = ScratchDefaults()
        let store = makeStore(scratch)
        store.setAvatarHeightFraction(9)
        #expect(store.avatar.current.placement.heightFraction
                == AvatarPlacement.heightFractionRange.upperBound)
        store.setAvatarHeightFraction(-1)
        #expect(store.avatar.current.placement.heightFraction
                == AvatarPlacement.heightFractionRange.lowerBound)
    }

    @Test("changes are announced once, and only when something actually changed")
    func changesAreAnnouncedOnce() {
        let scratch = ScratchDefaults()
        let store = makeStore(scratch)
        var seen: [AvatarSettings] = []
        store.onAvatarSettingsChanged = { seen.append($0) }

        store.setAvatarMode(.floating)
        store.setAvatarMode(.floating)
        #expect(seen.count == 1)
        #expect(seen.last?.presentation.mode == .floating)
    }

    // MARK: Persistence

    @Test("everything survives a relaunch")
    func settingsRoundTrip() {
        let scratch = ScratchDefaults()
        let first = makeStore(scratch)
        first.setAvatarHeightFraction(0.42)
        first.setAvatarAnchor(.topLeading)
        first.setAvatarDisplayScope(.mainDisplayOnly)
        first.setAvatarMode(.floating)
        first.setAvatarHeightFraction(0.19)

        let second = makeStore(scratch)
        #expect(second.avatar.presentation == first.avatar.presentation)
        #expect(second.avatar.mode == .floating)
        #expect(second.avatar.presentation.floating.placement.heightFraction == 0.19)
        #expect(second.avatar.presentation.desktop.placement.heightFraction == 0.42)
        #expect(second.avatar.presentation.desktop.placement.anchor == .topLeading)
        #expect(second.avatar.presentation.desktop.displayScope == .mainDisplayOnly)
    }

    @Test("a stored blob this build cannot read falls back instead of taking the window down")
    func unreadableBlobFallsBack() {
        let scratch = ScratchDefaults()
        scratch.defaults.set(Data("{\"mode\":\"hologram\"}".utf8), forKey: "avatar.presentation")
        let store = makeStore(scratch)
        #expect(store.avatar.presentation == .default)
    }

    @Test("a blob written by a build with fewer fields still loads")
    func partialBlobLoads() {
        let scratch = ScratchDefaults()
        scratch.defaults.set(Data("{\"mode\":\"floating\"}".utf8), forKey: "avatar.presentation")
        let store = makeStore(scratch)
        #expect(store.avatar.mode == .floating)
        #expect(store.avatar.presentation.floating == .floatingDefault)
    }

    @Test("consent defaults to no, and the wallpaper stays off until it is given")
    func consentDefaultsToNo() {
        let scratch = ScratchDefaults()
        let store = makeStore(scratch)
        #expect(store.avatar.wallpaperConsented == false)
        #expect(store.avatar.wallpaperEnabled == false)
    }

    // MARK: Wallpaper

    @Test("turning the wallpaper on the first time asks before touching the desktop")
    func firstEnableAsksFirst() {
        let scratch = ScratchDefaults()
        let paper = FakeWallpaper()
        let store = makeStore(scratch, wallpaper: paper)

        store.setWallpaperEnabled(true)
        #expect(store.wallpaperConsentPending)
        // The switch has NOT moved and the desktop has NOT been touched.
        #expect(store.avatar.wallpaperEnabled == false)
        #expect(paper.applyCount == 0)

        store.cancelWallpaperConsent()
        #expect(store.wallpaperConsentPending == false)
        #expect(store.avatar.wallpaperEnabled == false)
        #expect(paper.applyCount == 0)
    }

    @Test("saying yes applies it now, and the question is not asked twice")
    func consentIsRememberedAndApplied() {
        let scratch = ScratchDefaults()
        let paper = FakeWallpaper()
        let store = makeStore(scratch, wallpaper: paper)

        store.setWallpaperEnabled(true)
        store.confirmWallpaperConsent()
        #expect(store.avatar.wallpaperEnabled)
        #expect(store.avatar.wallpaperConsented)
        #expect(paper.applyCount == 1)

        store.setWallpaperEnabled(false)
        #expect(store.avatar.wallpaperEnabled == false)
        // Turning it off does not put the old picture back — that is the button.
        #expect(paper.restoreCount == 0)

        store.setWallpaperEnabled(true)
        #expect(store.wallpaperConsentPending == false)
        #expect(paper.applyCount == 2)
    }

    @Test("consent survives a relaunch, so the question really is asked once")
    func consentIsPersisted() {
        let scratch = ScratchDefaults()
        let first = makeStore(scratch, wallpaper: FakeWallpaper())
        first.setWallpaperEnabled(true)
        first.confirmWallpaperConsent()

        let paper = FakeWallpaper()
        let second = makeStore(scratch, wallpaper: paper)
        #expect(second.avatar.wallpaperConsented)
        #expect(second.avatar.wallpaperEnabled)
        second.setWallpaperEnabled(false)
        second.setWallpaperEnabled(true)
        #expect(second.wallpaperConsentPending == false)
        #expect(paper.applyCount == 1)
    }

    @Test("a wallpaper that refuses leaves the switch off and says so")
    func failureDoesNotFlipTheSwitch() {
        let scratch = ScratchDefaults()
        let paper = FakeWallpaper()
        paper.applyError = FakeWallpaper.Failure()
        let store = makeStore(scratch, wallpaper: paper)

        store.setWallpaperEnabled(true)
        store.confirmWallpaperConsent()
        #expect(store.avatar.wallpaperEnabled == false)
        #expect(store.notice?.contains("壁纸接口没答应") == true)
    }

    @Test("restore is dead until there is something to restore")
    func restoreNeedsABackup() {
        let scratch = ScratchDefaults()
        let paper = FakeWallpaper()
        let store = makeStore(scratch, wallpaper: paper)

        #expect(store.canRestoreWallpaper == false)
        store.setWallpaperEnabled(true)
        store.confirmWallpaperConsent()
        #expect(store.canRestoreWallpaper)

        store.restoreOriginalWallpaper()
        #expect(paper.restoreCount == 1)
        // Restoring also stops it happening again at the next launch.
        #expect(store.avatar.wallpaperEnabled == false)
    }

    @Test("a restore that fails leaves the launch switch alone and reports")
    func restoreFailureIsReported() {
        let scratch = ScratchDefaults()
        let paper = FakeWallpaper()
        let store = makeStore(scratch, wallpaper: paper)
        store.setWallpaperEnabled(true)
        store.confirmWallpaperConsent()

        paper.restoreError = FakeWallpaper.Failure()
        store.restoreOriginalWallpaper()
        #expect(store.avatar.wallpaperEnabled)
        #expect(store.notice?.contains("壁纸接口没答应") == true)
    }

    @Test("with no wallpaper module wired up the window says so instead of pretending")
    func unwiredWallpaperIsAdmitted() {
        let scratch = ScratchDefaults()
        let store = makeStore(scratch)
        #expect(store.isWallpaperWired == false)
        #expect(store.canRestoreWallpaper == false)
        store.setWallpaperEnabled(true)
        store.confirmWallpaperConsent()
        #expect(store.avatar.wallpaperEnabled)
        #expect(store.notice?.contains("还没接上") == true)
        #expect(SettingsDisplay.wallpaperStatusLine(enabled: true, canRestore: false,
                                                    replaced: false, wired: false)
            .contains("还没接上"))
    }

    /// The state this machine is actually in: the desktop was an Aerial, akari
    /// replaced it, and there is no way back through this app. Neither the
    /// button nor the sentence may suggest otherwise.
    @Test("a wallpaper akari cannot put back is never advertised as restorable")
    func unrestorableOriginIsNotOfferedAsARestore() {
        let scratch = ScratchDefaults()
        let paper = FakeWallpaper()
        let store = makeStore(scratch, wallpaper: paper)
        store.setWallpaperEnabled(true)
        store.confirmWallpaperConsent()

        // What `WallpaperController` reports once it has replaced an Aerial: the
        // desktop is akari's, but the recorded "original" is a placeholder.
        paper.hasBackup = false
        paper.hasReplacedWallpaper = true

        #expect(store.canRestoreWallpaper == false)
        #expect(store.hasReplacedWallpaper)

        let line = SettingsDisplay.wallpaperStatusLine(enabled: true, canRestore: false,
                                                       replaced: true, wired: true)
        #expect(line.contains("恢复不了"))
        #expect(line.contains("系统设置") )
        #expect(!line.contains("随时可以换回去"))
        #expect(!line.contains("还没有换过"))

        // Pressing it anyway explains, rather than claiming nothing happened.
        store.restoreOriginalWallpaper()
        #expect(paper.restoreCount == 0)
        #expect(store.notice?.contains("恢复不了") == true)
    }
}

// MARK: - The honest preview

@Suite("avatar grounding")
struct AvatarGroundingTests {

    /// The numbers in `AvatarGrounding.boxes` are a copy of
    /// `assets/akari/anchors.json`. A copy drifts, and a drifted copy is exactly
    /// the idealised diagram the preview is not allowed to be — so this reads the
    /// real file.
    @Test("the table still matches assets/akari/anchors.json")
    func tableMatchesAnchorsFile() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // AkariAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // app
            .deletingLastPathComponent()   // repo root
        let url = root.appending(path: "assets/akari/anchors.json")
        guard let data = try? Data(contentsOf: url) else {
            // The clips are not in the repo (avatar-states.md §三); if the
            // manifest travelled with them there is nothing to compare against.
            return
        }
        struct Manifest: Decodable {
            struct Clip: Decodable {
                var name: String
                var boxX: Double, boxY: Double, boxWidth: Double, boxHeight: Double
                var canvasWidth: Double, canvasHeight: Double
            }
            var clips: [Clip]
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        var compared = 0
        for clip in manifest.clips {
            guard let state = AvatarState(rawValue: clip.name),
                  let box = AvatarGrounding.box(state) else { continue }
            compared += 1
            #expect(clip.canvasWidth == Double(AvatarBodyBox.canvas.width))
            #expect(clip.canvasHeight == Double(AvatarBodyBox.canvas.height))
            #expect(box.x == CGFloat(clip.boxX), "\(clip.name) boxX")
            #expect(box.y == CGFloat(clip.boxY), "\(clip.name) boxY")
            #expect(box.width == CGFloat(clip.boxWidth), "\(clip.name) boxWidth")
            #expect(box.height == CGFloat(clip.boxHeight), "\(clip.name) boxHeight")
        }
        #expect(compared == AvatarGrounding.boxes.count)
    }

    @Test("the states really do end at different heights")
    func bottomGapsDiffer() {
        #expect(AvatarGrounding.box(.idle)?.bottomGap == 1)
        #expect(AvatarGrounding.box(.greeting)?.bottomGap == 27)
        #expect(AvatarGrounding.box(.listening)?.bottomGap == 111)
        #expect(AvatarGrounding.box(.thinking)?.bottomGap == 97)
    }

    @Test("the preview quotes the lift in points, not an adjective")
    func gapLineQuotesTheLift() {
        // A 1080pt-tall avatar box makes canvas units and points the same number.
        #expect(AvatarGrounding.gapPoints(.listening, boxHeight: 1080) == 111)
        #expect(AvatarGrounding.gapPoints(.idle, boxHeight: 1080) == 1)
        let line = AvatarGrounding.gapLine(.listening, boxHeight: 1080)
        #expect(line.contains("111"))
        #expect(line.contains("110"))   // 111 - 1, the lift against idle
    }

    @Test("talking has no measurement, and the line says so rather than inventing one")
    func talkingHasNoMeasurement() {
        // There is no talking.mov in the shipped assets; AvatarPlayer falls back.
        #expect(AvatarGrounding.box(.talking) == nil)
        #expect(AvatarGrounding.previewStates.contains(.talking) == false)
        #expect(AvatarGrounding.gapLine(.talking, boxHeight: 1080).contains("没有实测数据"))
    }
}

@Suite("avatar display strings")
struct AvatarDisplayStringTests {
    @Test("each layer mode is explained, not just named")
    func modesAreExplained() {
        for mode in AvatarLayerMode.allCases {
            #expect(SettingsDisplay.avatarModeExplanation(mode).count > 30)
            #expect(SettingsDisplay.avatarModeHeadline(mode)
                .contains(SettingsDisplay.avatarModeName(mode)))
        }
        // The two facts the user did not have when the desktop layer was chosen.
        #expect(SettingsDisplay.avatarModeExplanation(.desktop).contains("盖住"))
        #expect(SettingsDisplay.avatarModeExplanation(.floating).contains("占住"))
    }

    @Test("every anchor has a name and appears exactly once in the grid")
    func anchorGridIsComplete() {
        let placed = SettingsDisplay.anchorGrid.flatMap { $0 }
        #expect(Set(placed) == Set(AvatarPlacement.Anchor.allCases))
        #expect(placed.count == AvatarPlacement.Anchor.allCases.count)
        #expect(SettingsDisplay.anchorGrid.allSatisfy { $0.count == 3 })
        // The grid must read like the screen: top row on top, leading on the left.
        for row in SettingsDisplay.anchorGrid {
            #expect(Set(row.map(\.verticalPosition)).count == 1)
            #expect(row.map(\.horizontalPosition) == [-1, 0, 1])
        }
        #expect(Set(AvatarPlacement.Anchor.allCases.map(SettingsDisplay.anchorName)).count
                == AvatarPlacement.Anchor.allCases.count)
    }

    @Test("the size ranges differ per mode and contain their defaults")
    func heightRangesFitTheirDefaults() {
        let desktop = SettingsDisplay.avatarHeightRange(.desktop)
        let floating = SettingsDisplay.avatarHeightRange(.floating)
        #expect(desktop != floating)
        #expect(desktop.contains(AvatarPlacement.desktopDefault.heightFraction))
        #expect(floating.contains(AvatarPlacement.floatingDefault.heightFraction))
        // Neither range may offer something the placement would silently clamp.
        for range in [desktop, floating] {
            #expect(AvatarPlacement.heightFractionRange.contains(range.lowerBound))
            #expect(AvatarPlacement.heightFractionRange.contains(range.upperBound))
        }
    }

    @Test("every display scope is named and explained in both modes")
    func scopesAreExplained() {
        for scope in AvatarDisplayScope.allCases {
            for mode in AvatarLayerMode.allCases {
                #expect(SettingsDisplay.avatarScopeExplanation(scope, mode: mode).count > 10)
            }
        }
        #expect(Set(AvatarDisplayScope.allCases.map(SettingsDisplay.avatarScopeName)).count
                == AvatarDisplayScope.allCases.count)
    }

    @Test("the consent text says what it costs before it is paid")
    func consentTextNamesTheCost() {
        #expect(SettingsDisplay.wallpaperConsentBody.contains("换"))
        #expect(SettingsDisplay.wallpaperConsentBody.contains("恢复我原来的壁纸"))
    }
}
