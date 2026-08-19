import Dispatch
import Foundation
import Testing

@testable import AkariApp

/// Regressions around `pendingBuffers`, the per-stream count that drives
/// `isPlaying` and `onPlaybackFinished`.
///
/// The bug these pin down: `enqueuePlayback` used to read the playback generation
/// in one critical section and increment the stream's count in a *second* one,
/// with the PCM conversion and a possible `AVAudioEngine.start()` in between. A
/// `cancelPlayback` landing in that gap flushed the counts and bumped the
/// generation, then the increment re-created an entry whose completion handler
/// was discarded for having the wrong generation — a count that never came down.
/// `isPlaying` stayed true for good, and because `beginPlaybackStream` only
/// cleared the ban list, the stale count survived a reconnect: the core restarts
/// stream ids at 1, the new stream 1 started at 1 instead of 0, its last buffer
/// left the count at 1, `onPlaybackFinished` never fired, no `audio.done` went
/// out, and the avatar stayed `talking` until the next barge-in or disconnect.
///
/// `cancelPlayback` is genuinely concurrent with `enqueuePlayback`: the
/// `AVAudioEngineConfigurationChange` observers in `init` are registered with
/// `queue: nil`, so `handlePlaybackConfigurationChange` — and the
/// `cancelPlayback` it calls — runs on the notification poster's thread whenever
/// the user swaps headphones or unplugs a display mid-reply.
@Suite("AudioBridge playback queue accounting")
struct AudioBridgePlaybackAccountingTests {
    private static let uplink = AudioFormat(sampleRate: 16000, channels: 1, frameMillis: 20)
    private static let downlink = AudioFormat(sampleRate: 24000, channels: 1, frameMillis: 20)

    /// 20ms of silence at the downlink rate: 480 frames * 2 bytes.
    private static let chunk = Data(count: 480 * 2)

    /// Thread-safe flag box: the completion handler fires on `AVAudioPlayerNode`'s
    /// own queue, not on the test's thread.
    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: T
        init(_ value: T) { stored = value }
        var value: T {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    /// A configured bridge, or nil when this machine has no usable output device
    /// (`swift test` on a headless runner) — the engine refusing to start is not
    /// the thing under test.
    private static func usableBridge() throws -> AudioBridge? {
        let bridge = AudioBridge()
        try bridge.configure(uplink: uplink, downlink: downlink)
        let failure = Box<(any Error)?>(nil)
        bridge.onError = { failure.value = $0 }
        bridge.enqueuePlayback(chunk, streamID: 9_999)
        let ok = bridge.isPlaying && failure.value == nil
        bridge.cancelPlayback(streamID: nil)
        bridge.onError = nil
        guard ok else { return nil }
        return bridge
    }

    private static func spin(nanoseconds: UInt64) {
        guard nanoseconds > 0 else { return }
        let deadline = DispatchTime.now().uptimeNanoseconds &+ nanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {}
    }

    /// Poll `predicate` until it holds or `timeout` elapses.
    private static func wait(upTo timeout: TimeInterval, for predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            usleep(2_000)
        }
        return predicate()
    }

    /// A cancel that lands inside `enqueuePlayback`'s read-then-count window must
    /// not leave a count behind. Whichever side wins, the queue has to drain.
    @Test("a cancel racing an enqueue never strands a pending count")
    func racingCancelStrandsNothing() throws {
        guard let bridge = try Self.usableBridge() else {
            Issue.record("no usable audio output on this machine; playback path not exercised")
            return
        }
        defer { bridge.teardown() }

        let worker = DispatchQueue(label: "akari.test.enqueue")

        for round in 1...150 {
            // The core reopened stream 1: lift any ban the previous round left.
            bridge.beginPlaybackStream(1)

            let started = DispatchSemaphore(value: 0)
            let finishedEnqueue = DispatchSemaphore(value: 0)
            worker.async {
                started.signal()
                bridge.enqueuePlayback(Self.chunk, streamID: 1)
                finishedEnqueue.signal()
            }
            started.wait()
            // Land somewhere inside the conversion + engine-start window.
            Self.spin(nanoseconds: UInt64.random(in: 0...60_000))
            bridge.cancelPlayback(streamID: nil)
            finishedEnqueue.wait()

            let drained = Self.wait(upTo: 1.0) { bridge.pendingPlaybackBuffers(for: 1) == 0 }
            guard drained else {
                Issue.record("""
                    round \(round): stream 1 still shows \
                    \(bridge.pendingPlaybackBuffers(for: 1)) pending buffer(s) after the \
                    racing cancel; nothing will ever decrement it
                    """)
                return
            }
        }

        // And the stream the core opens next — id 1 again, after a reconnect —
        // still reaches `onPlaybackFinished`, which is what becomes `audio.done`.
        let finished = Box<[UInt32]>([])
        bridge.onPlaybackFinished = { finished.value.append($0) }
        bridge.beginPlaybackStream(1)
        bridge.enqueuePlayback(Self.chunk, streamID: 1)
        #expect(Self.wait(upTo: 2.0) { finished.value.contains(1) },
                "the reconnected stream 1 never reported finished")
    }

    /// `audio.begin` for an id that already has a queue recorded means the core
    /// reopened it; the old life's count must not be inherited.
    @Test("audio.begin drops the queue the previous life of that id left behind")
    func beginResetsTheQueue() throws {
        guard let bridge = try Self.usableBridge() else {
            Issue.record("no usable audio output on this machine; playback path not exercised")
            return
        }
        defer { bridge.teardown() }

        bridge.beginPlaybackStream(1)
        // Deep enough that it cannot drain while the test runs: 40 * 20ms.
        for _ in 0..<40 { bridge.enqueuePlayback(Self.chunk, streamID: 1) }
        #expect(bridge.pendingPlaybackBuffers(for: 1) > 0, "nothing was queued to begin with")

        // Reconnect: the core restarts numbering at 1 and announces it again.
        bridge.beginPlaybackStream(1)
        #expect(bridge.pendingPlaybackBuffers(for: 1) == 0,
                "the previous life's count survived audio.begin and will never reach zero")

        let finished = Box<[UInt32]>([])
        bridge.onPlaybackFinished = { finished.value.append($0) }
        bridge.enqueuePlayback(Self.chunk, streamID: 1)
        #expect(Self.wait(upTo: 3.0) { finished.value.contains(1) },
                "the reopened stream 1 never reported finished")
    }

    /// Completions of buffers scheduled before a reset must not decrement the run
    /// that came after it — otherwise a reopened stream reports finished while its
    /// own buffers are still queued.
    @Test("a stale completion cannot drain the run that replaced it")
    func staleCompletionDoesNotDrainTheNewRun() throws {
        guard let bridge = try Self.usableBridge() else {
            Issue.record("no usable audio output on this machine; playback path not exercised")
            return
        }
        defer { bridge.teardown() }

        bridge.beginPlaybackStream(1)
        for _ in 0..<20 { bridge.enqueuePlayback(Self.chunk, streamID: 1) }

        // Reopen the id, then queue a run of two.
        bridge.beginPlaybackStream(1)
        let finished = Box<[UInt32]>([])
        bridge.onPlaybackFinished = { finished.value.append($0) }
        bridge.enqueuePlayback(Self.chunk, streamID: 1)
        bridge.enqueuePlayback(Self.chunk, streamID: 1)
        #expect(bridge.pendingPlaybackBuffers(for: 1) == 2)

        #expect(Self.wait(upTo: 3.0) { finished.value.contains(1) },
                "the reopened stream 1 never reported finished")
        // Exactly once: the 20 stale completions must be inert, not extra drains.
        #expect(finished.value == [1], "finished fired \(finished.value.count) times, expected once")
    }
}
