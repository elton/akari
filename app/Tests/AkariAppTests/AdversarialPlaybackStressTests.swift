import Dispatch
import Foundation
import Testing

@testable import AkariApp

/// Independent (integration-agent) stress on the playback ledger. Harsher than
/// the fix author's own test: several producers, cancels and stream reopens
/// interleaved from other threads, and an assertion on the ledger itself rather
/// than on `isPlaying`.
@Suite("adversarial playback ledger stress")
struct AdversarialPlaybackStressTests {
    private static let uplink = AudioFormat(sampleRate: 16000, channels: 1, frameMillis: 20)
    private static let downlink = AudioFormat(sampleRate: 24000, channels: 1, frameMillis: 20)
    private static let chunk = Data(count: 480 * 2)

    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: T
        init(_ value: T) { stored = value }
        var value: T {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

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

    private static func drain(_ bridge: AudioBridge, within seconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if !bridge.isPlaying { return true }
            usleep(2_000)
        }
        return !bridge.isPlaying
    }

    @Test("four producers racing cancels and reopens leave no orphan count")
    func multiProducerRace() throws {
        guard let bridge = try Self.usableBridge() else { return }
        defer { bridge.teardown() }

        for round in 0..<10 {
            let group = DispatchGroup()
            for producer in 0..<4 {
                DispatchQueue.global().async(group: group) {
                    for _ in 0..<12 {
                        bridge.enqueuePlayback(Self.chunk, streamID: UInt32(producer + 1))
                    }
                }
            }
            // Two disruptions from other threads, at random points in the flood.
            DispatchQueue.global().async(group: group) {
                usleep(useconds_t(UInt32.random(in: 0...400)))
                bridge.cancelPlayback(streamID: nil)
            }
            DispatchQueue.global().async(group: group) {
                usleep(useconds_t(UInt32.random(in: 0...400)))
                bridge.beginPlaybackStream(2)
            }
            group.wait()

            // Deliberately NO trailing cancel: a flush would wipe the very
            // orphan this is looking for. The ledger has to come down on its
            // own, from the completion handlers.
            #expect(Self.drain(bridge, within: 5), "round \(round): the queue never drained")
            for id in UInt32(1)...UInt32(4) {
                #expect(bridge.pendingPlaybackBuffers(for: id) == 0,
                        "round \(round): stream \(id) kept \(bridge.pendingPlaybackBuffers(for: id)) orphan buffer(s)")
            }
            // Clean slate for the next round, now that the assertion is done.
            bridge.cancelPlayback(streamID: nil)
            for id in UInt32(1)...UInt32(4) { bridge.beginPlaybackStream(id) }
        }

        // The reconnect that used to inherit the orphan: stream ids restart at 1
        // and the very first one has to be able to report completion.
        let finished = Box<UInt32?>(nil)
        bridge.onPlaybackFinished = { finished.value = $0 }
        bridge.beginPlaybackStream(1)
        bridge.enqueuePlayback(Self.chunk, streamID: 1)
        let deadline = Date().addingTimeInterval(5)
        while finished.value == nil && Date() < deadline { usleep(5_000) }
        #expect(finished.value == 1, "onPlaybackFinished never fired for the reconnected stream 1")
    }
}
