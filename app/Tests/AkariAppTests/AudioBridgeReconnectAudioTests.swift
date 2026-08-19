import Foundation
import Testing

@testable import AkariApp

/// Adversarial follow-up to `AudioBridgeCancellationTests`.
///
/// Those tests only assert on `isPlaybackStreamCancelled`, the flag. This one
/// pushes real PCM through `enqueuePlayback` and asserts on the *effect*, which
/// is the thing the P0 was actually about: after a barge-in cancels stream 1 and
/// the app reconnects, the core restarts numbering at 1 and the first frames of
/// the new session must reach the player instead of being swallowed.
@Suite("AudioBridge reconnect actually plays again")
struct AudioBridgeReconnectAudioTests {
    private static let uplink = AudioFormat(sampleRate: 16000, channels: 1, frameMillis: 20)
    private static let downlink = AudioFormat(sampleRate: 24000, channels: 1, frameMillis: 20)

    /// 20ms of silence at the downlink rate: 480 frames * 2 bytes.
    private static let chunk = Data(count: 480 * 2)

    /// True when this machine has a usable output device. `swift test` on a
    /// headless runner has none, and an engine that will not start is not the
    /// thing under test — the test says so rather than failing for the wrong reason.
    private static func engineUsable(_ bridge: AudioBridge) -> Bool {
        var failure: (any Error)?
        bridge.onError = { failure = $0 }
        bridge.enqueuePlayback(chunk, streamID: 9_999)
        let ok = bridge.isPlaying && failure == nil
        bridge.cancelPlayback(streamID: nil)
        bridge.onError = nil
        return ok
    }

    @Test("a stream banned by a barge-in really does play again after the handshake")
    func bannedStreamPlaysAfterReconnect() throws {
        let bridge = AudioBridge()
        try bridge.configure(uplink: Self.uplink, downlink: Self.downlink)
        guard Self.engineUsable(bridge) else {
            Issue.record("no usable audio output on this machine; playback path not exercised")
            return
        }

        // Session 1: stream 1 is open and playing, then the user barges in.
        bridge.beginPlaybackStream(1)
        bridge.enqueuePlayback(Self.chunk, streamID: 1)
        bridge.cancelPlayback(streamID: 1)
        #expect(bridge.isPlaybackStreamCancelled(1))

        // Late frames of the dead stream are still dropped — that is the point
        // of the list, and it must keep working.
        bridge.enqueuePlayback(Self.chunk, streamID: 1)
        #expect(!bridge.isPlaying, "a late frame of the cancelled stream was queued anyway")

        // Reconnect, exactly as AppDelegate does it: drop everything in flight
        // (protocol.md §六), then apply the formats from the new `core.ready`.
        bridge.cancelPlayback(streamID: nil)
        try bridge.configure(uplink: Self.uplink, downlink: Self.downlink)

        // The core restarts at streamId 1 and sends `audio.begin` before any PCM.
        bridge.beginPlaybackStream(1)
        bridge.enqueuePlayback(Self.chunk, streamID: 1)
        #expect(bridge.isPlaying, "the first frame of the new session was dropped by a stale ban")

        bridge.teardown()
    }

    /// The `configure` exit is not the only one that has to work: a reconnect
    /// where the negotiated formats are unavailable never calls `configure`, so
    /// `audio.begin` alone has to lift the ban.
    @Test("audio.begin alone is enough to lift a stale ban")
    func beginAloneLiftsTheBan() throws {
        let bridge = AudioBridge()
        try bridge.configure(uplink: Self.uplink, downlink: Self.downlink)
        guard Self.engineUsable(bridge) else {
            Issue.record("no usable audio output on this machine; playback path not exercised")
            return
        }

        bridge.beginPlaybackStream(2)
        bridge.enqueuePlayback(Self.chunk, streamID: 2)
        bridge.cancelPlayback(streamID: nil)
        #expect(bridge.isPlaybackStreamCancelled(2))

        // No configure() this time — just the next session's audio.begin.
        bridge.beginPlaybackStream(2)
        bridge.enqueuePlayback(Self.chunk, streamID: 2)
        #expect(bridge.isPlaying, "audio.begin did not lift the ban on its own")

        bridge.teardown()
    }

    /// The ban list is trimmed to 32 entries. A trim must drop the *oldest*
    /// entries; dropping the newest would un-ban a stream that is still being
    /// cancelled and let its late frames through.
    @Test("trimming the ban list keeps the newest bans")
    func trimKeepsNewestBans() throws {
        let bridge = AudioBridge()
        try bridge.configure(uplink: Self.uplink, downlink: Self.downlink)
        for id in UInt32(1)...UInt32(40) { bridge.cancelPlayback(streamID: id) }
        #expect(!bridge.isPlaybackStreamCancelled(1), "oldest ban should have been trimmed")
        #expect(bridge.isPlaybackStreamCancelled(40), "newest ban was trimmed instead")
        #expect(bridge.isPlaybackStreamCancelled(9))
    }
}
