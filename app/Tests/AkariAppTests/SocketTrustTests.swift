import Foundation
import Testing

@testable import AkariApp

/// The policy half: `SocketTrust.verify` against injected `stat` results.
/// `FakeCoreRejectedTests` is the adversarial half — a real socket, a real
/// `lstat`, and a real `CoreBridge` dialing it.
@Suite("socket trust policy")
struct SocketTrustPolicyTests {
    private static let me: uid_t = 501
    private static let socketPath = "/Users/me/Library/Application Support/akari/core.sock"
    private static let directoryPath = "/Users/me/Library/Application Support/akari"

    /// A tree that passes, so each test can change exactly one thing.
    private static func tree(
        directory: SocketTrust.FileFacts = .init(uid: me, mode: 0o700, kind: .directory),
        socket: SocketTrust.FileFacts? = .init(uid: me, mode: 0o600, kind: .socket)
    ) -> (String) -> SocketTrust.FileFacts? {
        { path in
            switch path {
            case directoryPath: directory
            case socketPath: socket
            default: nil
            }
        }
    }

    private static func verdict(
        directory: SocketTrust.FileFacts = .init(uid: me, mode: 0o700, kind: .directory),
        socket: SocketTrust.FileFacts? = .init(uid: me, mode: 0o600, kind: .socket)
    ) -> SocketTrust.Verdict {
        SocketTrust.verify(socketPath: socketPath,
                           selfUID: me,
                           facts: tree(directory: directory, socket: socket))
    }

    @Test("0600 socket in a 0700 directory, both ours")
    func accepted() {
        #expect(Self.verdict() == .trusted)
    }

    @Test("a socket owned by another user is refused")
    func foreignSocket() {
        let verdict = Self.verdict(socket: .init(uid: 502, mode: 0o600, kind: .socket))
        #expect(verdict.isRefused)
    }

    @Test("a group- or world-readable socket is refused")
    func looseSocketMode() {
        #expect(Self.verdict(socket: .init(uid: Self.me, mode: 0o666, kind: .socket)).isRefused)
        #expect(Self.verdict(socket: .init(uid: Self.me, mode: 0o660, kind: .socket)).isRefused)
    }

    @Test("a directory anything can write to is refused, however tight the socket is")
    func looseDirectory() {
        // The exact hole: 0600 on the inode means nothing when the directory
        // lets anyone unlink it and bind their own.
        #expect(Self.verdict(directory: .init(uid: Self.me, mode: 0o777, kind: .directory)).isRefused)
        #expect(Self.verdict(directory: .init(uid: Self.me, mode: 0o755, kind: .directory)).isRefused)
    }

    @Test("a directory owned by another user is refused")
    func foreignDirectory() {
        #expect(Self.verdict(directory: .init(uid: 0, mode: 0o700, kind: .directory)).isRefused)
    }

    @Test("a symlink standing in for the socket or its directory is refused")
    func symlinks() {
        #expect(Self.verdict(socket: .init(uid: Self.me, mode: 0o600, kind: .symlink)).isRefused)
        #expect(Self.verdict(directory: .init(uid: Self.me, mode: 0o700, kind: .symlink)).isRefused)
    }

    @Test("a regular file where the socket should be is refused, not dialed")
    func regularFile() {
        #expect(Self.verdict(socket: .init(uid: Self.me, mode: 0o600, kind: .other)).isRefused)
    }

    @Test("a missing socket is 'not listening', not a refusal — the core may still be starting")
    func missingSocket() {
        guard case .notListening = Self.verdict(socket: nil) else {
            Issue.record("a missing socket must not be reported as an attack")
            return
        }
    }

    @Test("a missing directory is 'not listening' too — first run has not created it yet")
    func missingDirectory() {
        let verdict = SocketTrust.verify(socketPath: Self.socketPath,
                                         selfUID: Self.me,
                                         facts: { _ in nil })
        guard case .notListening = verdict else {
            Issue.record("a missing directory must not be reported as an attack")
            return
        }
    }
}

@Suite("AKARI_SOCKET override")
struct SocketPathResolutionTests {
    private static let planted = "/tmp/attacker/core.sock"

    @Test("a shipped build ignores AKARI_SOCKET")
    func releaseIgnoresOverride() {
        let resolved = SocketTrust.resolveSocketPath(
            environment: ["AKARI_SOCKET": Self.planted],
            allowsDevelopmentPaths: false)
        #expect(resolved == SocketTrust.builtInSocketPath)
    }

    @Test("a DEBUG build honours it, because `make run` needs a scratch socket")
    func debugHonoursOverride() {
        let resolved = SocketTrust.resolveSocketPath(
            environment: ["AKARI_SOCKET": Self.planted],
            allowsDevelopmentPaths: true)
        #expect(resolved == Self.planted)
    }

    @Test("an empty value is not an override")
    func emptyOverride() {
        let resolved = SocketTrust.resolveSocketPath(
            environment: ["AKARI_SOCKET": ""],
            allowsDevelopmentPaths: true)
        #expect(resolved == SocketTrust.builtInSocketPath)
    }
}

extension SocketTrust.Verdict {
    var isRefused: Bool {
        if case .refused = self { return true }
        return false
    }
}
