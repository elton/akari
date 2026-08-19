import Foundation
import Network
import os

/// Unix domain socket client to akari-core. The app is always the client; the
/// core owns and listens on the socket.
///
/// Local HTTP ports are off the table: re-signed apps drop off the Local Network
/// list on macOS Tahoe 26.3.x and can no longer connect (spec.md §3.1).
///
/// Trust: every connection attempt is gated on `SocketTrust.verify`, which is
/// this side's half of the check the core makes on its peer. What this file
/// deliberately does *not* do is read `LOCAL_PEERPID` off the connected socket
/// the way `core/src/darwin.ts` does, for two reasons. `NWConnection` exposes no
/// file descriptor, so it would mean hand-rolling the socket, the write
/// backpressure and the incremental reader that Network.framework provides — on
/// the path that carries realtime audio. And the answer would be worth little:
/// the core is a *script*, so the peer's executable is `bun`, which lives in
/// user-writable prefixes (`~/.bun/bin`, `/opt/homebrew/bin`) and which anyone
/// can run against any file. A path check on the core proves far less than the
/// same check on the app, whose binary is inside a real bundle. The check that
/// would settle either direction is the code-signature tier, and that waits on a
/// Team ID (decisions.md 遗留).
///
/// Threading contract:
/// - `onControl`, `onAudio` and `onStateChange` fire on the main actor, in the
///   exact order the frames arrived on the wire. Ordering is load-bearing:
///   `audio.begin` has to reach the app before the first PCM frame of that
///   stream, so both kinds of frame take the same path to the main queue.
/// - `send(_:)` and `sendAudio(_:)` are `nonisolated`. AudioBridge hands over
///   captured chunks on a realtime audio thread; hopping to the main actor there
///   would mean an allocation and a context switch every 20ms. Frames keep
///   global FIFO order no matter which thread enqueued them.
/// - JSON never touches the audio path: audio frames are pure binary
///   (protocol.md §四), and control JSON is decoded on the bridge queue, not on
///   the main thread.
///
/// What this class deliberately does NOT do: decide avatar state, drop late
/// frames of a cancelled stream, or reorder by `sequence`. Those are core-side
/// or AudioBridge-side concerns (protocol.md §3.4, §四).
@MainActor
final class CoreBridge {
    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        /// Handshake done: `app.hello` sent and `core.ready` received.
        case ready
    }

    enum BridgeError: Error {
        /// No socket is open right now. Audio is dropped silently in this state;
        /// control messages throw so the caller can decide.
        case notConnected
        /// The frame would break the 4 MiB ceiling, so it is never put on the
        /// wire — the core would answer that with a fatal `frame_too_large`.
        case frameTooLarge
    }

    private(set) var state: ConnectionState = .disconnected

    /// Formats from `core.ready`, valid while `state == .ready`.
    private(set) var negotiatedFormats: (uplink: AudioFormat, downlink: AudioFormat)?

    /// Every control message except `ping`/`pong`, which are answered and
    /// counted here — they carry no application semantics.
    var onControl: ((ControlMessage) -> Void)?
    var onAudio: ((AudioFrame) -> Void)?
    /// Fires on every transition. On `.disconnected` the app owes protocol.md §六
    /// four things: stop capture, drop queued PCM, avatar to `idle`, menu bar to
    /// "未连接". None of them belong in this file.
    var onStateChange: ((ConnectionState) -> Void)?

    // MARK: - Internals

    private let socketPath: String
    private let log = Logger(subsystem: "me.eltonzheng.akari", category: "core-bridge")
    private let queue = DispatchQueue(label: "me.akari.core-bridge", qos: .userInitiated)

    private var channel: CoreBridgeChannel?
    /// Same object as `channel`, reachable from any thread so the nonisolated
    /// send paths do not have to touch main-actor state.
    private let liveChannel = CoreBridgeLockedBox<CoreBridgeChannel?>(nil)

    private var wantsConnection = false
    private var attempt = 0
    private var readySince: ContinuousClock.Instant?
    private var reconnectTask: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?
    private var missedPongs = 0
    /// Last `SocketTrust` refusal that was logged, so the reconnect loop does not
    /// repeat it every few seconds.
    private var lastRefusal: String?

    /// protocol.md §3.6: ping every 10s, three unanswered pings means dead.
    private static let pingInterval = Duration.seconds(10)
    private static let maxMissedPongs = 3
    /// protocol.md §六 backoff: 250ms, doubling, 5s ceiling, ±20% jitter.
    private static let backoffFloor = 0.25
    private static let backoffCeiling = 5.0
    /// How long a session has to hold up before the backoff is considered
    /// recovered. Resetting on `core.ready` alone is not enough: a core that
    /// dies right after the handshake would then be retried every 250ms
    /// forever, which is exactly the case the backoff exists for.
    private static let stableSession = Duration.seconds(5)

    /// The default deliberately does not go through
    /// `ProtocolConstants.defaultSocketPath`: that one honours `AKARI_SOCKET` in
    /// every build, and an environment variable is not something a shipped app
    /// may take a socket path from (SocketTrust.resolveSocketPath).
    init(socketPath: String = SocketTrust.resolveSocketPath()) {
        self.socketPath = socketPath
    }

    // MARK: - Lifecycle

    /// Connect and keep reconnecting with backoff until `disconnect()` is called.
    /// Backoff: 250ms, doubling to a 5s ceiling, ±20% jitter.
    func connect() {
        guard !wantsConnection else { return }
        wantsConnection = true
        attempt = 0
        openChannel()
    }

    /// Stop reconnecting and close.
    func disconnect() {
        wantsConnection = false
        reconnectTask?.cancel()
        reconnectTask = nil
        // Flush first: a menu-bar quit sends `app.quit` immediately before this.
        let closing = channel
        closing?.closeAfterSend("disconnect() called")
        // `close` reports back asynchronously; make the state visible right away
        // so callers that immediately re-read `state` are not lied to.
        teardown(closing, reason: "disconnect() called", reconnect: false)
    }

    private func openChannel() {
        guard wantsConnection, channel == nil else { return }
        guard checkSocketBeforeDialing() else {
            scheduleReconnect()
            return
        }

        let ch = CoreBridgeChannel(socketPath: socketPath, queue: queue, log: log)
        // Every callback is tagged with the channel it came from. They arrive on
        // the main queue one hop later, by which time `disconnect()` +
        // `connect()` may already have put a different channel in place; without
        // the tag a stale close would tear down the live connection.
        ch.onOpen = { [weak self, weak ch] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.channelOpened(ch) } }
        }
        ch.onFrames = { [weak self, weak ch] frames in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.deliver(frames, from: ch) } }
        }
        ch.onClose = { [weak self, weak ch] reason in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.teardown(ch, reason: reason, reconnect: true) }
            }
        }

        channel = ch
        liveChannel.set(ch)
        setState(.connecting)
        ch.start()
    }

    /// Refuse to dial anything that is not a socket this user privately owns.
    ///
    /// The core has verified its peer since the last hardening pass; this is the
    /// other direction, and without it the check was one-way: whoever owned the
    /// socket path owned the session — the microphone uplink and the answer to
    /// `clipboard.read.request`, which is the whole reason that read lives on
    /// this side (decisions.md, §三). See `SocketTrust` for what a `stat` does
    /// and does not prove.
    ///
    /// Returns false when the caller should back off and try again.
    private func checkSocketBeforeDialing() -> Bool {
        switch SocketTrust.verify(socketPath: socketPath) {
        case .trusted:
            lastRefusal = nil
            return true
        case .notListening(let reason):
            // The core is usually just not up yet; the backoff already covers it.
            log.debug("no core socket yet: \(reason, privacy: .public)")
            return false
        case .refused(let reason):
            // The backoff retries every few seconds and the core may be
            // restarting, so log a given reason once instead of filling the log
            // with the same line.
            if lastRefusal != reason {
                lastRefusal = reason
                log.error("refusing to connect to the core socket: \(reason, privacy: .public)")
            }
            return false
        }
    }

    /// Socket is up. `app.hello` must be the first frame on the wire
    /// (protocol.md §3.1); the handshake only completes when `core.ready` lands.
    private func channelOpened(_ source: CoreBridgeChannel?) {
        guard isCurrent(source) else { return }
        let identity = Self.appIdentity()
        let hello = ControlMessage(body: .appHello(AppHelloPayload(
            protocolVersion: ProtocolConstants.version,
            appVersion: identity.version,
            appBuild: identity.build)))
        do {
            try send(hello)
        } catch {
            channel?.close("could not send app.hello")
        }
    }

    /// `source` is the channel whose close is being reported. A close from an
    /// already-replaced channel is ignored.
    private func teardown(_ source: CoreBridgeChannel?, reason: String, reconnect: Bool) {
        guard isCurrent(source) else { return }
        keepaliveTask?.cancel()
        keepaliveTask = nil
        missedPongs = 0

        if let readySince, readySince.duration(to: .now) >= Self.stableSession {
            attempt = 0
        }
        readySince = nil

        let hadChannel = channel != nil
        channel = nil
        liveChannel.set(nil)
        negotiatedFormats = nil

        if hadChannel {
            log.info("core bridge down: \(reason, privacy: .public)")
        }
        setState(.disconnected)

        if reconnect, wantsConnection {
            scheduleReconnect()
        }
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        let delay = backoffDelay()
        attempt += 1
        log.debug("reconnecting in \(delay, format: .fixed(precision: 2))s")
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.openChannel()
        }
    }

    private func backoffDelay() -> Double {
        let base = min(Self.backoffCeiling, Self.backoffFloor * pow(2.0, Double(attempt)))
        return base * Double.random(in: 0.8...1.2)
    }

    /// True when `source` is still the channel this bridge is driving. A nil
    /// `source` is a channel that has already deallocated, which can only be a
    /// stale one.
    private func isCurrent(_ source: CoreBridgeChannel?) -> Bool {
        guard let channel else { return false }
        guard let source else { return false }
        return channel === source
    }

    private func setState(_ new: ConnectionState) {
        guard state != new else { return }
        state = new
        onStateChange?(new)
    }

    private static func appIdentity() -> (version: String, build: String) {
        let info = Bundle.main.infoDictionary
        return (info?["CFBundleShortVersionString"] as? String ?? "0.0.0",
                info?["CFBundleVersion"] as? String ?? "0")
    }

    // MARK: - Sending

    /// Enqueue a control message. Throws if not connected.
    ///
    /// `nonisolated` on purpose: AudioBridge signals `audio.done` from the
    /// playback callback, which is not the main thread.
    nonisolated func send(_ message: ControlMessage) throws {
        guard let channel = liveChannel.get() else { throw BridgeError.notConnected }
        try channel.send(message)
    }

    /// Enqueue a microphone frame. Dropped silently while not `.ready` — losing a
    /// few 20ms chunks during a reconnect beats unbounded buffering.
    ///
    /// The PCM is never copied on this path: the length/type/stream header goes
    /// out as its own small write and `frame.pcm` is handed to the socket as-is
    /// (protocol.md §四 — no base64, no JSON).
    nonisolated func sendAudio(_ frame: AudioFrame) {
        guard let channel = liveChannel.get(), channel.audioAllowed else { return }
        channel.sendAudio(frame, type: .audioUplink)
    }

    // MARK: - Receiving

    private func deliver(_ frames: [CoreBridgeInbound], from source: CoreBridgeChannel?) {
        guard isCurrent(source) else { return }
        for frame in frames {
            switch frame {
            case .audio(let audio):
                onAudio?(audio)

            case .control(let message):
                switch message.body {
                case .ping:
                    // Pure transport: answer and do not bother the app with it.
                    try? send(ControlMessage(body: .pong, replyTo: message.id))
                    continue
                case .pong:
                    missedPongs = 0
                    continue
                case .coreReady(let payload):
                    guard handleCoreReady(payload) else { continue }
                case .error(let payload):
                    log.error("core error \(payload.code, privacy: .public): \(payload.message, privacy: .public)")
                    if payload.fatal {
                        // The core closes right after this frame; get ahead of it
                        // so the backoff starts now instead of on the read EOF.
                        channel?.close("core sent fatal \(payload.code)")
                    }
                default:
                    break
                }
                onControl?(message)
            }
        }
    }

    /// Returns false when the handshake was rejected and the message should not
    /// be forwarded.
    private func handleCoreReady(_ payload: CoreReadyPayload) -> Bool {
        guard payload.protocolVersion == ProtocolConstants.version else {
            fail(code: "protocol_mismatch",
                 message: "core speaks v\(payload.protocolVersion), app speaks v\(ProtocolConstants.version)")
            return false
        }
        guard Self.isSupported(payload.uplink), Self.isSupported(payload.downlink) else {
            fail(code: "audio_format_unsupported",
                 message: "app only implements mono pcm16le with a positive sample rate")
            return false
        }

        negotiatedFormats = (uplink: payload.uplink, downlink: payload.downlink)
        channel?.audioAllowed = true
        readySince = .now
        missedPongs = 0
        setState(.ready)
        startKeepalive()
        log.info("""
            handshake done: core \(payload.coreVersion, privacy: .public), \
            uplink \(payload.uplink.sampleRate)Hz, downlink \(payload.downlink.sampleRate)Hz
            """)
        return true
    }

    /// v1 is mono PCM16 little-endian on both directions (protocol.md §3.1).
    private static func isSupported(_ format: AudioFormat) -> Bool {
        format.encoding == "pcm16le"
            && format.channels == 1
            && format.sampleRate > 0
            && format.frameMillis > 0
    }

    /// Send a fatal `error` and drop the connection. The reconnect loop keeps
    /// running: the fix is usually restarting the core, and protocol.md §3.1
    /// rules out any downgrade negotiation.
    private func fail(code: String, message: String) {
        log.error("closing connection: \(code, privacy: .public) — \(message, privacy: .public)")
        try? send(ControlMessage(body: .error(ErrorPayload(code: code, message: message, fatal: true))))
        channel?.closeAfterSend(code)
    }

    // MARK: - Keepalive

    private func startKeepalive() {
        keepaliveTask?.cancel()
        keepaliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: CoreBridge.pingInterval)
                guard !Task.isCancelled, let self else { return }
                guard self.tick() else { return }
            }
        }
    }

    /// One keepalive round. Returns false when the connection was declared dead.
    private func tick() -> Bool {
        guard state == .ready, let channel else { return false }
        missedPongs += 1
        if missedPongs >= Self.maxMissedPongs {
            log.warning("no pong for \(Self.maxMissedPongs * 10)s, treating the core as gone")
            channel.close("keepalive timeout")
            return false
        }
        try? send(ControlMessage(body: .ping))
        return true
    }
}

// MARK: - Inbound frames

/// What the bridge queue hands to the main actor. Protocol violations never get
/// this far: the channel answers them with an `error` frame itself.
private enum CoreBridgeInbound: Sendable {
    case control(ControlMessage)
    case audio(AudioFrame)
}

// MARK: - Channel

/// One connection attempt and everything confined to it: the socket, the
/// incremental frame reader, and the bounded send queue.
///
/// `@unchecked Sendable` because every mutable field is either only touched on
/// `queue` (the reader) or guarded by `lock` (the send queue).
private final class CoreBridgeChannel: @unchecked Sendable {
    /// protocol.md §六: over 8 MiB queued, drop the oldest audio frames.
    /// Control frames are never dropped.
    private static let maxQueuedBytes = 8 * 1024 * 1024

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let log: Logger
    private let decoder = JSONDecoder()

    // Callbacks are set before `start()` and only read afterwards.
    var onOpen: (@Sendable () -> Void)?
    var onFrames: (@Sendable ([CoreBridgeInbound]) -> Void)?
    var onClose: (@Sendable (String) -> Void)?

    // Reader state — bridge queue only.
    private var reader = CoreBridgeFrameReader()
    private var lastDownlinkStream: UInt32 = 0
    private var lastDownlinkSequence: UInt32 = 0

    // Send state — guarded by `lock`.
    private let lock = NSLock()
    private var pending: [CoreBridgeOutFrame] = []
    private var queuedBytes = 0
    private var writing = false
    private var isClosed = false
    private var closeWhenDrained: String?
    private var droppedAudioFrames = 0
    private var lastDropReport: ContinuousClock.Instant?

    private let audioGate = CoreBridgeLockedBox<Bool>(false)
    /// True once `core.ready` landed. Audio before that is illegal
    /// (protocol.md §3.1).
    var audioAllowed: Bool {
        get { audioGate.get() }
        set { audioGate.set(newValue) }
    }

    init(socketPath: String, queue: DispatchQueue, log: Logger) {
        self.queue = queue
        self.log = log
        self.connection = NWConnection(to: .unix(path: socketPath), using: .tcp)
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.startReceive()
                self.onOpen?()
            case .waiting(let error):
                // A missing socket file parks the connection in `.waiting`
                // forever. The core may simply not be up yet, so treat it as a
                // failed attempt and let the backoff decide when to retry.
                self.close("socket unavailable: \(error)")
            case .failed(let error):
                self.close("connection failed: \(error)")
            case .cancelled:
                self.close("connection cancelled")
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func close(_ reason: String) {
        lock.lock()
        if isClosed {
            lock.unlock()
            return
        }
        isClosed = true
        pending.removeAll()
        queuedBytes = 0
        let totalDropped = droppedAudioFrames
        lock.unlock()

        // The throttled warning above can under-report the tail of a burst.
        if totalDropped > 0 {
            log.warning("connection closing after dropping \(totalDropped) audio frames")
        }

        audioAllowed = false
        connection.cancel()
        onClose?(reason)
    }

    /// Close once the queue has drained. `NWConnection.cancel()` does not push
    /// out whatever is still queued here, so closing straight away loses the
    /// frame we are closing *because of* — the fatal `error` the core is owed
    /// (protocol.md §3.6), or the `app.quit` a menu-bar quit just sent.
    /// The timer is the backstop for a peer that stopped reading.
    func closeAfterSend(_ reason: String) {
        lock.lock()
        if isClosed {
            lock.unlock()
            return
        }
        if !writing && pending.isEmpty {
            lock.unlock()
            close(reason)
            return
        }
        closeWhenDrained = reason
        lock.unlock()
        queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.close(reason)
        }
    }

    // MARK: Sending

    func send(_ message: ControlMessage) throws {
        let json = try JSONEncoder().encode(message)
        guard let length = Self.frameLength(payloadBytes: json.count) else {
            throw CoreBridge.BridgeError.frameTooLarge
        }
        var header = Data(capacity: ProtocolConstants.lengthPrefixBytes + ProtocolConstants.typeByteBytes)
        appendBigEndian(length, to: &header)
        header.append(WireFrameType.control.rawValue)
        enqueue(CoreBridgeOutFrame(chunks: [header, json], isAudio: false))
    }

    /// Header and PCM go out as two writes inside one `batch`, which keeps the
    /// samples from being copied into a concatenated buffer.
    func sendAudio(_ frame: AudioFrame, type: WireFrameType) {
        guard let length = Self.frameLength(payloadBytes: AudioFrame.headerBytes + frame.pcm.count) else {
            // 20ms of PCM is about a kilobyte; this can only be a caller bug.
            log.error("dropping a \(frame.pcm.count) byte audio frame: over the 4 MiB frame ceiling")
            return
        }
        var header = Data(capacity: ProtocolConstants.lengthPrefixBytes + ProtocolConstants.typeByteBytes + AudioFrame.headerBytes)
        appendBigEndian(length, to: &header)
        header.append(type.rawValue)
        appendBigEndian(frame.streamID, to: &header)
        appendBigEndian(frame.sequence, to: &header)
        enqueue(CoreBridgeOutFrame(chunks: [header, frame.pcm], isAudio: true))
    }

    /// The length prefix covers the type byte plus the payload, capped at
    /// 4 MiB (protocol.md §二).
    private static func frameLength(payloadBytes: Int) -> UInt32? {
        let length = ProtocolConstants.typeByteBytes + payloadBytes
        guard length <= ProtocolConstants.maxFrameBytes else { return nil }
        return UInt32(length)
    }

    private func enqueue(_ frame: CoreBridgeOutFrame) {
        lock.lock()
        guard !isClosed, closeWhenDrained == nil else {
            lock.unlock()
            return
        }
        pending.append(frame)
        queuedBytes += frame.bytes
        var dropped = 0
        while queuedBytes > Self.maxQueuedBytes,
              let index = pending.firstIndex(where: { $0.isAudio }) {
            queuedBytes -= pending.remove(at: index).bytes
            dropped += 1
        }
        let shouldPump = !writing
        if shouldPump { writing = true }
        lock.unlock()

        if dropped > 0 { reportDrops(dropped) }
        if shouldPump { pump() }
    }

    /// Once the queue is saturated every single enqueue drops a frame, so an
    /// unthrottled warning would bury the log at the exact moment something is
    /// wrong. Report the running total, at most once a second.
    private func reportDrops(_ count: Int) {
        lock.lock()
        droppedAudioFrames += count
        let now = ContinuousClock.now
        let due = lastDropReport.map { $0.duration(to: now) >= .seconds(1) } ?? true
        let total = droppedAudioFrames
        if due { lastDropReport = now }
        lock.unlock()

        if due {
            log.warning("send queue over 8 MiB: \(total) audio frames dropped so far — the core is not draining")
        }
    }

    private func pump() {
        lock.lock()
        guard !isClosed, !pending.isEmpty else {
            writing = false
            let drained = isClosed ? nil : closeWhenDrained
            lock.unlock()
            if let drained { close(drained) }
            return
        }
        let frame = pending.removeFirst()
        queuedBytes -= frame.bytes
        lock.unlock()

        connection.batch {
            for (index, chunk) in frame.chunks.enumerated() {
                let isLast = index == frame.chunks.count - 1
                connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
                    guard let self else { return }
                    if let error {
                        self.close("send failed: \(error)")
                        return
                    }
                    if isLast { self.pump() }
                })
            }
        }
    }

    // MARK: Receiving

    private func startReceive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.ingest(data) }
            if let error {
                self.close("receive failed: \(error)")
                return
            }
            if isComplete {
                self.close("core closed the socket")
                return
            }
            self.startReceive()
        }
    }

    private func ingest(_ data: Data) {
        reader.append(data)
        var batch: [CoreBridgeInbound] = []

        while true {
            let frame: (type: UInt8, payload: Data)?
            do {
                frame = try reader.next()
            } catch CoreBridgeFrameReader.ReadError.tooLarge(let length) {
                // protocol.md §二: the stream is desynchronised, do not resync.
                deliver(batch)
                violation(code: "frame_too_large", message: "length prefix \(length) exceeds 4 MiB")
                return
            } catch {
                deliver(batch)
                violation(code: "bad_frame_type", message: "frame with a zero length prefix")
                return
            }
            guard let frame else { break }

            switch WireFrameType(rawValue: frame.type) {
            case .control:
                if let inbound = decodeControl(frame.payload) {
                    batch.append(inbound)
                }
            case .audioDownlink:
                if let audio = decodeAudio(frame.payload) {
                    batch.append(.audio(audio))
                }
            default:
                // Includes 0x02: uplink audio arriving from the core means the
                // core is confused, and protocol.md §二 calls any unexpected
                // type byte fatal.
                deliver(batch)
                violation(code: "bad_frame_type",
                          message: "type 0x\(String(frame.type, radix: 16)) is not valid core → app")
                return
            }
        }

        deliver(batch)
    }

    private func deliver(_ batch: [CoreBridgeInbound]) {
        guard !batch.isEmpty else { return }
        onFrames?(batch)
    }

    private func decodeAudio(_ payload: Data) -> AudioFrame? {
        guard payload.count >= AudioFrame.headerBytes else {
            badPayload(replyTo: nil, message: "audio frame shorter than its 8 byte header")
            return nil
        }
        let base = payload.startIndex
        let streamID = readBigEndian(payload, at: base)
        let sequence = readBigEndian(payload, at: base + 4)
        // Rebased on purpose: consumers index PCM from zero, and a 960 byte copy
        // 50 times a second is not worth the class of bug a slice invites.
        let pcm = Data(payload[(base + AudioFrame.headerBytes)...])

        // protocol.md §四: report gaps, never reorder or ask for a resend.
        if streamID == lastDownlinkStream, sequence != lastDownlinkSequence &+ 1 {
            log.warning("downlink stream \(streamID) jumped from sequence \(self.lastDownlinkSequence) to \(sequence)")
        } else if streamID != lastDownlinkStream, sequence != 0 {
            log.warning("downlink stream \(streamID) opened at sequence \(sequence), not 0")
        }
        lastDownlinkStream = streamID
        lastDownlinkSequence = sequence

        return AudioFrame(streamID: streamID, sequence: sequence, pcm: pcm)
    }

    private func decodeControl(_ payload: Data) -> CoreBridgeInbound? {
        /// Only the routing fields. An unknown `type` has to be skipped without
        /// dropping the connection (protocol.md §三) — that is the one and only
        /// forward-compatibility mechanism, so it cannot go through the strict
        /// `ControlMessage` decoder.
        struct Peek: Decodable {
            var v: Int?
            var id: String?
            var type: String?
        }

        guard let peek = try? decoder.decode(Peek.self, from: payload) else {
            badPayload(replyTo: nil, message: "control frame is not a JSON object")
            return nil
        }
        if let v = peek.v, v != ProtocolConstants.version {
            violation(code: "protocol_mismatch",
                      message: "envelope v=\(v), app speaks v=\(ProtocolConstants.version)")
            return nil
        }
        guard let type = peek.type else {
            badPayload(replyTo: peek.id, message: "control frame has no `type`")
            return nil
        }
        guard MessageType(rawValue: type) != nil else {
            log.warning("ignoring unknown control type \(type, privacy: .public)")
            return nil
        }
        do {
            return .control(try decoder.decode(ControlMessage.self, from: payload))
        } catch {
            // The decoder's own text can quote payload values; keep it in the
            // local log and send back only the message type (protocol.md §3.6
            // forbids credentials on the wire).
            log.error("bad \(type, privacy: .public) payload: \(String(describing: error), privacy: .private)")
            badPayload(replyTo: peek.id, message: "\(type): payload does not match the v1 schema")
            return nil
        }
    }

    /// Non-fatal: one bad message, connection stays up (protocol.md §三).
    private func badPayload(replyTo: String?, message: String) {
        log.warning("bad payload: \(message, privacy: .public)")
        try? send(ControlMessage(body: .error(ErrorPayload(code: "bad_payload", message: message, fatal: false)),
                                 replyTo: replyTo))
    }

    /// Fatal: tell the core why, then close. Best effort — a desynchronised peer
    /// may never parse the frame.
    private func violation(code: String, message: String) {
        log.error("protocol violation \(code, privacy: .public): \(message, privacy: .public)")
        try? send(ControlMessage(body: .error(ErrorPayload(code: code, message: message, fatal: true))))
        closeAfterSend(code)
    }
}

// MARK: - Frame reader

/// Incremental parser. One socket read can carry half a frame or five frames;
/// both sides have to cope (protocol.md §二).
private struct CoreBridgeFrameReader {
    enum ReadError: Error {
        /// `length` must cover at least the type byte.
        case emptyFrame
        case tooLarge(Int)
    }

    private var buffer = Data()
    private var offset = 0

    /// Compaction threshold. Only reached when a peer trickles bytes.
    private static let compactAfter = 64 * 1024

    mutating func append(_ data: Data) {
        if offset == buffer.count {
            // Fully drained: adopt the new buffer instead of copying into the
            // old one. This is the common case, and it makes the steady state
            // one copy shorter.
            buffer = data
            offset = 0
            return
        }
        if offset > Self.compactAfter { compact() }
        buffer.append(data)
    }

    /// The next complete frame, or nil when more bytes are needed.
    mutating func next() throws -> (type: UInt8, payload: Data)? {
        let available = buffer.count - offset
        guard available >= ProtocolConstants.lengthPrefixBytes else { return nil }

        let base = buffer.startIndex + offset
        let length = Int(readBigEndian(buffer, at: base))
        guard length >= ProtocolConstants.typeByteBytes else { throw ReadError.emptyFrame }
        guard length <= ProtocolConstants.maxFrameBytes else { throw ReadError.tooLarge(length) }
        guard available - ProtocolConstants.lengthPrefixBytes >= length else { return nil }

        let type = buffer[base + ProtocolConstants.lengthPrefixBytes]
        let payloadStart = base + ProtocolConstants.lengthPrefixBytes + ProtocolConstants.typeByteBytes
        let payloadEnd = base + ProtocolConstants.lengthPrefixBytes + length
        let payload = Data(buffer[payloadStart..<payloadEnd])
        offset += ProtocolConstants.lengthPrefixBytes + length
        return (type, payload)
    }

    private mutating func compact() {
        guard offset > 0 else { return }
        buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + offset))
        offset = 0
    }
}

// MARK: - Outbound frames

private struct CoreBridgeOutFrame {
    /// Written back to back inside one `NWConnection.batch`.
    let chunks: [Data]
    let isAudio: Bool
    let bytes: Int

    init(chunks: [Data], isAudio: Bool) {
        self.chunks = chunks
        self.isAudio = isAudio
        self.bytes = chunks.reduce(0) { $0 + $1.count }
    }
}

// MARK: - Small helpers

/// Lets the nonisolated send paths reach state owned by the main actor without
/// a hop. Deliberately tiny: one lock, one value.
private final class CoreBridgeLockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T

    init(_ value: T) { self.value = value }

    func get() -> T {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: T) {
        lock.lock()
        value = newValue
        lock.unlock()
    }
}

/// Big-endian on the wire for every length and header field. The PCM samples
/// inside an audio payload stay little-endian — that mismatch is intentional
/// (protocol.md §二).
private func appendBigEndian(_ value: UInt32, to data: inout Data) {
    data.append(UInt8(truncatingIfNeeded: value >> 24))
    data.append(UInt8(truncatingIfNeeded: value >> 16))
    data.append(UInt8(truncatingIfNeeded: value >> 8))
    data.append(UInt8(truncatingIfNeeded: value))
}

private func readBigEndian(_ data: Data, at index: Data.Index) -> UInt32 {
    (UInt32(data[index]) << 24)
        | (UInt32(data[index + 1]) << 16)
        | (UInt32(data[index + 2]) << 8)
        | UInt32(data[index + 3])
}
