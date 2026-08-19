import Foundation

/// Whether the socket the app is about to dial is one it should trust, and
/// which socket path it is allowed to dial in the first place.
///
/// ## Why this exists
///
/// The core verifies the app: `core/src/peer.ts` reads the peer's uid and
/// executable path out of the kernel at `connect(2)` time and refuses anything
/// that is not an allow-listed akari.app. That check was only ever half of a
/// trust boundary. The app did no check at all, so anything that got a socket
/// under `AKARI_SOCKET` — or that unlinked the real socket and re-bound the
/// path — was handed the full session: the microphone uplink, and the answers
/// to `clipboard.read.request`, which is the app-side read that exists
/// precisely because it can see the `org.nspasteboard.ConcealedType` marker a
/// password manager sets. A one-directional check does not protect that; it
/// just moves the read to a process that will hand it to whoever asked.
///
/// This file is the mirror of the core's `assertPrivate`: before connecting,
/// confirm the socket and its directory are owned by this user and are 0600 /
/// 0700, exactly the invariant the core refuses to start without.
///
/// ## What this actually buys — read this before trusting it
///
/// The same honesty the core's `peer.ts` applies to its direction applies here:
///
///   - It stops a socket that belongs to **another uid**, and a socket sitting
///     in a directory that other accounts can write to (`/tmp`, a `umask 000`
///     directory, an unlocked shared folder). That is the shape of the reported
///     attack, and it is the shape a stray dev script has.
///   - It does **not** stop a process already running as *you*. Your own uid
///     can unlink `~/Library/Application Support/akari/core.sock` and bind its
///     own socket there with the same 0600 in the same 0700 directory, and
///     nothing in a `stat` can tell the two apart.
///
/// Only the peer's code signature can, and closing this direction is strictly
/// harder than closing the core's: see the note on `LOCAL_PEERPID` below.
enum SocketTrust {
    enum Verdict: Equatable {
        /// Owned by this user, 0600 in a 0700 directory.
        case trusted
        /// Nothing is bound there yet. The normal state while the core is
        /// starting, so callers should retry rather than complain.
        case notListening(String)
        /// Something is there and it fails the check. Never connect.
        case refused(String)
    }

    struct FileFacts: Equatable {
        enum Kind: Equatable { case socket, directory, symlink, other }

        var uid: uid_t
        /// Permission bits only (`st_mode & 0o777`).
        var mode: mode_t
        var kind: Kind
    }

    /// `lstat`, deliberately not `stat`: a symlink as the final component is a
    /// redirect somewhere else, and following it would check the target's modes
    /// while connecting through the link.
    ///
    /// Ancestors above the socket's own directory are not walked, which matches
    /// what the core checks. A user whose home directory is group-writable has a
    /// larger problem than this socket.
    static func facts(_ path: String) -> FileFacts? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        let kind: FileFacts.Kind =
            switch info.st_mode & S_IFMT {
            case S_IFSOCK: .socket
            case S_IFDIR: .directory
            case S_IFLNK: .symlink
            default: .other
            }
        return FileFacts(uid: info.st_uid, mode: info.st_mode & 0o777, kind: kind)
    }

    static func verify(socketPath: String) -> Verdict {
        verify(socketPath: socketPath, selfUID: getuid(), facts: facts)
    }

    /// Injectable form. `facts` returns nil for "does not exist".
    static func verify(
        socketPath: String,
        selfUID: uid_t,
        facts: (String) -> FileFacts?
    ) -> Verdict {
        let directoryPath = (socketPath as NSString).deletingLastPathComponent

        guard let directory = facts(directoryPath) else {
            return .notListening("\(directoryPath) does not exist")
        }
        // A symlink here is not "the core moved its socket": the core creates
        // this directory itself with mkdir, so a link in its place was put there
        // by something else.
        guard directory.kind == .directory else {
            return .refused("\(directoryPath) is not a directory")
        }
        guard directory.uid == selfUID else {
            return .refused("\(directoryPath) is owned by uid \(directory.uid), not \(selfUID)")
        }
        guard directory.mode == 0o700 else {
            return .refused("""
                \(directoryPath) is mode 0\(String(directory.mode, radix: 8)), expected 0700 — \
                anything that can write here can replace the socket
                """)
        }

        guard let socket = facts(socketPath) else {
            return .notListening("\(socketPath) does not exist")
        }
        guard socket.kind == .socket else {
            return .refused("\(socketPath) is not a unix socket")
        }
        guard socket.uid == selfUID else {
            return .refused("\(socketPath) is owned by uid \(socket.uid), not \(selfUID)")
        }
        guard socket.mode == 0o600 else {
            return .refused("""
                \(socketPath) is mode 0\(String(socket.mode, radix: 8)), expected 0600 — \
                the core forces 0600 and refuses to start otherwise, so this is not our core
                """)
        }
        return .trusted
    }

    // MARK: - Which socket the app is allowed to dial

    /// `<Application Support>/akari/core.sock`. Mirrors `defaultSocketPath()` in
    /// `core/src/bridge.ts`; `ProtocolConstants.defaultSocketPath` is the same
    /// path, but it honours `AKARI_SOCKET` unconditionally and must not be used
    /// to open a connection.
    static var builtInSocketPath: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appending(path: "akari/core.sock").path(percentEncoded: false)
    }

    /// `AKARI_SOCKET` moves the socket — in DEBUG builds only.
    ///
    /// This is the same rule `AKARI_CORE_ROOT` and `AKARI_BUN` already follow,
    /// for the same reason: a GUI app's environment is set by whoever launches
    /// it, so a launch agent or an `LSEnvironment` entry is enough to point a
    /// shipped build at an attacker's socket — which is exactly how the reported
    /// attack was staged.
    ///
    /// A second "I know what I am doing" variable was considered and rejected:
    /// anyone who can set `AKARI_SOCKET` on this process can set that one in the
    /// same breath, so it would buy nothing against the actual threat.
    static func resolveSocketPath(
        environment: [String: String],
        allowsDevelopmentPaths: Bool
    ) -> String {
        if allowsDevelopmentPaths,
           let override = environment["AKARI_SOCKET"], !override.isEmpty {
            return override
        }
        return builtInSocketPath
    }

    static func resolveSocketPath() -> String {
        resolveSocketPath(environment: ProcessInfo.processInfo.environment,
                          allowsDevelopmentPaths: CoreProcess.allowsDevelopmentPaths)
    }
}
