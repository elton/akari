//
//  Wallpaper.swift — the companion desktop picture: apply it, remember what it
//  replaced, and put that back.
//
//  # What macOS 26 actually lets a third-party app do (measured, 26.6.2 / 25G83)
//
//  The user asked for "the matching *dynamic* wallpaper". It cannot be done, and
//  the measurement rather than the guess is why:
//
//  * `NSWorkspace.setDesktopImageURL` is the only public door, and it renders a
//    still frame even from a file macOS itself treats as dynamic.
//    `/System/Library/Desktop Pictures/Sonoma.heic` is a two-image HEIC carrying
//    `apple_desktop:apr` (the light/dark pair). Set through the API, then toggled
//    to Dark mode: the Dock's `Wallpaper-<UUID>` window came back **byte-identical**
//    (5120x2880 capture, max per-channel diff 0.0) after 3s, after 8s, and after
//    re-issuing the call while already in Dark. So the API drops the dynamic
//    metadata; spec.md §4.1's "setDesktopImageURL 只吃静态图" holds on 26.
//  * The store the API writes (`~/Library/Application Support/com.apple.wallpaper/
//    Store/Index.plist`) confirms it from the other side: the recorded choice is
//    `Provider = com.apple.wallpaper.choice.image`, `Configuration =
//    {type: imageFile, url: …}`, with no dynamic/appearance option at all — the
//    same provider a plain JPEG gets.
//  * Video wallpapers (the Sonoma/Tahoe "Aerials") are a different provider,
//    `com.apple.wallpaper.choice.aerials`, keyed by an asset UUID. There is no
//    public API that selects one, and `WallpaperExtensionKit` is private
//    (spec.md: `com.apple.private.wallpaper.extension`, verified unobtainable).
//
//  So: a still image is the ceiling for the *desktop picture*. Anything that has
//  to move belongs on our own desktop-layer window (`DesktopWindow`), which is
//  already there and already below the Finder icons.
//
//  What this file does deliver on top of a plain still: it picks the light or the
//  dark artwork itself and re-picks it when the system appearance flips, which is
//  the half of "dynamic" a user actually notices day to day.
//
//  # Restoring is not symmetric with applying, and the difference is measured
//
//  `NSWorkspace.desktopImageURL(for:)` lies when the wallpaper is not an image
//  file. On this machine, with an Aerial ("Tahiti Waves") set, it returned
//  `/System/Library/CoreServices/DefaultDesktop.heic` for both displays — a file
//  that is nothing like what was on screen. Backing that up and calling it "your
//  original wallpaper" would produce a restore that silently installs the wrong
//  picture and reports success.
//
//  Hence `WallpaperStoreProbe`: a **read-only** look at the same Index.plist to
//  find out whether the thing being replaced is an image file at all. If it is
//  not, the first `applyBundledWallpaper()` refuses and says so; a second call
//  proceeds, and `restoreOriginal()` then refuses rather than lying.
//
//  Nothing here ever *writes* the private store. (It is possible — a byte copy of
//  Index.plist plus `killall -9 WallpaperAgent`, copy, `killall -9` again does put
//  an Aerial back, verified — but it is an undocumented file owned by a live
//  daemon, and losing a user's whole wallpaper configuration is a worse failure
//  than not offering the restore.)
//
//  # Where the avatar sits, for whoever draws the artwork
//
//  Default desktop placement is `AvatarPlacement.default` — bottom-trailing, 55%
//  of display height, 810:1080, 48pt side margin, 0 bottom margin. On a
//  2560x1440 logical display that is x 1918…2512, y 0…792 from the bottom left:
//  the right-hand ~23% of the width and the bottom ~55% of the height. The
//  wallpaper's subject should stay clear of it. See `AvatarPlacement.frame`.
//

import AppKit
import Foundation
import ImageIO
import os

private let wallpaperLog = Logger(subsystem: "me.eltonzheng.akari", category: "wallpaper")

// MARK: - Appearance

/// Which of the two artworks the desktop should be showing.
///
/// macOS will not switch between them for us (see the file header), so akari
/// picks one and re-picks on `AppleInterfaceThemeChangedNotification`.
enum WallpaperAppearance: String, Sendable, CaseIterable {
    case light, dark

    /// The one in effect right now. Main-actor because `NSApp` is.
    @MainActor
    static var current: WallpaperAppearance {
        let name = NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()
        let match = name.bestMatch(from: [.aqua, .darkAqua])
        return match == .darkAqua ? .dark : .light
    }
}

// MARK: - Naming and resolution convention

/// Where the companion artwork lives and what it has to be called.
///
/// ## Naming
///
/// Everything in `assets/brand/wallpaper/` whose name starts with
/// `akari-wallpaper` and ends in `heic`, `png`, `jpg` or `jpeg` is artwork. Two
/// suffixes are meaningful, and only two:
///
/// ```
/// akari-wallpaper-light.png       the light-appearance artwork
/// akari-wallpaper-dark.png        the dark one; optional, light is used instead
/// akari-wallpaper.png             neither — used for both appearances
/// akari-wallpaper-5120x2880.png   also "neither"; the rest of the name is free
/// ```
///
/// The exact stems above are matched first, in that order. Anything else that
/// starts with `akari-wallpaper` is still artwork, picked by **pixel size**:
/// closest to the master below, preferring one that covers it. That is what
/// makes a drop of `-2560x1440` / `-5120x2880` / `-5504` work without a rename,
/// and it is why the size suffix is a free-form label rather than a parsed
/// field — the file itself already says how big it is.
///
/// Extensions are tried `heic, png, jpg, jpeg`: same picture, HEIC is about a
/// third of the bytes at this size and decodes in hardware.
///
/// ## Resolution
///
/// Master is **5120x2880** (16:9, sRGB): the physical pixel size of the target
/// 5K panels, whose logical size is 2560x1440 at 2x. Anything smaller is used
/// anyway — it is not worth refusing to draw a desktop over — but it is logged,
/// because a soft wallpaper on a 5K panel is otherwise a mystery. The picture is
/// applied with proportional scaling plus clipping, so a differently-shaped
/// display crops rather than letterboxes.
enum WallpaperCatalog {
    static let baseName = "akari-wallpaper"
    /// HEIC first: same picture, ~1/3 the bytes, hardware decode.
    static let extensions = ["heic", "png", "jpg", "jpeg"]
    /// The size the artwork is authored at. Smaller is a warning, not an error.
    static let masterPixelSize = CGSize(width: 5120, height: 2880)

    /// File stems to try, in order, for one appearance.
    ///
    /// Dark falls back through light so a one-artwork install behaves like a
    /// one-artwork install rather than like a missing file.
    static func stems(for appearance: WallpaperAppearance) -> [String] {
        switch appearance {
        case .light: ["\(baseName)-light", baseName]
        case .dark: ["\(baseName)-dark", "\(baseName)-light", baseName]
        }
    }

    /// Every exact-name path that would be accepted, in preference order. Also
    /// what the "not found" error carries, so the message can name the directory
    /// the user is supposed to put the file in.
    static func candidates(in directory: URL,
                           appearance: WallpaperAppearance) -> [URL] {
        stems(for: appearance).flatMap { stem in
            extensions.map { directory.appending(path: "\(stem).\($0)", directoryHint: .notDirectory) }
        }
    }

    /// The exact-name candidate that exists, if any.
    ///
    /// `fileExists` is injected so the whole naming convention is testable
    /// against a made-up directory listing — a test must not need real artwork
    /// on disk, and it must not silently pass because the developer happens to
    /// have some.
    static func resolve(in directory: URL,
                        appearance: WallpaperAppearance,
                        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }) -> URL? {
        candidates(in: directory, appearance: appearance).first(where: fileExists)
    }

    /// Rank a directory listing when no exact-name file matched.
    ///
    /// Pure over `(name, pixelSize)` pairs so the ranking is testable without
    /// any artwork on disk. The order is: files that cover the master first,
    /// then by how far the pixel count is from the master, then by name so two
    /// equally good files always resolve to the same one.
    ///
    /// The appearance filter is by name only, because that is the only thing a
    /// file can say about it: `-dark` is dark artwork and is never used for the
    /// light appearance; `-light` is only used for dark once nothing better is
    /// left; everything else serves both.
    static func rank(_ files: [(name: String, pixels: CGSize?)],
                     appearance: WallpaperAppearance) -> [String] {
        func tier(_ name: String) -> Int? {
            let stem = (name as NSString).deletingPathExtension
            let isDark = stem.contains("-dark")
            let isLight = stem.contains("-light")
            switch appearance {
            case .light: return isDark ? nil : (isLight ? 0 : 1)
            case .dark: return isDark ? 0 : (isLight ? 2 : 1)
            }
        }
        let masterPixels = masterPixelSize.width * masterPixelSize.height
        return files.compactMap { file -> (String, Int, Int, Double)? in
            let stem = (file.name as NSString).deletingPathExtension
            guard stem.hasPrefix(baseName),
                  extensions.contains((file.name as NSString).pathExtension.lowercased()),
                  let tier = tier(file.name)
            else { return nil }
            // No readable size is not a disqualification — it sorts last within
            // its tier rather than vanishing, so a lone unreadable-header file
            // is still tried and still produces a real error if it is broken.
            guard let pixels = file.pixels else { return (file.name, tier, 2, .infinity) }
            let area = pixels.width * pixels.height
            return (file.name, tier, area >= masterPixels ? 0 : 1, abs(area - masterPixels))
        }
        .sorted {
            ($0.1, $0.2, $0.3, $0.0) < ($1.1, $1.2, $1.3, $1.0)
        }
        .map(\.0)
    }

    /// The exact-name match if there is one, otherwise the best-ranked file in
    /// the directory. nil only when the directory holds no artwork at all.
    static func bestArtwork(in directory: URL, appearance: WallpaperAppearance) -> URL? {
        if let exact = resolve(in: directory, appearance: appearance) { return exact }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
        else { return nil }
        let listing = names.map { name -> (name: String, pixels: CGSize?) in
            (name, pixelSize(of: directory.appending(path: name, directoryHint: .notDirectory)))
        }
        guard let best = rank(listing, appearance: appearance).first else { return nil }
        return directory.appending(path: best, directoryHint: .notDirectory)
    }

    /// `AKARI_WALLPAPER_DIR`, then the bundle's Resources, then
    /// `<repo>/assets/brand/wallpaper` so `swift run` from a checkout finds the
    /// artwork with no setup. Mirrors `AppDelegate.resolveAssetDirectory`.
    @MainActor
    static func defaultDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["AKARI_WALLPAPER_DIR"],
           !override.isEmpty {
            return URL(filePath: override)
        }
        let bundled = Bundle.main.bundleURL
            .appending(path: "Contents/Resources/wallpaper", directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: bundled.path(percentEncoded: false)) {
            return bundled
        }
        return AppDelegate.repoRoot()
            .appending(path: "assets/brand/wallpaper", directoryHint: .isDirectory)
    }

    /// Pixel dimensions without decoding the image. nil when the file is not a
    /// readable image — which is itself worth saying out loud.
    static func pixelSize(of url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return CGSize(width: width, height: height)
    }

    /// The sentence to log when the artwork is smaller than the panel it is
    /// about to be stretched across. nil when there is nothing to complain about.
    static func resolutionWarning(for size: CGSize?, at url: URL) -> String? {
        guard let size else {
            return "壁纸文件读不出尺寸（可能不是图片）：\(url.lastPathComponent)"
        }
        guard size.width < masterPixelSize.width || size.height < masterPixelSize.height else {
            return nil
        }
        return "壁纸只有 \(Int(size.width))x\(Int(size.height))，"
            + "小于 5K 屏的 \(Int(masterPixelSize.width))x\(Int(masterPixelSize.height))，放大后会发虚："
            + url.lastPathComponent
    }
}

// MARK: - One display

/// A display, identified by the two things that are needed for different spans
/// of time.
///
/// `id` is what CoreGraphics and AppKit take, and is re-issued on sleep, wake and
/// hot-plug (docs/decisions.md). `key` is the display's UUID, which survives all
/// of those and a reboot — so it, not `id`, is what a backup written today and
/// read next week is filed under.
struct WallpaperDisplay: Equatable, Hashable, Sendable {
    let id: CGDirectDisplayID
    let key: String

    /// Falls back to the numeric id when CoreGraphics has no UUID (it returns
    /// none for some virtual/captured displays). Worse as a persistent key, but
    /// better than dropping the display.
    init(id: CGDirectDisplayID) {
        self.id = id
        if let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() {
            self.key = CFUUIDCreateString(nil, uuid) as String
        } else {
            self.key = "display-\(id)"
        }
    }

    init(id: CGDirectDisplayID, key: String) {
        self.id = id
        self.key = key
    }
}

/// A desktop picture as `NSWorkspace` describes it: the file plus how it is fitted.
///
/// The fitting is carried because dropping it makes "restore" visibly wrong — a
/// picture the user had centred comes back stretched, and they have no way to
/// know akari did that.
struct WallpaperPicture: Codable, Equatable, Sendable {
    var url: URL
    /// `NSImageScaling.rawValue`. Optional because `desktopImageOptions` returns
    /// an empty dictionary for a wallpaper it cannot describe.
    var scaling: Int?
    var allowsClipping: Bool?
    /// sRGB r,g,b,a. Four values or nil; anything else is treated as nil.
    var fillColor: [Double]?

    /// How akari's own artwork is fitted: fill the panel, crop the overflow,
    /// black behind anything that still does not cover.
    static func bundled(_ url: URL) -> WallpaperPicture {
        WallpaperPicture(url: url,
                         scaling: Int(NSImageScaling.scaleProportionallyUpOrDown.rawValue),
                         allowsClipping: true,
                         fillColor: [0, 0, 0, 1])
    }
}

// MARK: - The backup

/// What was on the desktop before akari first replaced it.
///
/// Persisted, because "恢复我原来的壁纸" is a button the user may press three
/// launches later. Versioned and decoded defensively: a blob this build cannot
/// read is treated as *no backup*, which disables the restore button — strictly
/// better than restoring something invented.
struct WallpaperBackup: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version = WallpaperBackup.currentVersion
    /// Display UUID → the picture that display had.
    var entries: [String: WallpaperPicture]
    var capturedAt: Date
    /// The wallpaper being replaced was an image file, so putting it back is a
    /// faithful restore. False for Aerials, video and slideshows, where
    /// `desktopImageURL` reports a placeholder rather than what is on screen.
    var faithful: Bool

    /// The entry to use for a display, falling back to any other recorded entry.
    ///
    /// The fallback matters on hot-plug: a display attached after the backup was
    /// taken has no entry of its own, and leaving akari's artwork on it while
    /// every other panel reverts is the worse outcome. Sorted so the choice is
    /// deterministic rather than dictionary-order.
    func picture(for display: WallpaperDisplay) -> WallpaperPicture? {
        entries[display.key] ?? entries.sorted { $0.key < $1.key }.first?.value
    }
}

// MARK: - Reading the system's wallpaper store

/// What kind of thing the current wallpaper is, as far as it can be told.
enum WallpaperOriginKind: Equatable, Sendable {
    /// An image file — `NSWorkspace` can describe it, so it can be restored.
    case imageFile
    /// An Aerial, video or slideshow. `desktopImageURL` reports a placeholder.
    case notAnImage(provider: String)
    /// The store could not be read or understood. Assume the API is telling the
    /// truth; say nothing rather than cry wolf.
    case unknown
}

/// A read-only look at `com.apple.wallpaper`'s own store.
///
/// This exists because the public API cannot answer "is the thing I am about to
/// replace something I can put back". Every failure mode collapses to
/// `.unknown`, and `.unknown` never blocks anything — the probe can only ever
/// add a warning, never remove a capability.
enum WallpaperStoreProbe {
    static let relativePath = "Library/Application Support/com.apple.wallpaper/Store/Index.plist"

    /// Keys whose subtree describes the **desktop**. `Idle` is the screen saver
    /// and is deliberately not one of them: after `setDesktopImageURL` the user's
    /// Aerial is still filed under `Idle`, and counting it would report every
    /// machine with an Aerial screen saver as unrestorable.
    private static let desktopKeys: Set<String> = ["Desktop", "Linked"]

    static let imageProvider = "com.apple.wallpaper.choice.image"

    /// Classify a parsed `Index.plist`.
    ///
    /// Pure, so the two shapes that matter — an Aerial under `Linked` (what this
    /// machine had) and an image under `Displays/<uuid>/Desktop` (what the API
    /// writes) — are testable without touching anybody's desktop.
    static func kind(fromIndex root: Any) -> WallpaperOriginKind {
        var providers: [String] = []
        collectProviders(root, underDesktop: false, into: &providers)
        guard !providers.isEmpty else { return .unknown }
        if let foreign = providers.first(where: { $0 != imageProvider }) {
            return .notAnImage(provider: foreign)
        }
        return .imageFile
    }

    private static func collectProviders(_ node: Any, underDesktop: Bool, into out: inout [String]) {
        if let dictionary = node as? [String: Any] {
            if underDesktop, let provider = dictionary["Provider"] as? String {
                out.append(provider)
            }
            for (key, value) in dictionary {
                collectProviders(value, underDesktop: underDesktop || desktopKeys.contains(key), into: &out)
            }
        } else if let array = node as? [Any] {
            for value in array {
                collectProviders(value, underDesktop: underDesktop, into: &out)
            }
        }
    }

    /// Read and classify the live store. Never throws: an unreadable or
    /// re-shaped store is `.unknown`.
    static func currentKind(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> WallpaperOriginKind {
        let url = home.appending(path: relativePath, directoryHint: .notDirectory)
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
        else { return .unknown }
        return kind(fromIndex: plist)
    }

    /// The file `desktopImageURL` reports when the real wallpaper is not an image.
    ///
    /// Measured: with an Aerial set on both 5K panels, both displays reported
    /// this path. It is a second, API-level tell for the same fact, used when the
    /// store probe comes back `.unknown` so a re-shaped store still produces the
    /// warning.
    static let placeholderPath = "/System/Library/CoreServices/DefaultDesktop.heic"

    /// Does this look like a wallpaper akari cannot faithfully put back?
    static func looksUnrestorable(kind: WallpaperOriginKind, reported: URL?) -> Bool {
        switch kind {
        case .notAnImage: true
        case .imageFile: false
        case .unknown: reported?.path(percentEncoded: false) == placeholderPath
        }
    }
}

// MARK: - The seam over NSWorkspace

/// Everything `WallpaperController` needs from the system, behind a protocol for
/// exactly one reason: a unit test must not be able to change the developer's
/// desktop. Same argument as `CredentialStore` in SettingsStore.swift.
@MainActor
protocol DesktopPictureIO: AnyObject {
    func displays() -> [WallpaperDisplay]
    func currentPicture(on display: WallpaperDisplay) -> WallpaperPicture?
    func setPicture(_ picture: WallpaperPicture, on display: WallpaperDisplay) throws
}

/// The real one.
@MainActor
final class SystemDesktopPictureIO: DesktopPictureIO {
    func displays() -> [WallpaperDisplay] {
        NSScreen.screens.compactMap { screen in
            screen.displayID.map(WallpaperDisplay.init(id:))
        }
    }

    func currentPicture(on display: WallpaperDisplay) -> WallpaperPicture? {
        guard let screen = screen(for: display),
              let url = NSWorkspace.shared.desktopImageURL(for: screen)
        else { return nil }
        let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
        return WallpaperPicture(url: url,
                                scaling: (options[.imageScaling] as? NSNumber)?.intValue,
                                allowsClipping: (options[.allowClipping] as? NSNumber)?.boolValue,
                                fillColor: Self.components(of: options[.fillColor] as? NSColor))
    }

    func setPicture(_ picture: WallpaperPicture, on display: WallpaperDisplay) throws {
        guard let screen = screen(for: display) else {
            throw WallpaperError.displayGone(display.key)
        }
        var options: [NSWorkspace.DesktopImageOptionKey: Any] = [:]
        if let scaling = picture.scaling { options[.imageScaling] = NSNumber(value: UInt(max(scaling, 0))) }
        if let clipping = picture.allowsClipping { options[.allowClipping] = NSNumber(value: clipping) }
        if let color = Self.color(from: picture.fillColor) { options[.fillColor] = color }
        do {
            try NSWorkspace.shared.setDesktopImageURL(picture.url, for: screen, options: options)
        } catch {
            throw WallpaperError.setFailed(display: display.key, reason: error.localizedDescription)
        }
    }

    /// `NSScreen` is re-created on sleep and hot-plug, so it is looked up by
    /// display id every time rather than held (docs/decisions.md).
    private func screen(for display: WallpaperDisplay) -> NSScreen? {
        NSScreen.screens.first { $0.displayID == display.id }
    }

    private static func components(of color: NSColor?) -> [Double]? {
        guard let converted = color?.usingColorSpace(.sRGB) else { return nil }
        return [converted.redComponent, converted.greenComponent,
                converted.blueComponent, converted.alphaComponent].map(Double.init)
    }

    private static func color(from components: [Double]?) -> NSColor? {
        guard let components, components.count == 4 else { return nil }
        return NSColor(srgbRed: components[0], green: components[1],
                       blue: components[2], alpha: components[3])
    }
}

// MARK: - Errors

/// Every one of these ends up in the settings window's notice line verbatim, so
/// they are written as sentences to a person, not as diagnostics.
enum WallpaperError: LocalizedError, Equatable {
    /// No artwork in any of the places that were looked at.
    case artworkMissing(searched: [String])
    /// Refusing the *first* attempt because the thing being replaced cannot be
    /// put back. A second attempt goes through.
    case originalNotRestorable(provider: String?)
    /// The restore button was pressed for a wallpaper akari never could restore.
    case restoreNotPossible
    case nothingToRestore
    case displayGone(String)
    case setFailed(display: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .artworkMissing(let searched):
            let directory = searched.first.map { ($0 as NSString).deletingLastPathComponent } ?? "?"
            return "找不到配套壁纸。把一张 5120x2880 的图放进 \(directory)，"
                + "文件名以 akari-wallpaper 开头（.heic/.png/.jpg 都行），再试一次。"
        case .originalNotRestorable(let provider):
            let what = provider == nil ? "动态壁纸" : "动态壁纸（\(Self.providerName(provider!))）"
            return "你现在用的是\(what)，macOS 没给第三方 App 任何接口把它设回去 —— "
                + "akari 换掉之后只能由你去「系统设置 › 墙纸」里重新选一次。"
                + "知道了的话，再点一次开关就换。"
        case .restoreNotPossible:
            return "换之前那张是动态壁纸，macOS 不允许第三方 App 设置它，"
                + "akari 恢复不了。请去「系统设置 › 墙纸」重新选一次。"
        case .nothingToRestore:
            return "没有可恢复的壁纸：akari 还没有换过你的桌面。"
        case .displayGone(let key):
            return "换壁纸时这块屏幕已经不在了（\(key)）。"
        case .setFailed(let display, let reason):
            return "屏幕 \(display) 换壁纸失败：\(reason)"
        }
    }

    private static func providerName(_ provider: String) -> String {
        switch provider {
        case "com.apple.wallpaper.choice.aerials": "航拍视频"
        case "com.apple.wallpaper.choice.slideshow": "幻灯片"
        default: provider
        }
    }
}

// MARK: - The controller

/// Applies the companion wallpaper, remembers what it replaced, and puts it back.
///
/// `NSObject` because the appearance and display-configuration notices come
/// through selector-based observers, the same shape `DesktopWindowController`
/// uses.
@MainActor
final class WallpaperController: NSObject, WallpaperControlling {
    /// Where the backup lives between launches. One blob rather than scalars —
    /// unlike `AvatarSettings`, a half-decoded backup is not usable at all, so
    /// all-or-nothing is the honest shape.
    static let backupDefaultsKey = "avatar.wallpaper.backup"

    private let io: any DesktopPictureIO
    private let directory: URL
    private let defaults: UserDefaults
    private let originKind: () -> WallpaperOriginKind

    /// Set once the user has been told, this launch, that their dynamic
    /// wallpaper cannot be restored. In memory on purpose: a relaunch is a fresh
    /// chance to notice, and the warning costs one extra click.
    private var unrestorableWarningGiven = false

    /// Displays this process has already applied to. Used so a hot-plug applies
    /// to the *new* panel without stamping over a wallpaper the user changed by
    /// hand on the others while akari was running.
    private var appliedDisplays: Set<String> = []

    private var observing = false

    init(io: any DesktopPictureIO = SystemDesktopPictureIO(),
         directory: URL,
         defaults: UserDefaults = .standard,
         originKind: @escaping () -> WallpaperOriginKind = { WallpaperStoreProbe.currentKind() }) {
        self.io = io
        self.directory = directory
        self.defaults = defaults
        self.originKind = originKind
        super.init()
    }

    deinit {
        // `removeObserver(self)` is safe from any thread and is the only teardown
        // these two registrations need.
        NotificationCenter.default.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }

    // MARK: WallpaperControlling

    /// Deliberately narrower than `backup != nil`: a backup taken over an Aerial
    /// holds `/System/Library/CoreServices/DefaultDesktop.heic`, which is not
    /// what was on screen. Offering "restore" from that would put a stranger's
    /// picture on the desktop and call it the user's own.
    var hasBackup: Bool { backup?.faithful == true }

    var hasReplacedWallpaper: Bool { backup != nil }

    func applyBundledWallpaper() throws {
        try apply(reason: .userAction)
    }

    func restoreOriginal() throws {
        guard let backup else { throw WallpaperError.nothingToRestore }
        guard backup.faithful else { throw WallpaperError.restoreNotPossible }

        var failure: (any Error)?
        for display in io.displays() {
            guard let picture = backup.picture(for: display) else { continue }
            do {
                try io.setPicture(picture, on: display)
            } catch {
                // Keep going: putting three of four displays back beats stopping
                // at the first one and leaving the rest wearing akari's artwork.
                wallpaperLog.error("restore failed on \(display.key, privacy: .public): \(error.localizedDescription, privacy: .public)")
                failure = failure ?? error
            }
        }
        if let failure { throw failure }

        self.backup = nil
        appliedDisplays.removeAll()
        stopObserving()
        wallpaperLog.info("restored the user's original wallpaper")
    }

    // MARK: Launch and configuration changes

    /// The launch path. Silent when the feature is off, and never fatal when it
    /// is on — a missing artwork file logs and leaves the desktop alone.
    ///
    /// Two `Bool`s rather than the whole settings value on purpose: this module
    /// needs exactly "the switch is on" and "the question was answered", and
    /// taking the struct would tie it to a type the 形象 section is still
    /// growing fields on.
    func applyAtLaunch(enabled: Bool, consented: Bool) {
        guard enabled, consented else { return }
        do {
            try apply(reason: .launch)
        } catch {
            wallpaperLog.error("launch wallpaper skipped: \(error.localizedDescription, privacy: .public)")
            FileHandle.standardError.write(Data("akari: \(error.localizedDescription)\n".utf8))
        }
    }

    /// A display was attached, removed or rearranged. Only *new* displays get
    /// akari's artwork.
    func handleScreenConfigurationChange() {
        let live = Set(io.displays().map(\.key))
        appliedDisplays.formIntersection(live)
        guard !live.subtracting(appliedDisplays).isEmpty else { return }
        try? apply(reason: .newDisplaysOnly)
    }

    /// The system flipped between light and dark. Re-picks the artwork, and does
    /// nothing at all when only one artwork is installed.
    func handleAppearanceChange() {
        guard !appliedDisplays.isEmpty else { return }
        try? apply(reason: .appearance)
    }

    // MARK: Apply

    private enum ApplyReason {
        case userAction, launch, newDisplaysOnly, appearance
    }

    private func apply(reason: ApplyReason) throws {
        let appearance = WallpaperAppearance.current
        guard let artwork = WallpaperCatalog.bestArtwork(in: directory, appearance: appearance) else {
            let searched = WallpaperCatalog.candidates(in: directory, appearance: appearance)
                .map { $0.path(percentEncoded: false) }
            wallpaperLog.error("no wallpaper artwork in \(self.directory.path(percentEncoded: false), privacy: .public)")
            throw WallpaperError.artworkMissing(searched: searched)
        }
        if let warning = WallpaperCatalog.resolutionWarning(for: WallpaperCatalog.pixelSize(of: artwork),
                                                           at: artwork) {
            wallpaperLog.warning("\(warning, privacy: .public)")
        }

        let displays = io.displays()
        let targets = reason == .newDisplaysOnly
            ? displays.filter { !appliedDisplays.contains($0.key) }
            : displays
        guard !targets.isEmpty else { return }

        try captureBackupIfNeeded(displays: displays, artwork: artwork, reason: reason)

        let picture = WallpaperPicture.bundled(artwork)
        var failure: (any Error)?
        for display in targets {
            do {
                try io.setPicture(picture, on: display)
                appliedDisplays.insert(display.key)
            } catch {
                wallpaperLog.error("apply failed on \(display.key, privacy: .public): \(error.localizedDescription, privacy: .public)")
                failure = failure ?? error
            }
        }
        if let failure { throw failure }

        startObserving()
        wallpaperLog.info("applied \(appearance.rawValue, privacy: .public) wallpaper to \(targets.count) display(s)")
    }

    /// Records what is on the desktop, once, before the first replacement.
    ///
    /// Two guards, and both are load-bearing on the second launch: a backup is
    /// only taken when there is none, and a display already wearing akari's
    /// artwork is never recorded — otherwise "your original wallpaper" quietly
    /// becomes akari's own.
    private func captureBackupIfNeeded(displays: [WallpaperDisplay],
                                       artwork: URL,
                                       reason: ApplyReason) throws {
        guard backup == nil else { return }

        var entries: [String: WallpaperPicture] = [:]
        var reported: URL?
        for display in displays {
            guard let picture = io.currentPicture(on: display) else { continue }
            reported = reported ?? picture.url
            guard !isOurArtwork(picture.url) else { continue }
            entries[display.key] = picture
        }
        guard !entries.isEmpty else { return }

        let kind = originKind()
        let unrestorable = WallpaperStoreProbe.looksUnrestorable(kind: kind, reported: reported)
        if unrestorable {
            // Refuse the first *deliberate* attempt so the sentence is read
            // before the desktop changes. A launch-time apply has already been
            // consented to and does not re-ask.
            if reason == .userAction && !unrestorableWarningGiven {
                unrestorableWarningGiven = true
                let provider: String? = if case .notAnImage(let name) = kind { name } else { nil }
                throw WallpaperError.originalNotRestorable(provider: provider)
            }
            wallpaperLog.warning("original wallpaper is not an image file; restore will not be offered")
        }

        backup = WallpaperBackup(entries: entries, capturedAt: Date(), faithful: !unrestorable)
        wallpaperLog.info("backed up \(entries.count) display(s), faithful=\(!unrestorable)")
    }

    /// Same directory and same stem family — enough to recognise our own file
    /// without caring which extension or appearance variant it was.
    private func isOurArtwork(_ url: URL) -> Bool {
        url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL
            && url.deletingPathExtension().lastPathComponent.hasPrefix(WallpaperCatalog.baseName)
    }

    // MARK: Persistence

    var backup: WallpaperBackup? {
        get {
            guard let data = defaults.data(forKey: Self.backupDefaultsKey),
                  let decoded = try? JSONDecoder().decode(WallpaperBackup.self, from: data),
                  decoded.version == WallpaperBackup.currentVersion,
                  !decoded.entries.isEmpty
            else { return nil }
            return decoded
        }
        set {
            guard let newValue else {
                defaults.removeObject(forKey: Self.backupDefaultsKey)
                return
            }
            guard let data = try? JSONEncoder().encode(newValue) else {
                wallpaperLog.error("could not encode the wallpaper backup; restore will be unavailable")
                return
            }
            defaults.set(data, forKey: Self.backupDefaultsKey)
        }
    }

    // MARK: Observers

    private func startObserving() {
        guard !observing else { return }
        observing = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersChanged(_:)),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        // Appearance changes arrive cross-process only. There is no AppKit
        // notification for the system theme on an LSUIElement app that never
        // draws a window, so this is the one that fires.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(themeChanged(_:)),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, suspensionBehavior: .deliverImmediately)
    }

    private func stopObserving() {
        guard observing else { return }
        observing = false
        NotificationCenter.default.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc private func screenParametersChanged(_ notification: Notification) {
        handleScreenConfigurationChange()
    }

    @objc private func themeChanged(_ notification: Notification) {
        handleAppearanceChange()
    }
}
