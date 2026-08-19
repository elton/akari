import Foundation
import Testing

@testable import AkariApp

/// Which core the app hands to `bun`, and which `bun` it uses.
///
/// Both questions are "what code does akari execute", so the tests are written
/// around the attack rather than around the happy path: the core is the socket
/// server, it sees the microphone uplink, it draws the confirmation cards and it
/// holds DASHSCOPE_API_KEY. Anything that gets to be the core owns the app.
@Suite("core resolution")
struct CoreResolutionTests {
    /// `~/Downloads/akari.app`, with the real bundle laid out beside whatever
    /// else happens to be in ~/Downloads.
    private static let downloads = URL(filePath: "/Users/someone/Downloads")
    private static let bundle = downloads.appending(path: "akari.app")
    private static let checkout = URL(filePath: "/Users/someone/Dev/akari")

    /// `directoryHint: .isDirectory` leaves a trailing slash on the resolved
    /// URL, so compare the paths rather than the URLs.
    private static func samePath(_ lhs: URL?, _ rhs: URL) -> Bool {
        func normalize(_ url: URL) -> String {
            let path = url.standardizedFileURL.path(percentEncoded: false)
            return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        }
        return lhs.map(normalize) == normalize(rhs)
    }

    /// A file tree in which exactly the listed directories are core packages.
    private static func packages(_ directories: [URL]) -> (URL) -> Bool {
        let paths = Set(directories.map { $0.standardizedFileURL.path })
        return { paths.contains($0.standardizedFileURL.path) }
    }

    private static func resolve(
        bundleURL: URL,
        checkoutRoot: URL? = checkout,
        environment: [String: String] = [:],
        development: Bool,
        packagesAt: [URL]
    ) -> CoreProcess.CoreLocation? {
        CoreProcess.resolveCoreDirectory(
            bundleURL: bundleURL,
            checkoutRoot: checkoutRoot,
            environment: environment,
            allowsDevelopmentPaths: development,
            isCorePackage: packages(packagesAt))
    }

    @Test("the development gate follows the build configuration")
    func developmentGateMatchesTheBuildConfiguration() {
        // Everything above is policy given a gate value; this is the gate. It is
        // the one thing no injected argument can stand in for, so it is checked
        // in both configurations: `swift test` and `swift test -c release`.
        #if DEBUG
        #expect(CoreProcess.allowsDevelopmentPaths)
        #else
        #expect(!CoreProcess.allowsDevelopmentPaths)
        #endif
    }

    // MARK: - The reported hole

    @Test("a release build ignores a core planted next to the .app")
    func plantedCoreBesideTheBundle() {
        // The attack: unzip `core/package.json` + `core/src/index.ts` into
        // ~/Downloads, where the user already dropped akari.app. No prompt, no
        // privilege. The old upward walk found it and ran it.
        let planted = Self.downloads.appending(path: "core")
        let location = Self.resolve(
            bundleURL: Self.bundle,
            checkoutRoot: Self.downloads,
            development: false,
            packagesAt: [planted])
        #expect(location == nil)
    }

    @Test("a release build ignores a core anywhere above the .app")
    func plantedCoreFurtherUp() {
        let planted = URL(filePath: "/Users/someone/core")
        let location = Self.resolve(
            bundleURL: Self.bundle,
            checkoutRoot: URL(filePath: "/Users/someone"),
            development: false,
            packagesAt: [planted])
        #expect(location == nil)
    }

    @Test("even a DEBUG build refuses to search once it runs from a .app")
    func debugBuildInsideABundleDoesNotSearch() {
        // `make app-bundle` defaults to CONFIG=debug, so DEBUG alone is not
        // enough of a signal: running from a bundle means this is the shipped
        // shape, and the bundled core is the only legitimate one.
        let planted = Self.downloads.appending(path: "core")
        let location = Self.resolve(
            bundleURL: Self.bundle,
            checkoutRoot: Self.downloads,
            development: true,
            packagesAt: [planted])
        #expect(location == nil)
    }

    // MARK: - The paths that must still work

    @Test("the bundled core wins, planted or not")
    func bundledCoreIsUsed() {
        let bundled = Self.bundle.appending(path: "Contents/Resources/core")
        let planted = Self.downloads.appending(path: "core")
        let location = Self.resolve(
            bundleURL: Self.bundle,
            checkoutRoot: Self.downloads,
            development: false,
            packagesAt: [bundled, planted])
        #expect(Self.samePath(location?.directory, bundled))
        #expect(location?.origin == "app bundle")
    }

    @Test("`swift run` from a checkout still finds the checkout's core")
    func checkoutCoreInDevelopment() {
        let core = Self.checkout.appending(path: "core")
        let location = Self.resolve(
            bundleURL: Self.checkout.appending(path: "app/.build/debug"),
            development: true,
            packagesAt: [core])
        #expect(Self.samePath(location?.directory, core))
        #expect(location?.origin == "checkout")
    }

    @Test("a lone package.json is not a core package")
    func incompletePackageIsRejected() {
        // `isCorePackage` demands package.json *and* src/index.ts; the tree here
        // has neither registered, standing in for a partial drop.
        let location = Self.resolve(
            bundleURL: Self.checkout.appending(path: "app/.build/debug"),
            development: true,
            packagesAt: [])
        #expect(location == nil)
    }

    // MARK: - AKARI_CORE_ROOT

    @Test("AKARI_CORE_ROOT is honoured in a DEBUG build")
    func coreRootOverrideInDevelopment() {
        let elsewhere = URL(filePath: "/Users/someone/Dev/akari-fork")
        let location = Self.resolve(
            bundleURL: Self.checkout.appending(path: "app/.build/debug"),
            environment: ["AKARI_CORE_ROOT": elsewhere.path],
            development: true,
            packagesAt: [elsewhere.appending(path: "core"), Self.checkout.appending(path: "core")])
        #expect(Self.samePath(location?.directory, elsewhere.appending(path: "core")))
        #expect(location?.origin == "AKARI_CORE_ROOT")
    }

    @Test("AKARI_CORE_ROOT is ignored in a release build")
    func coreRootOverrideIgnoredInRelease() {
        // The environment of a GUI app is chosen by whoever launched it, so in a
        // shipped build the variable must not be able to redirect execution —
        // the bundled core is used instead.
        let attacker = URL(filePath: "/tmp/evil")
        let bundled = Self.bundle.appending(path: "Contents/Resources/core")
        let location = Self.resolve(
            bundleURL: Self.bundle,
            environment: ["AKARI_CORE_ROOT": attacker.path],
            development: false,
            packagesAt: [attacker.appending(path: "core"), bundled])
        #expect(Self.samePath(location?.directory, bundled))
    }

    @Test("a wrong AKARI_CORE_ROOT fails loudly instead of falling back")
    func badCoreRootDoesNotFallBack() {
        let location = Self.resolve(
            bundleURL: Self.checkout.appending(path: "app/.build/debug"),
            environment: ["AKARI_CORE_ROOT": "/nowhere"],
            development: true,
            packagesAt: [Self.checkout.appending(path: "core")])
        #expect(location == nil)
    }
}

@Suite("bun resolution")
struct BunResolutionTests {
    private static func find(
        _ environment: [String: String],
        development: Bool,
        executables: [String]
    ) -> URL? {
        let set = Set(executables)
        return CoreProcess.findBun(
            environment: environment,
            allowsDevelopmentPaths: development,
            isExecutable: { set.contains($0) })
    }

    @Test("AKARI_BUN is honoured in a DEBUG build")
    func overrideInDevelopment() {
        let url = Self.find(["AKARI_BUN": "/opt/custom/bun"],
                            development: true,
                            executables: ["/opt/custom/bun", "/opt/homebrew/bin/bun"])
        #expect(url?.path == "/opt/custom/bun")
    }

    @Test("AKARI_BUN is ignored in a release build")
    func overrideIgnoredInRelease() {
        // Same reasoning as AKARI_CORE_ROOT: a launch agent or an LSEnvironment
        // entry must not turn "launch akari" into "run this binary".
        let url = Self.find(["AKARI_BUN": "/tmp/evil-bun"],
                            development: false,
                            executables: ["/tmp/evil-bun", "/opt/homebrew/bin/bun"])
        #expect(url?.path == "/opt/homebrew/bin/bun")
    }

    @Test("an AKARI_BUN that is not executable is rejected, not worked around")
    func nonExecutableOverride() {
        let url = Self.find(["AKARI_BUN": "/opt/custom/bun"],
                            development: true,
                            executables: ["/opt/homebrew/bin/bun"])
        #expect(url == nil)
    }

    @Test("without an override the usual install locations are searched in order")
    func standardLocations() {
        let url = Self.find(["HOME": "/Users/someone"],
                            development: true,
                            executables: ["/Users/someone/.bun/bin/bun", "/usr/local/bin/bun"])
        #expect(url?.path == "/Users/someone/.bun/bin/bun")
    }
}
