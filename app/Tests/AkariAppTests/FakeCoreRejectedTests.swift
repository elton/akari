import Foundation
import Testing

@testable import AkariApp

/// The reported attack, reproduced: a process that is not the core binds the
/// socket the app is pointed at, and waits for the app to hand over the session.
/// The real thing was a `bun` script under `AKARI_SOCKET`; the only part that
/// matters is that it is *some* process holding *that path*, which is what
/// `FakeCore` is.
///
/// Adversarial counterpart to `SocketTrustPolicyTests`: no injection, a real
/// `AF_UNIX` listener, a real `lstat`, and the real `CoreBridge` dialing it.
/// Revert `checkSocketBeforeDialing` and `rejectsWorldWritableDirectory` /
/// `rejectsLooseSocketMode` fail — the app connects and the fake core gets its
/// accept.
@Suite("a fake core does not get the app")
struct FakeCoreRejectedTests {
    @Test @MainActor
    func acceptsTheRealThing() async throws {
        let fake = try FakeCore(directoryMode: 0o700, socketMode: 0o600)
        defer { fake.stop() }

        let bridge = CoreBridge(socketPath: fake.path)
        bridge.connect()
        defer { bridge.disconnect() }

        // The control: proves the harness is a socket the app *would* dial, so
        // the refusals below are the check firing and not a broken fixture.
        #expect(await fake.waitForConnection(within: .seconds(3)),
                "a 0600 socket in a 0700 directory must still be connectable")
    }

    @Test @MainActor
    func rejectsWorldWritableDirectory() async throws {
        // 0600 on the socket buys nothing here: anyone who can write the
        // directory can unlink the core's socket and bind their own.
        let fake = try FakeCore(directoryMode: 0o777, socketMode: 0o600)
        defer { fake.stop() }

        let bridge = CoreBridge(socketPath: fake.path)
        bridge.connect()
        defer { bridge.disconnect() }

        #expect(await !fake.waitForConnection(within: .seconds(2)),
                "the app connected to a socket in a directory anything can write to")
        #expect(bridge.state == .disconnected)
    }

    @Test @MainActor
    func rejectsLooseSocketMode() async throws {
        let fake = try FakeCore(directoryMode: 0o700, socketMode: 0o666)
        defer { fake.stop() }

        let bridge = CoreBridge(socketPath: fake.path)
        bridge.connect()
        defer { bridge.disconnect() }

        #expect(await !fake.waitForConnection(within: .seconds(2)),
                "the app connected to a socket the core would never have created")
        #expect(bridge.state == .disconnected)
    }

    /// Asserted on the verdict rather than through `CoreBridge`: connecting to a
    /// regular file fails in the kernel anyway, so a bridge-level assertion here
    /// would pass with the check removed and prove nothing. What is worth
    /// checking on a real filesystem is that `lstat` tells the two apart.
    @Test
    func aPlainFileIsNotMistakenForASocket() throws {
        let directory = try FakeCore.makeDirectory(mode: 0o700)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "c.sock").path(percentEncoded: false)
        FileManager.default.createFile(atPath: path, contents: Data(),
                                       attributes: [.posixPermissions: 0o600])

        #expect(SocketTrust.verify(socketPath: path).isRefused)
    }

    /// The same, for a symlink pointing at a socket that *would* pass: `lstat`
    /// has to see the link, not the target it resolves to.
    @Test
    func aSymlinkToAGoodSocketIsStillRefused() throws {
        let fake = try FakeCore(directoryMode: 0o700, socketMode: 0o600)
        defer { fake.stop() }
        #expect(SocketTrust.verify(socketPath: fake.path) == .trusted)

        let link = fake.directory.appending(path: "link.sock").path(percentEncoded: false)
        try #require(symlink(fake.path, link) == 0)
        #expect(SocketTrust.verify(socketPath: link).isRefused)
    }
}

/// A unix socket bound by something that is not akari-core, with the modes the
/// test asks for. It never accepts on its own: `waitForConnection` polls, so a
/// connection that lands in the backlog is still detected.
private final class FakeCore {
    let directory: URL
    let path: String
    private var fd: Int32 = -1

    init(directoryMode: mode_t, socketMode: mode_t) throws {
        directory = try Self.makeDirectory(mode: 0o700)
        path = directory.appending(path: "c.sock").path(percentEncoded: false)
        // 104 bytes on macOS, and a bind failure past that says nothing useful.
        let bytes = Array(path.utf8)
        try #require(bytes.count < 104, "test socket path is too long for sun_path")

        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(fd >= 0, "socket(2) failed: \(errno)")

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        try #require(bound == 0, "bind(2) failed: \(errno)")
        try #require(chmod(path, socketMode) == 0)
        try #require(listen(fd, 4) == 0)
        // Non-blocking so the poll below never parks the test on accept(2).
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        // Loosened last: the app has to see the directory the way it is now, and
        // a 0777 mkdir would be masked by umask anyway.
        try #require(chmod(directory.path(percentEncoded: false), directoryMode) == 0)
    }

    static func makeDirectory(mode: mode_t) throws -> URL {
        // Short by design: the whole path has to fit in `sun_path`.
        let directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "ak-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try #require(chmod(directory.path(percentEncoded: false), mode) == 0)
        return directory
    }

    /// True as soon as somebody has connected. Polls rather than blocking so a
    /// refusal costs the timeout and nothing else.
    func waitForConnection(within timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            let client = accept(fd, nil, nil)
            if client >= 0 {
                close(client)
                return true
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return false
    }

    func stop() {
        if fd >= 0 { close(fd) }
        fd = -1
        // 0700 again, or the temp directory cannot be removed on some setups.
        _ = chmod(directory.path(percentEncoded: false), 0o700)
        try? FileManager.default.removeItem(at: directory)
    }
}
