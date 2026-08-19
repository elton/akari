import Foundation
import Testing

@testable import AkariApp

/// Whether the app starts a core of its own — the one decision that can put two
/// cores on one socket.
///
/// The bug these are written against: the gate used to be "wait 2s, then spawn
/// unless the handshake has finished". Both halves are wrong. 2s is shorter than
/// the app's own reconnect backoff (0 / 0.25 / 0.75 / 1.75 / 3.75s), and the
/// handshake finishing is not what the question is about — a core that is up and
/// has not answered *us* yet is still a core. The observed cost was two cores,
/// the second one holding a per-minute Realtime session with no client on it.
///
/// So the tests below drive the gate off a real listening socket rather than off
/// a clock.
@Suite("core spawn gate")
struct CoreProcessSpawnGateTests {
    // MARK: - Fixtures

    /// A short directory under the temp dir: `sun_path` is 104 bytes and the
    /// probe is expected to refuse anything longer, so the fixture must not be
    /// the thing that trips it.
    private static func temporaryDirectory() throws -> URL {
        let directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "ak-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func address(for path: String) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        return address
    }

    /// A real unix socket bound and listening at `path`. Closing the returned
    /// descriptor stops the listener but leaves the inode behind — which is
    /// exactly what a core killed with SIGKILL leaves.
    private static func startListening(at path: String) throws -> CInt {
        var socketAddress = Self.address(for: path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(fd >= 0)
        unlink(path)
        let bound = withUnsafePointer(to: &socketAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        try #require(bound == 0, "bind failed: \(String(cString: strerror(errno)))")
        try #require(listen(fd, 4) == 0, "listen failed: \(String(cString: strerror(errno)))")
        return fd
    }

    // MARK: - What the socket says

    @Test("a listening core is seen even before it has said a word to us")
    func probeSeesALiveListener() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "core.sock").path(percentEncoded: false)

        let listener = try Self.startListening(at: path)
        defer { close(listener) }

        // No accept(), no handshake, nothing read: the core in `make run` is in
        // exactly this state for as long as bun takes to get through its
        // startup, and it is already the owner of the socket.
        #expect(CoreProcess.probeSocket(at: path) == .serving)
    }

    @Test("a socket file with nobody behind it is stale, not serving")
    func probeSeesAStaleSocketFile() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "core.sock").path(percentEncoded: false)

        let listener = try Self.startListening(at: path)
        close(listener)

        // The inode survives its listener; this is the SIGKILLed-core case.
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(CoreProcess.probeSocket(at: path) == .stale)
    }

    @Test("no socket file at all is absent")
    func probeSeesNothing() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "core.sock").path(percentEncoded: false)
        #expect(CoreProcess.probeSocket(at: path) == .absent)
    }

    @Test("a path longer than sun_path is refused rather than truncated")
    func probeRefusesAnOverlongPath() {
        let path = "/tmp/" + String(repeating: "a", count: 200) + "/core.sock"
        #expect(CoreProcess.probeSocket(at: path) == .unusable(ENAMETOOLONG))
    }

    // MARK: - The decision

    /// The regression, stated as a decision: core up, handshake not finished.
    /// The old gate answered "spawn" here, and that is the second core.
    @Test("a serving socket stops the spawn even while the app is still connecting")
    func servingSocketStopsTheSpawn() {
        #expect(!CoreProcess.shouldSpawn(probe: .serving, appIsConnected: false))
    }

    @Test("nothing on the socket means the app starts its own core")
    func absentOrStaleSocketSpawns() {
        #expect(CoreProcess.shouldSpawn(probe: .absent, appIsConnected: false))
        #expect(CoreProcess.shouldSpawn(probe: .stale, appIsConnected: false))
    }

    @Test("a socket we cannot speak to is not fixed by starting a core")
    func unusableSocketDoesNotSpawn() {
        #expect(!CoreProcess.shouldSpawn(probe: .unusable(EACCES), appIsConnected: false))
    }

    @Test("an app already connected never spawns, whatever the socket says")
    func connectedAppNeverSpawns() {
        #expect(!CoreProcess.shouldSpawn(probe: .absent, appIsConnected: true))
        #expect(!CoreProcess.shouldSpawn(probe: .stale, appIsConnected: true))
    }

    // MARK: - The gate, end to end

    /// The reported reproduction, minus the 8 second wait: a core is listening,
    /// the app has not completed its handshake, and the grace window expires.
    /// Nothing may be spawned.
    @Test("the gate does not start a core while one is listening")
    @MainActor
    func gateRefusesToStartASecondCore() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "core.sock").path(percentEncoded: false)
        let listener = try Self.startListening(at: path)
        defer { close(listener) }

        let core = CoreProcess()
        defer { core.terminate() }
        core.spawnUnlessCoreIsServing(socketPath: path,
                                      grace: .milliseconds(50),
                                      interval: .milliseconds(10)) { false }
        // Well past the grace window the old gate would have fired in.
        try await Task.sleep(for: .milliseconds(400))

        #expect(core.spawnAttempts == 0)
        #expect(!core.isSupervising)
    }

    // MARK: - One spawner at a time

    @Test("two app instances cannot both decide to start a core")
    func spawnLockIsExclusive() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = CoreProcess.spawnLockPath(
            besideSocketAt: directory.appending(path: "core.sock").path(percentEncoded: false))

        let first = try #require(CoreProcess.claimSpawnLock(at: path))
        #expect(CoreProcess.claimSpawnLock(at: path) == nil)

        // flock lives on the open file description, so releasing it frees the
        // path for the next app — including after a crash, which is why this is
        // not a pid file.
        close(first)
        let second = try #require(CoreProcess.claimSpawnLock(at: path))
        close(second)
    }

    // MARK: - Whose core is it

    /// `make run-core` + `make run-app`: the core was not started by the app, so
    /// the app owes it no `app.quit` on the way out. `AppDelegate` gates that
    /// send on exactly this flag.
    @Test("a core the app did not start is not one the app supervises")
    @MainActor
    func aForeignCoreIsNotSupervised() {
        #expect(!CoreProcess().isSupervising)
    }
}
