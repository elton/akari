import Testing

@testable import AkariApp

/// Regressions around the playback cancellation list.
///
/// The bug these pin down: the list used to be append-only (trimmed at 32 entries
/// and never otherwise emptied), while the core resets `nextStreamId` to 1 on every
/// `app.hello`. A barge-in that cancelled stream 3, followed by a reconnect, banned
/// the third stream of the new session before a single frame of it was played — no
/// audio, and no `audio.done` either, so the avatar never left `talking`.
@Suite("AudioBridge cancellation lifecycle")
struct AudioBridgeCancellationTests {
    private static let uplink = AudioFormat(sampleRate: 16000, channels: 1, frameMillis: 20)
    private static let downlink = AudioFormat(sampleRate: 24000, channels: 1, frameMillis: 20)

    private func configuredBridge() throws -> AudioBridge {
        let bridge = AudioBridge()
        try bridge.configure(uplink: Self.uplink, downlink: Self.downlink)
        return bridge
    }

    @Test("cancelPlayback bans the stream it was given")
    func cancelBansTheStream() throws {
        let bridge = try configuredBridge()
        bridge.cancelPlayback(streamID: 3)
        #expect(bridge.isPlaybackStreamCancelled(3))
        #expect(!bridge.isPlaybackStreamCancelled(4))
    }

    @Test("a new handshake clears the ban a barge-in left behind")
    func reconnectClearsTheBan() throws {
        let bridge = try configuredBridge()
        bridge.cancelPlayback(streamID: 3)
        #expect(bridge.isPlaybackStreamCancelled(3))

        // What the app does on reconnect: drop everything in flight (protocol.md
        // §六), then re-apply the formats from the new `core.ready`.
        bridge.cancelPlayback(streamID: nil)
        try bridge.configure(uplink: Self.uplink, downlink: Self.downlink)

        // The core restarts at streamId 1, so ids 1..3 must be playable again.
        #expect(!bridge.isPlaybackStreamCancelled(3))
        #expect(!bridge.isPlaybackStreamCancelled(1))
    }

    @Test("audio.begin lifts the ban on that id and only that id")
    func beginLiftsOneBan() throws {
        let bridge = try configuredBridge()
        bridge.cancelPlayback(streamID: 3)
        bridge.cancelPlayback(streamID: 4)

        bridge.beginPlaybackStream(3)

        #expect(!bridge.isPlaybackStreamCancelled(3))
        #expect(bridge.isPlaybackStreamCancelled(4))
    }

    @Test("cancelling every stream then reopening one un-bans it")
    func cancelAllThenBegin() throws {
        let bridge = try configuredBridge()
        // A whole-session cancel with nothing queued has nothing to ban; the case
        // that matters is a targeted ban followed by the id coming back.
        bridge.cancelPlayback(streamID: 7)
        bridge.cancelPlayback(streamID: nil)
        #expect(bridge.isPlaybackStreamCancelled(7))

        bridge.beginPlaybackStream(7)
        #expect(!bridge.isPlaybackStreamCancelled(7))
    }
}
