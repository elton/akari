import Foundation
import Testing

@testable import AkariApp

/// Adversarial follow-up to `CoreResolutionTests`, which injects `isCorePackage`
/// and therefore proves the *policy* but never touches a disk.
///
/// This suite plants a real, complete `core/` package (package.json + src/index.ts)
/// in the directory above a real `.app` directory and runs the resolver against
/// the actual `FileManager`, which is the shape of the reported attack: unzip a
/// core next to akari.app in ~/Downloads.
@Suite("planted core on a real filesystem")
struct PlantedCoreTests {
    /// Builds `<tmp>/drop/akari.app/Contents/Resources/core` (optionally) and
    /// `<tmp>/drop/core` (the plant), and returns `<tmp>/drop`.
    private static func makeTree(withBundledCore: Bool) throws -> URL {
        let files = FileManager.default
        let root = URL(filePath: NSTemporaryDirectory())
            .appending(path: "akari-planted-\(UUID().uuidString)")
        let drop = root.appending(path: "drop")

        func writeCore(_ directory: URL) throws {
            try files.createDirectory(at: directory.appending(path: "src"),
                                      withIntermediateDirectories: true)
            try #"{"name":"akari-core"}"#
                .write(to: directory.appending(path: "package.json"), atomically: true, encoding: .utf8)
            try "console.log('planted')"
                .write(to: directory.appending(path: "src/index.ts"), atomically: true, encoding: .utf8)
        }

        try files.createDirectory(at: drop.appending(path: "akari.app/Contents/MacOS"),
                                  withIntermediateDirectories: true)
        try writeCore(drop.appending(path: "core"))
        if withBundledCore {
            try writeCore(drop.appending(path: "akari.app/Contents/Resources/core"))
        }
        return drop
    }

    private static func resolve(
        drop: URL,
        development: Bool,
        environment: [String: String] = [:]
    ) -> CoreProcess.CoreLocation? {
        CoreProcess.resolveCoreDirectory(
            bundleURL: drop.appending(path: "akari.app"),
            // The worst case for the app: repoRoot()'s upward walk *would* have
            // stopped here, because a real core/package.json is sitting here.
            checkoutRoot: drop,
            environment: environment,
            allowsDevelopmentPaths: development,
            // The real one. No stubbing.
            isCorePackage: CoreProcess.isCorePackage)
    }

    @Test("a real core dropped beside a real .app is not executed by a release build")
    func releaseIgnoresPlantedCore() throws {
        let drop = try Self.makeTree(withBundledCore: false)
        defer { try? FileManager.default.removeItem(at: drop.deletingLastPathComponent()) }

        // Sanity: the plant really is a complete core package by the app's own rule,
        // so a nil below is the policy refusing it, not the file check missing it.
        #expect(CoreProcess.isCorePackage(drop.appending(path: "core")))

        #expect(Self.resolve(drop: drop, development: false) == nil)
    }

    @Test("even a DEBUG build refuses the plant once it is running from a .app")
    func debugInsideBundleIgnoresPlantedCore() throws {
        let drop = try Self.makeTree(withBundledCore: false)
        defer { try? FileManager.default.removeItem(at: drop.deletingLastPathComponent()) }
        #expect(Self.resolve(drop: drop, development: true) == nil)
    }

    @Test("AKARI_CORE_ROOT cannot point a release build at the plant")
    func releaseIgnoresCoreRootPointingAtThePlant() throws {
        let drop = try Self.makeTree(withBundledCore: true)
        defer { try? FileManager.default.removeItem(at: drop.deletingLastPathComponent()) }

        let location = Self.resolve(drop: drop,
                                    development: false,
                                    environment: ["AKARI_CORE_ROOT": drop.path(percentEncoded: false)])
        // The bundled copy, not the plant.
        #expect(location?.origin == "app bundle")
        #expect(location?.directory.path(percentEncoded: false)
            .contains("akari.app/Contents/Resources/core") == true)
    }

    @Test("the bundled core is still found on a real filesystem")
    func bundledCoreStillResolves() throws {
        let drop = try Self.makeTree(withBundledCore: true)
        defer { try? FileManager.default.removeItem(at: drop.deletingLastPathComponent()) }
        let location = Self.resolve(drop: drop, development: false)
        #expect(location?.origin == "app bundle")
    }

    /// A half-dropped core (package.json only) must not count either.
    @Test("a lone package.json on disk is not a core package")
    func lonePackageJSONOnDisk() throws {
        let files = FileManager.default
        let root = URL(filePath: NSTemporaryDirectory()).appending(path: "akari-half-\(UUID().uuidString)")
        defer { try? files.removeItem(at: root) }
        let core = root.appending(path: "core")
        try files.createDirectory(at: core, withIntermediateDirectories: true)
        try "{}".write(to: core.appending(path: "package.json"), atomically: true, encoding: .utf8)
        #expect(!CoreProcess.isCorePackage(core))
    }

    /// `repoRoot()` is the function that does the upward walk. In a release build
    /// the walk is compiled out entirely, so it can never return a directory that
    /// merely happens to contain a `core/package.json`.
    @Test("repoRoot does not search in a release build")
    @MainActor
    func repoRootDoesNotSearchInRelease() {
        #if DEBUG
        // Nothing to assert here: the walk is supposed to be on.
        #expect(CoreProcess.allowsDevelopmentPaths)
        #else
        #expect(AppDelegate.repoRoot().path == Bundle.main.bundleURL.path)
        #endif
    }
}
