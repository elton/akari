import AppKit
import Foundation
import Testing
@testable import AkariApp

// The wallpaper module. Everything here runs without a real desktop: the one
// call that would change the developer's own wallpaper goes through
// `DesktopPictureIO`, and every test injects a fake for it. Artwork lives in a
// throwaway temp directory, so a machine that happens to have real artwork
// cannot make a test pass that would otherwise fail.

// MARK: - Doubles

@MainActor
private final class FakeDesktopPictureIO: DesktopPictureIO {
    var attached: [WallpaperDisplay]
    /// What each display currently shows, as `NSWorkspace` would report it.
    var showing: [String: WallpaperPicture] = [:]
    /// Display keys whose `setPicture` throws.
    var refusing: Set<String> = []
    private(set) var setCalls: [(display: String, picture: WallpaperPicture)] = []

    init(attached: [WallpaperDisplay]) {
        self.attached = attached
    }

    func displays() -> [WallpaperDisplay] { attached }

    func currentPicture(on display: WallpaperDisplay) -> WallpaperPicture? {
        showing[display.key]
    }

    func setPicture(_ picture: WallpaperPicture, on display: WallpaperDisplay) throws {
        if refusing.contains(display.key) {
            throw WallpaperError.setFailed(display: display.key, reason: "fake")
        }
        setCalls.append((display.key, picture))
        showing[display.key] = picture
    }
}

private enum Fixture {
    static let displayA = WallpaperDisplay(id: 2, key: "AAAA-1111")
    static let displayB = WallpaperDisplay(id: 4, key: "BBBB-2222")

    /// A defaults instance nobody else shares, so a failed test cannot leak into
    /// the next one or into the developer's real preferences.
    static func defaults() -> UserDefaults {
        let name = "akari.tests.wallpaper.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// A directory holding `akari-wallpaper.png` — the no-suffix form, so light
    /// and dark both resolve to the same file and the assertions do not depend
    /// on what the test machine's appearance happens to be.
    static func artworkDirectory() throws -> URL {
        let directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "akari-wallpaper-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not-a-real-png".utf8)
            .write(to: directory.appending(path: "\(WallpaperCatalog.baseName).png"))
        return directory
    }

    static func picture(_ path: String) -> WallpaperPicture {
        WallpaperPicture(url: URL(filePath: path), scaling: 3, allowsClipping: true,
                         fillColor: [0.1, 0.2, 0.3, 1])
    }

    @MainActor
    static func controller(io: FakeDesktopPictureIO,
                           directory: URL,
                           defaults: UserDefaults,
                           kind: WallpaperOriginKind = .imageFile) -> WallpaperController {
        WallpaperController(io: io, directory: directory, defaults: defaults, originKind: { kind })
    }
}

// MARK: - Naming and resolution convention

@Suite("wallpaper catalog")
struct WallpaperCatalogTests {
    @Test("the suffixed artwork wins over the bare one, and heic over png")
    func preferenceOrder() {
        let directory = URL(filePath: "/art")
        let present: Set<String> = [
            "/art/akari-wallpaper-light.png",
            "/art/akari-wallpaper.heic",
        ]
        let resolved = WallpaperCatalog.resolve(in: directory, appearance: .light) {
            present.contains($0.path(percentEncoded: false))
        }
        // `-light` outranks the bare stem even though the bare one is a heic:
        // naming the appearance is a stronger statement than the container.
        #expect(resolved?.lastPathComponent == "akari-wallpaper-light.png")

        let heicFirst = WallpaperCatalog.resolve(in: directory, appearance: .light) { url in
            url.deletingPathExtension().lastPathComponent == "akari-wallpaper-light"
        }
        #expect(heicFirst?.pathExtension == "heic")
    }

    @Test("dark falls back through light rather than reporting nothing")
    func darkFallsBack() {
        let directory = URL(filePath: "/art")
        let onlyLight: Set<String> = ["/art/akari-wallpaper-light.png"]
        #expect(WallpaperCatalog.resolve(in: directory, appearance: .dark) {
            onlyLight.contains($0.path(percentEncoded: false))
        }?.lastPathComponent == "akari-wallpaper-light.png")

        let onlyBare: Set<String> = ["/art/akari-wallpaper.jpg"]
        #expect(WallpaperCatalog.resolve(in: directory, appearance: .dark) {
            onlyBare.contains($0.path(percentEncoded: false))
        }?.lastPathComponent == "akari-wallpaper.jpg")

        let onlyDark: Set<String> = ["/art/akari-wallpaper-dark.png"]
        #expect(WallpaperCatalog.resolve(in: directory, appearance: .dark) {
            onlyDark.contains($0.path(percentEncoded: false))
        }?.lastPathComponent == "akari-wallpaper-dark.png")
        // …and the dark-only install must not leak into the light appearance.
        #expect(WallpaperCatalog.resolve(in: directory, appearance: .light) {
            onlyDark.contains($0.path(percentEncoded: false))
        } == nil)
    }

    @Test("nothing installed resolves to nothing, and the search list is printable")
    func missingIsNotAGuess() {
        let directory = URL(filePath: "/art")
        #expect(WallpaperCatalog.resolve(in: directory, appearance: .light) { _ in false } == nil)
        let candidates = WallpaperCatalog.candidates(in: directory, appearance: .dark)
        #expect(candidates.count == 3 * WallpaperCatalog.extensions.count)
        #expect(candidates.allSatisfy { $0.path(percentEncoded: false).hasPrefix("/art/akari-wallpaper") })
    }

    @Test("a free-form name is still artwork, ranked by how well it covers 5K")
    func sizeSuffixedDropWorksWithoutRenaming() {
        // Exactly what the artwork drop looks like: three sizes, no appearance
        // suffix anywhere. Nothing may need renaming for this to resolve.
        let listing: [(name: String, pixels: CGSize?)] = [
            ("akari-wallpaper-2560x1440.png", CGSize(width: 2560, height: 1440)),
            ("akari-wallpaper-5504.png", CGSize(width: 5504, height: 3072)),
            ("akari-wallpaper-5120x2880.png", CGSize(width: 5120, height: 2880)),
        ]
        #expect(WallpaperCatalog.rank(listing, appearance: .light).first == "akari-wallpaper-5120x2880.png")
        // The oversized one still beats the undersized one: cropping a 5504
        // master is invisible, upscaling a 2560 one is not.
        #expect(WallpaperCatalog.rank(listing, appearance: .light) == [
            "akari-wallpaper-5120x2880.png",
            "akari-wallpaper-5504.png",
            "akari-wallpaper-2560x1440.png",
        ])
    }

    @Test("ranking keeps the appearance suffixes meaningful and ignores strangers")
    func rankRespectsAppearanceAndPrefix() {
        let listing: [(name: String, pixels: CGSize?)] = [
            ("akari-wallpaper-dark-5120x2880.png", WallpaperCatalog.masterPixelSize),
            ("akari-wallpaper-light-5120x2880.png", WallpaperCatalog.masterPixelSize),
            ("akari-wallpaper-plain.png", WallpaperCatalog.masterPixelSize),
            ("README.md", nil),
            ("someone-elses-photo.png", WallpaperCatalog.masterPixelSize),
            ("akari-wallpaper.txt", WallpaperCatalog.masterPixelSize),
        ]
        // Dark artwork must never be served to a light desktop.
        let light = WallpaperCatalog.rank(listing, appearance: .light)
        #expect(light == ["akari-wallpaper-light-5120x2880.png", "akari-wallpaper-plain.png"])
        // Dark prefers its own, then the neutral one, then light as a last resort.
        #expect(WallpaperCatalog.rank(listing, appearance: .dark) == [
            "akari-wallpaper-dark-5120x2880.png",
            "akari-wallpaper-plain.png",
            "akari-wallpaper-light-5120x2880.png",
        ])
        // Neither a foreign name nor a foreign extension is artwork.
        #expect(!light.contains("someone-elses-photo.png"))
        #expect(!light.contains("akari-wallpaper.txt"))
        #expect(!light.contains("README.md"))
    }

    @Test("a file whose header will not parse sorts last but is not thrown away")
    func unreadableHeaderStillCounts() {
        let listing: [(name: String, pixels: CGSize?)] = [
            ("akari-wallpaper-a.png", nil),
            ("akari-wallpaper-b.png", CGSize(width: 640, height: 360)),
        ]
        #expect(WallpaperCatalog.rank(listing, appearance: .light)
                == ["akari-wallpaper-b.png", "akari-wallpaper-a.png"])
        #expect(WallpaperCatalog.rank([("akari-wallpaper-a.png", nil)], appearance: .light)
                == ["akari-wallpaper-a.png"])
    }

    @Test("under-sized artwork is a warning, never a refusal")
    func resolutionWarning() {
        let url = URL(filePath: "/art/akari-wallpaper.png")
        #expect(WallpaperCatalog.resolutionWarning(for: WallpaperCatalog.masterPixelSize, at: url) == nil)
        #expect(WallpaperCatalog.resolutionWarning(for: CGSize(width: 8192, height: 4320), at: url) == nil)
        #expect(WallpaperCatalog.resolutionWarning(for: CGSize(width: 2560, height: 1440), at: url) != nil)
        // Unreadable is its own sentence: "smaller than 5K" would be a lie about
        // a file that is not an image at all.
        let unreadable = WallpaperCatalog.resolutionWarning(for: nil, at: url)
        #expect(unreadable?.contains("读不出尺寸") == true)
    }
}

// MARK: - Reading the system's wallpaper store

@Suite("wallpaper store probe")
struct WallpaperStoreProbeTests {
    /// The shape this machine actually had: one Aerial, filed under `Linked`
    /// because desktop and screen saver were the same choice.
    private static func aerialIndex() -> [String: Any] { [
        "AllSpacesAndDisplays": [
            "Type": "linked",
            "Linked": ["Content": ["Choices": [
                ["Provider": "com.apple.wallpaper.choice.aerials"],
            ]]],
        ],
        "Displays": [String: Any](),
    ] }

    /// The shape `setDesktopImageURL` leaves behind: an image on the desktop,
    /// and the Aerial demoted to the screen saver slot.
    private static func imageIndex() -> [String: Any] { [
        "Displays": [
            "UUID-1": [
                "Desktop": ["Content": ["Choices": [
                    ["Provider": "com.apple.wallpaper.choice.image"],
                ]]],
                "Idle": ["Content": ["Choices": [
                    ["Provider": "com.apple.wallpaper.choice.aerials"],
                ]]],
            ],
        ],
    ] }

    @Test("an aerial desktop is recognised as something that cannot be put back")
    func aerialIsNotAnImage() {
        #expect(WallpaperStoreProbe.kind(fromIndex: Self.aerialIndex())
                == .notAnImage(provider: "com.apple.wallpaper.choice.aerials"))
    }

    @Test("an aerial *screen saver* does not count as the desktop")
    func idleIsIgnored() {
        // This is the regression that would otherwise flag every machine with an
        // Aerial screen saver — including this one, right after akari applies.
        #expect(WallpaperStoreProbe.kind(fromIndex: Self.imageIndex()) == .imageFile)
    }

    @Test("a store this build cannot read is unknown, not a failure")
    func unreadableIsUnknown() {
        #expect(WallpaperStoreProbe.kind(fromIndex: [String: Any]()) == .unknown)
        #expect(WallpaperStoreProbe.kind(fromIndex: ["Displays": ["x": ["Idle": ["Content": ["Choices": [["Provider": "com.apple.wallpaper.choice.aerials"]]]]]]]) == .unknown)
        #expect(WallpaperStoreProbe.kind(fromIndex: "nonsense") == .unknown)
    }

    @Test("the API's placeholder path is the second tell, used only when the store is unknown")
    func placeholderBacksUpTheProbe() {
        let placeholder = URL(filePath: WallpaperStoreProbe.placeholderPath)
        let ordinary = URL(filePath: "/Users/me/Pictures/mine.jpg")

        #expect(WallpaperStoreProbe.looksUnrestorable(kind: .unknown, reported: placeholder))
        #expect(!WallpaperStoreProbe.looksUnrestorable(kind: .unknown, reported: ordinary))
        #expect(!WallpaperStoreProbe.looksUnrestorable(kind: .unknown, reported: nil))
        // A store that says "image" outranks the placeholder heuristic, and one
        // that says "aerial" outranks an innocent-looking path.
        #expect(!WallpaperStoreProbe.looksUnrestorable(kind: .imageFile, reported: placeholder))
        #expect(WallpaperStoreProbe.looksUnrestorable(kind: .notAnImage(provider: "x"), reported: ordinary))
    }
}

// MARK: - Backup record

@Suite("wallpaper backup")
struct WallpaperBackupTests {
    @Test("a display with no entry of its own borrows one deterministically")
    func hotPluggedDisplayStillReverts() {
        let backup = WallpaperBackup(entries: ["BBBB-2222": Fixture.picture("/b.jpg"),
                                               "AAAA-1111": Fixture.picture("/a.jpg")],
                                     capturedAt: Date(), faithful: true)
        #expect(backup.picture(for: Fixture.displayA)?.url.path == "/a.jpg")
        // Attached after the backup was taken: it gets the lowest-keyed entry
        // rather than nothing, so it does not sit there wearing akari's artwork
        // while every other panel reverts.
        let newcomer = WallpaperDisplay(id: 9, key: "ZZZZ-9999")
        #expect(backup.picture(for: newcomer)?.url.path == "/a.jpg")
    }

    @MainActor
    @Test("a backup written today is readable by a controller built tomorrow")
    func survivesRelaunch() throws {
        let defaults = Fixture.defaults()
        let directory = try Fixture.artworkDirectory()
        let io = FakeDesktopPictureIO(attached: [Fixture.displayA])
        io.showing[Fixture.displayA.key] = Fixture.picture("/Users/me/mine.jpg")

        let first = Fixture.controller(io: io, directory: directory, defaults: defaults)
        try first.applyBundledWallpaper()
        #expect(first.hasBackup)

        // A different object, same defaults — the launch after next.
        let second = Fixture.controller(io: io, directory: directory, defaults: defaults)
        #expect(second.hasBackup)
        #expect(second.backup?.entries[Fixture.displayA.key]?.url.path == "/Users/me/mine.jpg")
    }

    @MainActor
    @Test("a blob this build cannot decode disables restore instead of inventing one")
    func corruptBlobIsNoBackup() throws {
        let defaults = Fixture.defaults()
        defaults.set(Data("{not json".utf8), forKey: WallpaperController.backupDefaultsKey)
        let controller = Fixture.controller(io: FakeDesktopPictureIO(attached: []),
                                            directory: try Fixture.artworkDirectory(),
                                            defaults: defaults)
        #expect(!controller.hasBackup)
        #expect(throws: WallpaperError.nothingToRestore) { try controller.restoreOriginal() }
    }
}

// MARK: - Applying and restoring

@MainActor
@Suite("wallpaper controller")
struct WallpaperControllerTests {
    @Test("every attached display is set, and what each was showing is remembered")
    func appliesToAllDisplays() throws {
        let defaults = Fixture.defaults()
        let directory = try Fixture.artworkDirectory()
        let io = FakeDesktopPictureIO(attached: [Fixture.displayA, Fixture.displayB])
        io.showing[Fixture.displayA.key] = Fixture.picture("/Users/me/a.jpg")
        io.showing[Fixture.displayB.key] = Fixture.picture("/Users/me/b.jpg")

        let controller = Fixture.controller(io: io, directory: directory, defaults: defaults)
        try controller.applyBundledWallpaper()

        #expect(io.setCalls.count == 2)
        #expect(io.setCalls.allSatisfy { $0.picture.url.lastPathComponent == "akari-wallpaper.png" })
        // Fill, crop, black behind — not whatever the previous picture used.
        #expect(io.setCalls.allSatisfy { $0.picture.allowsClipping == true })
        #expect(controller.backup?.entries.count == 2)
        #expect(controller.backup?.faithful == true)
        #expect(controller.backup?.entries[Fixture.displayB.key]?.url.path == "/Users/me/b.jpg")
    }

    @Test("the second launch does not back up akari's own artwork over the user's")
    func backupIsTakenOnce() throws {
        let defaults = Fixture.defaults()
        let directory = try Fixture.artworkDirectory()
        let io = FakeDesktopPictureIO(attached: [Fixture.displayA])
        io.showing[Fixture.displayA.key] = Fixture.picture("/Users/me/mine.jpg")

        let controller = Fixture.controller(io: io, directory: directory, defaults: defaults)
        try controller.applyBundledWallpaper()
        // The desktop now shows akari's file. Applying again — a relaunch, a
        // hot-plug, an appearance flip — must not turn that into "the original".
        try controller.applyBundledWallpaper()
        #expect(controller.backup?.entries[Fixture.displayA.key]?.url.path == "/Users/me/mine.jpg")

        // Even a brand-new controller with a wiped backup refuses to record our
        // own artwork, so a lost backup cannot become a wrong one.
        defaults.removeObject(forKey: WallpaperController.backupDefaultsKey)
        let fresh = Fixture.controller(io: io, directory: directory, defaults: defaults)
        try fresh.applyBundledWallpaper()
        #expect(!fresh.hasBackup)
    }

    @Test("restore puts each display back and then has nothing left to do")
    func restorePutsBackPerDisplay() throws {
        let defaults = Fixture.defaults()
        let directory = try Fixture.artworkDirectory()
        let io = FakeDesktopPictureIO(attached: [Fixture.displayA, Fixture.displayB])
        io.showing[Fixture.displayA.key] = Fixture.picture("/Users/me/a.jpg")
        io.showing[Fixture.displayB.key] = Fixture.picture("/Users/me/b.jpg")

        let controller = Fixture.controller(io: io, directory: directory, defaults: defaults)
        try controller.applyBundledWallpaper()
        try controller.restoreOriginal()

        #expect(io.showing[Fixture.displayA.key]?.url.path == "/Users/me/a.jpg")
        #expect(io.showing[Fixture.displayB.key]?.url.path == "/Users/me/b.jpg")
        // The fitting comes back too: a picture the user had centred must not
        // come back stretched.
        #expect(io.showing[Fixture.displayA.key]?.fillColor == [0.1, 0.2, 0.3, 1])
        #expect(!controller.hasBackup)
        #expect(throws: WallpaperError.nothingToRestore) { try controller.restoreOriginal() }
    }

    @Test("a dynamic wallpaper is refused once, out loud, before anything changes")
    func dynamicOriginalIsRefusedFirst() throws {
        let defaults = Fixture.defaults()
        let directory = try Fixture.artworkDirectory()
        let io = FakeDesktopPictureIO(attached: [Fixture.displayA])
        // What this machine really reports under an Aerial.
        io.showing[Fixture.displayA.key] =
            WallpaperPicture(url: URL(filePath: WallpaperStoreProbe.placeholderPath),
                             scaling: nil, allowsClipping: nil, fillColor: nil)

        let controller = Fixture.controller(
            io: io, directory: directory, defaults: defaults,
            kind: .notAnImage(provider: "com.apple.wallpaper.choice.aerials"))

        #expect(throws: WallpaperError.originalNotRestorable(provider: "com.apple.wallpaper.choice.aerials")) {
            try controller.applyBundledWallpaper()
        }
        // Nothing changed on the way out: the sentence has to be read *before*
        // the desktop is gone, not after.
        #expect(io.setCalls.isEmpty)
        #expect(!controller.hasBackup)

        // Clicking again is the consent. Now it applies — and says so in the
        // backup rather than pretending the restore will work.
        try controller.applyBundledWallpaper()
        #expect(io.setCalls.count == 1)
        #expect(controller.backup?.faithful == false)
        // `hasBackup` is the settings window's "is 恢复 clickable" question, so it
        // has to be false here: a restore from this backup would install a file
        // the user never chose. `hasReplacedWallpaper` is what stops the window
        // from then claiming akari never touched the desktop.
        #expect(!controller.hasBackup)
        #expect(controller.hasReplacedWallpaper)
        #expect(throws: WallpaperError.restoreNotPossible) { try controller.restoreOriginal() }
    }

    @Test("launch applies only when the switch is on and the question was answered")
    func launchRespectsBothFlags() throws {
        let defaults = Fixture.defaults()
        let directory = try Fixture.artworkDirectory()
        let io = FakeDesktopPictureIO(attached: [Fixture.displayA])
        io.showing[Fixture.displayA.key] = Fixture.picture("/Users/me/mine.jpg")
        let controller = Fixture.controller(io: io, directory: directory, defaults: defaults)

        controller.applyAtLaunch(enabled: false, consented: true)
        controller.applyAtLaunch(enabled: true, consented: false)
        #expect(io.setCalls.isEmpty)

        controller.applyAtLaunch(enabled: true, consented: true)
        #expect(io.setCalls.count == 1)
    }

    @Test("missing artwork says where to put it instead of crashing")
    func missingArtworkIsSurvivable() throws {
        let defaults = Fixture.defaults()
        let empty = URL(filePath: NSTemporaryDirectory())
            .appending(path: "akari-empty-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let io = FakeDesktopPictureIO(attached: [Fixture.displayA])
        io.showing[Fixture.displayA.key] = Fixture.picture("/Users/me/mine.jpg")
        let controller = Fixture.controller(io: io, directory: empty, defaults: defaults)

        var thrown: (any Error)?
        #expect(throws: (any Error).self) {
            do { try controller.applyBundledWallpaper() } catch { thrown = error; throw error }
        }
        let message = (thrown as? WallpaperError)?.errorDescription ?? ""
        #expect(message.contains("akari-wallpaper"))
        #expect(message.contains(empty.lastPathComponent))
        #expect(io.setCalls.isEmpty)
        // The launch path swallows it — a desktop picture is not worth an app
        // that will not start.
        controller.applyAtLaunch(enabled: true, consented: true)
        #expect(io.setCalls.isEmpty)
    }

    @Test("a display attached later gets the artwork; the others are left alone")
    func hotPlugOnlyTouchesNewDisplays() throws {
        let defaults = Fixture.defaults()
        let directory = try Fixture.artworkDirectory()
        let io = FakeDesktopPictureIO(attached: [Fixture.displayA])
        io.showing[Fixture.displayA.key] = Fixture.picture("/Users/me/a.jpg")
        let controller = Fixture.controller(io: io, directory: directory, defaults: defaults)
        try controller.applyBundledWallpaper()
        #expect(io.setCalls.count == 1)

        // The user changes display A's wallpaper by hand, then plugs in B.
        io.showing[Fixture.displayA.key] = Fixture.picture("/Users/me/handpicked.jpg")
        io.attached = [Fixture.displayA, Fixture.displayB]
        io.showing[Fixture.displayB.key] = Fixture.picture("/Users/me/b.jpg")
        controller.handleScreenConfigurationChange()

        #expect(io.setCalls.count == 2)
        #expect(io.setCalls.last?.display == Fixture.displayB.key)
        #expect(io.showing[Fixture.displayA.key]?.url.path == "/Users/me/handpicked.jpg")
        // Nothing new to do the second time it fires.
        controller.handleScreenConfigurationChange()
        #expect(io.setCalls.count == 2)
    }

    @Test("one display refusing does not strand the others")
    func partialFailureStillAppliesTheRest() throws {
        let defaults = Fixture.defaults()
        let directory = try Fixture.artworkDirectory()
        let io = FakeDesktopPictureIO(attached: [Fixture.displayA, Fixture.displayB])
        io.showing[Fixture.displayA.key] = Fixture.picture("/Users/me/a.jpg")
        io.showing[Fixture.displayB.key] = Fixture.picture("/Users/me/b.jpg")
        io.refusing = [Fixture.displayA.key]
        let controller = Fixture.controller(io: io, directory: directory, defaults: defaults)

        #expect(throws: (any Error).self) { try controller.applyBundledWallpaper() }
        // B got it even though A blew up, and the error still reached the caller
        // so the settings window says something rather than claiming success.
        #expect(io.setCalls.map(\.display) == [Fixture.displayB.key])
    }
}

// MARK: - What the artwork has to avoid

@Suite("wallpaper composition")
struct WallpaperCompositionTests {
    @Test("the avatar's default footprint is the region the artwork must keep clear")
    func avatarKeepOut() {
        // Recorded here so the number the wallpaper is composed against is a
        // test, not a sentence in a report that drifts the first time anyone
        // changes `AvatarPlacement.default`.
        let frame = AvatarPlacement.default.frame(inDisplayOfSize: CGSize(width: 2560, height: 1440))
        #expect(frame == CGRect(x: 1918, y: 0, width: 594, height: 792))
        // In physical pixels on a 5K panel: the right-hand 1188 columns of 5120,
        // the bottom 1584 rows of 2880.
        #expect(frame.width * 2 == 1188)
        #expect(frame.height * 2 == 1584)
    }
}
