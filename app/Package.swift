// swift-tools-version:6.2
import PackageDescription

// akari.app — the thin Swift/AppKit glue layer.
//
// Built with SwiftPM (no .xcodeproj) so `swift build` works from the command line
// and in CI. `make app-bundle` wraps the produced binary into akari.app; a real
// bundle is required before any TCC permission (Accessibility, Microphone) can be
// tested honestly — see spec.md §4.4 "责任进程陷阱".
let package = Package(
    name: "AkariApp",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "akari", targets: ["AkariApp"])
    ],
    targets: [
        .executableTarget(
            name: "AkariApp",
            path: "Sources/AkariApp"
        ),
        // Whatever in the app can be exercised without a live desktop, a live
        // socket or a live microphone: the pure decision logic each module
        // keeps at its edges.
        .testTarget(
            name: "AkariAppTests",
            dependencies: ["AkariApp"],
            path: "Tests/AkariAppTests"
        ),
    ]
)
