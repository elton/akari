import Foundation
import Synchronization
import os

private let coreLog = Logger(subsystem: "me.eltonzheng.akari", category: "core-process")

/// pid of the core *this app spawned*, or 0.
///
/// A global because the exit paths that need it take no context: `atexit` and a
/// signal handler are C function pointers and cannot capture. `Atomic` because a
/// signal handler may read it while the main actor writes it, and an atomic load
/// is async-signal-safe where an ordinary Swift property access is not.
private let supervisedCorePID = Atomic<pid_t>(0)

/// SIGTERM whatever core we started. Async-signal-safe: `kill` is on the list,
/// and the pid comes from an atomic that is already initialised.
private func killSupervisedCore() {
    let pid = supervisedCorePID.load(ordering: .relaxed)
    if pid > 0 { kill(pid, SIGTERM) }
}

/// Launches and supervises the `akari-core` Bun process.
///
/// The core is the socket *server*, so the app can perfectly well run against a
/// core somebody started by hand (`make run` does exactly that). Spawning a
/// second one would be actively harmful: `Bridge.listen` unlinks a stale socket
/// file before binding, so the newcomer would steal the path from the live core
/// — and the robbed core keeps a per-minute Realtime session open with nobody
/// on the other end.
///
/// So the question "is a core already running?" is never answered by a timer.
/// It is answered by `connect(2)` against the socket the core serves: a connect
/// that succeeds means a core owns that path, whether or not *our* handshake
/// has finished. Waiting on the handshake is what the first attempt at this got
/// wrong — the app's own reconnect backoff (0 / 0.25 / 0.75 / 1.75 / 3.75s)
/// routinely puts the first successful handshake past any fixed deadline.
@MainActor
final class CoreProcess {
    private var process: Process?
    private var probe: Task<Void, Never>?
    private var restarts = 0
    private var wantsRunning = false
    /// Held for as long as this app may start a core; see `claimSpawnLock`.
    private var spawnLock: CInt = -1

    /// How many times the gate has decided to start a core. Counted before any
    /// of the reasons a spawn can still fail (no bun, no core package), so it
    /// records the *decision*, which is the part with the interesting bug.
    private(set) var spawnAttempts = 0

    /// True while a core *this app started* is running.
    ///
    /// The app tells a core to quit only when it started it. A core the
    /// developer launched with `make run-core` outlives the app it happened to
    /// be serving: it was never ours to shut down, and taking it away on every
    /// app restart is exactly the surprise the P0 review flagged.
    var isSupervising: Bool { process?.isRunning ?? false }

    /// Give up restarting after this many crashes; past that it is a config
    /// error (a missing key, a bad model name) and a loop only hides it.
    private static let maxRestarts = 3

    /// How long a core gets to honour SIGTERM before it is killed outright.
    private static let terminationGrace = 2.0

    /// Start a core only once the socket itself says nobody is serving it.
    ///
    /// Call this *before* the bridge dials. The first look happens synchronously
    /// for that reason: if a core is already serving, we must not have a probe
    /// connection open at the same moment as the real one, because the core
    /// admits exactly one client and answers the second with `already_connected`
    /// (protocol.md §一) — which would cost the app a full reconnect backoff.
    ///
    /// `grace` is not a guess about the handshake. It only covers a core that is
    /// *mid-boot* (bun's cold start), and it is spent re-asking the socket, not
    /// waiting blindly. Erring long is free — the worst case is a slower
    /// autostart — while erring short is what buys a second paid Realtime
    /// session.
    func spawnUnlessCoreIsServing(
        // The same resolver `CoreBridge` dials through, so the path we probe and
        // the path the app connects to can never drift apart — and so a shipped
        // build ignores `AKARI_SOCKET` here too (SocketTrust.resolveSocketPath).
        socketPath: String = SocketTrust.resolveSocketPath(),
        grace: Duration = .seconds(5),
        interval: Duration = .milliseconds(200),
        isConnected: @escaping () -> Bool
    ) {
        probe?.cancel()
        probe = nil
        guard process == nil else { return }

        // The app cannot be connected yet — this runs before the bridge dials.
        guard Self.decide(probe: Self.probeSocket(at: socketPath),
                          appIsConnected: false,
                          socketPath: socketPath) else { return }

        probe = Task { @MainActor [weak self] in
            let deadline = ContinuousClock.now + grace
            var last = SocketProbe.absent
            while !Task.isCancelled {
                guard let self, self.process == nil else { return }
                last = Self.probeSocket(at: socketPath)
                guard Self.decide(probe: last,
                                  appIsConnected: isConnected(),
                                  socketPath: socketPath) else { return }
                if ContinuousClock.now >= deadline { break }
                try? await Task.sleep(for: interval)
            }
            guard !Task.isCancelled, let self, self.process == nil else { return }

            if last == .stale {
                // Identified, but deliberately not unlinked from here. Between
                // our probe and our unlink a core could bind, and we would then
                // delete a socket that is being served. `Bridge.listen` already
                // unlinks the dead inode as part of its own bind, where there is
                // no such window.
                coreLog.info("""
                    the socket file is stale (nothing is listening); \
                    the core will replace it when it binds
                    """)
            }
            guard self.claimSpawnLock(besideSocketAt: socketPath) else {
                coreLog.info("not spawning a core: another akari.app holds the spawn lock")
                return
            }
            self.wantsRunning = true
            self.spawn()
        }
    }

    // MARK: - Is anybody serving the socket?

    /// What one `connect(2)` against the core's socket path found.
    enum SocketProbe: Equatable {
        /// Somebody is listening. Not necessarily finished handshaking with us,
        /// and that is the point: the core exists, so we must not start another.
        case serving
        /// No socket file at all — nothing has bound this path.
        case absent
        /// The file is there but nothing is listening: a core died without
        /// unlinking (SIGKILL, panic).
        case stale
        /// The path cannot be spoken to at all (wrong owner, too long, not a
        /// socket). Whatever is wrong, starting a core will not fix it.
        case unusable(Int32)
    }

    /// Whether the app should start a core of its own, given what the socket
    /// said and whether the app is already talking to one.
    ///
    /// This is the whole judgement, and it is deliberately free of clocks: the
    /// previous version asked "has the handshake finished by now?", which says
    /// nothing about whether a core exists.
    nonisolated static func shouldSpawn(probe: SocketProbe, appIsConnected: Bool) -> Bool {
        if appIsConnected { return false }
        switch probe {
        case .serving, .unusable: return false
        case .absent, .stale: return true
        }
    }

    /// `shouldSpawn`, with the reason logged when the answer is no. The gate
    /// calls only this, so the rule the tests pin is the rule that runs.
    ///
    /// A `true` means "nothing objects", not "start one now": within the grace
    /// window the caller keeps asking.
    private nonisolated static func decide(
        probe: SocketProbe,
        appIsConnected: Bool,
        socketPath: String
    ) -> Bool {
        if shouldSpawn(probe: probe, appIsConnected: appIsConnected) { return true }
        let reason: String =
            if appIsConnected {
                "the app is already connected to one"
            } else {
                switch probe {
                case .serving: "a core is already serving \(socketPath)"
                case .unusable(let code): "cannot reach \(socketPath): \(String(cString: strerror(code)))"
                case .absent, .stale: "nothing objects"  // unreachable: shouldSpawn said no
                }
            }
        coreLog.info("not spawning a core: \(reason, privacy: .public)")
        return false
    }

    /// Ask the kernel, not a clock, whether a core owns `path`.
    ///
    /// Non-blocking on purpose: a listener with a full accept backlog would
    /// otherwise park the main actor inside `connect`. A full backlog still
    /// means somebody is listening, so `EAGAIN` counts as `serving`.
    ///
    /// One measured side effect, so nobody chases it as an intrusion: a live
    /// core logs one `AUDIT peer refused ... the kernel would not report the
    /// peer's identity` for each successful probe. We connect and hang up in the
    /// same breath, so by the time `peer.ts` asks the kernel for `LOCAL_PEERPID`
    /// the peer is already gone. That refusal is also what makes the probe safe:
    /// the core drops it *before* it can occupy the one client slot, so a probe
    /// can never displace, or be mistaken for, the app's real connection. Costs
    /// one log line per app launch, and only when a core is already up.
    nonisolated static func probeSocket(at path: String) -> SocketProbe {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8)
        // `sun_path` needs a trailing NUL, so the last byte stays zero.
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            return .unusable(ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .unusable(errno) }
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
        let outcome = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        // Before `close`, which is allowed to clobber errno.
        let code = errno
        close(fd)
        if outcome == 0 { return .serving }
        switch code {
        case ENOENT, ENOTDIR: return .absent
        case ECONNREFUSED: return .stale
        case EAGAIN, EINPROGRESS: return .serving
        default: return .unusable(code)
        }
    }

    // MARK: - One spawner at a time

    /// Take an exclusive advisory lock beside the socket, so two copies of the
    /// app cannot both look, both see nothing, and both start a core.
    ///
    /// `flock` rather than a pid file: the kernel drops it when the holder dies,
    /// so a crashed app never leaves a lock that blocks the next one. `O_CLOEXEC`
    /// keeps the spawned core from inheriting it — the lock belongs to the app,
    /// and it must end with the app.
    private func claimSpawnLock(besideSocketAt socketPath: String) -> Bool {
        if spawnLock >= 0 { return true }
        guard let fd = Self.claimSpawnLock(at: Self.spawnLockPath(besideSocketAt: socketPath)) else {
            return false
        }
        spawnLock = fd
        return true
    }

    nonisolated static func spawnLockPath(besideSocketAt socketPath: String) -> String {
        URL(filePath: socketPath)
            .deletingLastPathComponent()
            .appending(path: "core.spawn.lock")
            .path(percentEncoded: false)
    }

    /// The lock's file descriptor, or nil when somebody else holds it (or the
    /// directory cannot hold a lock file at all, in which case a core could not
    /// bind its socket there either).
    nonisolated static func claimSpawnLock(at path: String) -> CInt? {
        let directory = URL(filePath: path).deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            coreLog.error("cannot open the spawn lock: \(String(cString: strerror(errno)), privacy: .public)")
            return nil
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    func terminate() {
        wantsRunning = false
        probe?.cancel()
        probe = nil
        if spawnLock >= 0 {
            close(spawnLock)
            spawnLock = -1
        }
        guard let process else {
            supervisedCorePID.store(0, ordering: .relaxed)
            return
        }
        self.process = nil
        guard process.isRunning else {
            supervisedCorePID.store(0, ordering: .relaxed)
            return
        }
        // SIGTERM: index.ts installs a handler that closes the realtime session
        // and unlinks the socket. SIGKILL would leave the socket file behind.
        process.terminate()
        // Do not return while it is still up. `applicationWillTerminate` is the
        // last moment this object runs, and a core that outlives the app is not
        // merely untidy: it still holds the socket, the microphone uplink and
        // DASHSCOPE_API_KEY, with nobody driving it.
        if !Self.waitForExit(process, upTo: Self.terminationGrace) {
            coreLog.warning("akari-core ignored SIGTERM; sending SIGKILL")
            kill(process.processIdentifier, SIGKILL)
            _ = Self.waitForExit(process, upTo: 0.5)
        }
        supervisedCorePID.store(0, ordering: .relaxed)
    }

    // MARK: - Spawning

    private func spawn() {
        spawnAttempts += 1
        guard let location = Self.resolveCoreDirectory() else {
            coreLog.error("""
                cannot start akari-core: no core package to run. \
                A release build only runs the copy inside Contents/Resources/core; \
                rebuild the bundle with `make app-bundle`.
                """)
            return
        }
        guard let bun = Self.findBun() else {
            coreLog.error("""
                cannot start akari-core: no `bun` executable found. \
                Start the core yourself with `make run-core`.
                """)
            return
        }
        let entry = location.directory.appending(path: "src/index.ts")
        coreLog.info("""
            starting akari-core from \(location.origin, privacy: .public): \
            \(entry.path(percentEncoded: false), privacy: .public)
            """)

        let process = Process()
        process.executableURL = bun
        process.arguments = ["run", entry.path(percentEncoded: false)]
        process.currentDirectoryURL = location.directory
        // A GUI process has almost no PATH; give the child one so anything it
        // shells out to (`open`, `pbpaste`) resolves.
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = (environment["PATH"].map { "\($0):" } ?? "")
            + "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        // Tells the core it has a parent worth watching: it polls for the app
        // going away and exits, which is the only cover for SIGKILL — no handler
        // of ours can run in that case.
        environment["AKARI_SUPERVISED"] = "1"
        process.environment = environment
        // Inherit stdout/stderr so `swift run` shows the core's log inline; the
        // core never prints credentials.
        process.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.coreExited(finished) }
            }
        }

        Self.installExitHandlers()
        do {
            try process.run()
            self.process = process
            supervisedCorePID.store(process.processIdentifier, ordering: .relaxed)
            coreLog.info("started akari-core (pid \(process.processIdentifier))")
        } catch {
            coreLog.error("could not start akari-core: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func coreExited(_ finished: Process) {
        guard finished === process else { return }
        process = nil
        if supervisedCorePID.load(ordering: .relaxed) == finished.processIdentifier {
            supervisedCorePID.store(0, ordering: .relaxed)
        }
        guard wantsRunning else { return }
        coreLog.warning("akari-core exited with status \(finished.terminationStatus)")

        restarts += 1
        guard restarts <= Self.maxRestarts else {
            coreLog.error("akari-core died \(Self.maxRestarts) times; not restarting. Check the core's log.")
            return
        }
        let delay = Duration.seconds(min(8, 1 << restarts))
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, self.wantsRunning, self.process == nil else { return }
            self.spawn()
        }
    }

    private static func waitForExit(_ process: Process, upTo seconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while process.isRunning {
            if Date() >= deadline { return false }
            usleep(10_000)
        }
        return true
    }

    // MARK: - Reaping the core on the abnormal exit paths

    /// `terminate()` covers the orderly quit. These cover the rest: a signal
    /// from the terminal or launchd, and a crash in the app itself. SIGKILL is
    /// deliberately absent because it cannot be caught — that one is the core's
    /// own parent watchdog to handle (`AKARI_SUPERVISED`).
    private static let exitHandlersInstalled: Bool = {
        // Force the atomic's lazy initialisation here, on a normal thread: a
        // first touch from inside a signal handler would run `swift_once`, which
        // is not async-signal-safe.
        _ = supervisedCorePID.load(ordering: .relaxed)
        atexit { killSupervisedCore() }
        let fatal: [Int32] = [
            SIGHUP, SIGINT, SIGQUIT, SIGTERM,
            SIGABRT, SIGILL, SIGSEGV, SIGBUS, SIGFPE, SIGTRAP,
        ]
        for received in fatal {
            _ = signal(received) { received in
                killSupervisedCore()
                // Restore the default action and re-raise so the app still dies
                // the way it would have, crash report and exit status included.
                _ = signal(received, SIG_DFL)
                raise(received)
            }
        }
        return true
    }()

    private static func installExitHandlers() {
        _ = exitHandlersInstalled
    }

    // MARK: - What the app is allowed to execute

    struct CoreLocation {
        /// Directory holding `package.json` and `src/index.ts`.
        let directory: URL
        /// Which rule produced it. Logged, so a surprising core is traceable.
        let origin: String
    }

    /// Whether the development lookups (`AKARI_CORE_ROOT`, the checkout search,
    /// `AKARI_BUN`) are on at all. False in anything shipped.
    nonisolated static var allowsDevelopmentPaths: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// Decide which core package the app is willing to hand to `bun`.
    ///
    /// Resolution order:
    ///
    /// 1. `$AKARI_CORE_ROOT/core` — DEBUG builds only, and authoritative: if it
    ///    is set and wrong we fail rather than quietly running something else.
    /// 2. `Contents/Resources/core` inside the app bundle.
    /// 3. `<checkout>/core` — DEBUG builds only, and never from a `.app`.
    ///
    /// A release build therefore runs the bundled copy or nothing. It must never
    /// go looking, because the directories around a shipped `.app` are chosen by
    /// whoever put the app there: dropping `core/package.json` and
    /// `core/src/index.ts` next to akari.app in ~/Downloads (one unzip, no
    /// prompt, no privilege) used to be enough to have akari execute them — with
    /// akari's whole trust boundary, since the core is the socket server, sees
    /// the microphone uplink, draws the confirmation cards and holds
    /// DASHSCOPE_API_KEY.
    nonisolated static func resolveCoreDirectory(
        bundleURL: URL,
        checkoutRoot: URL?,
        environment: [String: String],
        allowsDevelopmentPaths: Bool,
        isCorePackage: (URL) -> Bool
    ) -> CoreLocation? {
        if allowsDevelopmentPaths,
           let override = environment["AKARI_CORE_ROOT"], !override.isEmpty {
            let directory = URL(filePath: override)
                .appending(path: "core", directoryHint: .isDirectory)
            return isCorePackage(directory)
                ? CoreLocation(directory: directory, origin: "AKARI_CORE_ROOT")
                : nil
        }

        let bundled = bundleURL
            .appending(path: "Contents/Resources/core", directoryHint: .isDirectory)
        if isCorePackage(bundled) {
            return CoreLocation(directory: bundled, origin: "app bundle")
        }

        // Running from a bundle means this *is* the shipped artifact, whatever
        // the compiler flags say — the copy that has one legitimate core, the
        // one inside it.
        guard allowsDevelopmentPaths, bundleURL.pathExtension != "app",
              let checkoutRoot else { return nil }
        let directory = checkoutRoot.appending(path: "core", directoryHint: .isDirectory)
        return isCorePackage(directory)
            ? CoreLocation(directory: directory, origin: "checkout")
            : nil
    }

    private static func resolveCoreDirectory() -> CoreLocation? {
        resolveCoreDirectory(
            bundleURL: Bundle.main.bundleURL,
            checkoutRoot: AppDelegate.repoRoot(),
            environment: ProcessInfo.processInfo.environment,
            allowsDevelopmentPaths: allowsDevelopmentPaths,
            isCorePackage: isCorePackage)
    }

    /// A directory only counts as the core if it carries both halves — a lone
    /// `package.json` is a much easier thing for someone else to leave lying
    /// around than a complete package.
    nonisolated static func isCorePackage(_ directory: URL) -> Bool {
        let files = FileManager.default
        return ["package.json", "src/index.ts"].allSatisfy {
            files.fileExists(atPath: directory.appending(path: $0).path(percentEncoded: false))
        }
    }

    /// `AKARI_BUN` (DEBUG only), then the usual install locations. `which` is
    /// useless here: a GUI process does not inherit the login shell's PATH.
    ///
    /// The override is DEBUG-only for the same reason the core path is. The
    /// environment of a GUI app is set by whoever launches it, so honouring
    /// `AKARI_BUN` in a shipped build turns "launch akari" into "run this
    /// arbitrary binary" for anyone who can write a launch agent or a
    /// `LSEnvironment` entry.
    nonisolated static func findBun(
        environment: [String: String],
        allowsDevelopmentPaths: Bool,
        isExecutable: (String) -> Bool
    ) -> URL? {
        if allowsDevelopmentPaths,
           let override = environment["AKARI_BUN"], !override.isEmpty {
            return isExecutable(override) ? URL(filePath: override) : nil
        }
        var candidates = [
            "/opt/homebrew/bin/bun",
            "/usr/local/bin/bun",
            "/usr/bin/bun",
        ]
        if let home = environment["HOME"] {
            candidates.insert("\(home)/.bun/bin/bun", at: 0)
        }
        return candidates.first(where: isExecutable).map { URL(filePath: $0) }
    }

    private static func findBun() -> URL? {
        findBun(
            environment: ProcessInfo.processInfo.environment,
            allowsDevelopmentPaths: allowsDevelopmentPaths,
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) })
    }
}
