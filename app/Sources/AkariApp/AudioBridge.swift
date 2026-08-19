import AVFoundation
import Carbon.HIToolbox
import Foundation
import os

// MARK: - Errors

/// Failures the glue layer has to surface (menu bar, or an `error` control frame).
enum AudioBridgeError: Error, CustomStringConvertible {
    /// `core.ready` announced something other than mono `pcm16le`.
    case unsupportedFormat(String)
    /// Capture or playback was asked for before `configure(uplink:downlink:)`.
    case notConfigured
    /// The user denied (or has not yet granted) the microphone TCC permission.
    case microphoneAccessDenied
    /// No usable input device, or CoreAudio reported a 0 Hz input format.
    case noInputDevice
    /// `AVAudioConverter` refused the hardware -> uplink format pair.
    case converterUnavailable(from: String, to: String)
    /// `AVAudioEngine.start()` threw.
    case engineStartFailed(any Error)

    var description: String {
        switch self {
        case .unsupportedFormat(let why): "unsupported audio format: \(why)"
        case .notConfigured: "audio formats not negotiated yet (core.ready missing)"
        case .microphoneAccessDenied: "microphone access denied"
        case .noInputDevice: "no usable audio input device"
        case .converterUnavailable(let from, let to): "cannot convert \(from) -> \(to)"
        case .engineStartFailed(let underlying): "audio engine failed to start: \(underlying)"
        }
    }

    /// `error.code` to put on the wire (docs/protocol.md §3.6). Only a format the
    /// app genuinely cannot honour is fatal; a denied mic is recoverable once the
    /// user flips the switch in System Settings.
    var wireCode: String {
        switch self {
        case .unsupportedFormat, .converterUnavailable: "audio_format_unsupported"
        default: "internal"
        }
    }

    var isFatal: Bool { wireCode == "audio_format_unsupported" }
}

// MARK: - Microphone permission

enum MicrophoneAuthorization {
    case notDetermined
    case granted
    /// Denied or restricted by policy. Only System Settings can change this.
    case denied
}

// MARK: - Push-to-talk hotkey

/// System-wide push-to-talk key, implemented with Carbon `RegisterEventHotKey`.
///
/// Why Carbon and not `NSEvent.addGlobalMonitorForEvents`:
///
/// 1. **Permission.** A global `NSEvent` monitor for `.keyDown`/`.keyUp` only
///    delivers events once the app is Accessibility-trusted. spec.md §4.5 requires
///    first launch to ask for the microphone and nothing else, so a hotkey that
///    drags the AX prompt to launch day is disqualified. `RegisterEventHotKey`
///    needs no TCC permission at all.
/// 2. **Consumption.** A global monitor is observe-only: the key still reaches the
///    frontmost app, so holding the PTT chord would also type into whatever has
///    focus. A Carbon hotkey swallows the event.
/// 3. **Key-up.** Push-to-talk needs the release edge; `kEventHotKeyReleased` is
///    part of the same API.
///
/// There is no modern (non-Carbon) public replacement — `RegisterEventHotKey` is
/// still the only unprivileged system-wide hotkey on macOS 26.
///
/// Not verified on this machine yet: whether `kEventHotKeyReleased` fires reliably
/// when the modifier is released before the key. The protocol tolerates the bad
/// case (an unpaired `ptt.up` is ignored, docs/protocol.md §3.3), but a *missing*
/// release would leave the mic open — hence `onUp` is also driven by a safety
/// timeout in `AudioBridge`'s caller, and `stopCapture()` is idempotent.
@MainActor
final class PushToTalkHotkey {
    /// Key held down. Delivered on the main thread.
    var onDown: (() -> Void)?
    /// Key released. Delivered on the main thread.
    var onUp: (() -> Void)?

    /// Default chord: ⌥Space. Chosen because it is a chord (hard to trigger by
    /// accident) that macOS itself does not claim. It does shadow the system's
    /// "insert non-breaking space", which is an accepted trade; call
    /// `register(keyCode:modifiers:)` with something else to change it.
    static let defaultKeyCode = UInt32(kVK_Space)
    static let defaultModifiers = UInt32(optionKey)

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var isDown = false

    /// 'AKRT' — the Carbon signature that identifies our hotkey. `nonisolated`
    /// because the C trampoline below reads them before it can hop to the main actor.
    fileprivate nonisolated static let signature: OSType = 0x414B_5254
    fileprivate nonisolated static let identifier: UInt32 = 1

    // No `deinit` cleanup: `deinit` is nonisolated, and `UnregisterEventHotKey` /
    // `RemoveEventHandler` are main-thread-only Carbon calls on main-actor state.
    // The owner must call `unregister()` — `applicationWillTerminate` is the place.

    /// Register the chord. Returns false if another app already owns it.
    @discardableResult
    func register(keyCode: UInt32 = PushToTalkHotkey.defaultKeyCode,
                  modifiers: UInt32 = PushToTalkHotkey.defaultModifiers) -> Bool {
        unregister()

        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                          eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                          eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let installed = InstallEventHandler(GetEventDispatcherTarget(),
                                            akariHotkeyHandler,
                                            specs.count,
                                            &specs,
                                            Unmanaged.passUnretained(self).toOpaque(),
                                            &handlerRef)
        guard installed == noErr else {
            audioLog.error("InstallEventHandler failed: \(installed, privacy: .public)")
            return false
        }

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: Self.identifier)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetEventDispatcherTarget(), 0, &hotKeyRef)
        guard status == noErr else {
            audioLog.error("RegisterEventHotKey failed: \(status, privacy: .public) — chord already taken?")
            unregister()
            return false
        }
        return true
    }

    func unregister() {
        if isDown {
            isDown = false
            onUp?()
        }
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }

    fileprivate func handle(kind: UInt32) {
        switch Int(kind) {
        case kEventHotKeyPressed:
            // Carbon does not auto-repeat hotkeys, but guard anyway: a duplicate
            // down would open a second capture turn.
            guard !isDown else { return }
            isDown = true
            onDown?()
        case kEventHotKeyReleased:
            guard isDown else { return }
            isDown = false
            onUp?()
        default:
            break
        }
    }
}

/// C trampoline for the Carbon event dispatcher. Runs on the main run loop.
private func akariHotkeyHandler(_ callRef: EventHandlerCallRef?,
                                _ event: EventRef?,
                                _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                   EventParamType(typeEventHotKeyID), nil,
                                   MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    guard status == noErr,
          hotKeyID.signature == PushToTalkHotkey.signature,
          hotKeyID.id == PushToTalkHotkey.identifier
    else { return OSStatus(eventNotHandledErr) }

    let kind = GetEventKind(event)
    // The Carbon event dispatcher only ever calls us from the main run loop, so
    // hopping onto the main actor is an assertion rather than a dispatch.
    let context = UncheckedBox(userData)
    MainActor.assumeIsolated {
        Unmanaged<PushToTalkHotkey>.fromOpaque(context.value).takeUnretainedValue().handle(kind: kind)
    }
    return noErr
}

let audioLog = Logger(subsystem: "me.eltonzheng.akari", category: "audio")

/// Escape hatch for AVFoundation types that are thread-confined rather than
/// `Sendable`. Only used where the callee runs synchronously on the caller's thread.
private struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

// MARK: - AudioBridge

/// Microphone capture and speaker playback of raw PCM16.
///
/// v1 is push-to-talk with no echo cancellation and no wake word (ADR-005), so
/// this deliberately does NOT use `VoiceProcessingIO`: capture only runs while the
/// hotkey is held, which is what keeps the avatar's own voice out of the mic.
///
/// Capture and playback get **separate `AVAudioEngine`s**. The capture engine is
/// started on key-down and stopped on key-up, so the orange microphone indicator
/// (and the input hardware) is only live while the user is actually talking —
/// that is the whole point of ADR-005. Sharing one engine would keep the input
/// device open for as long as playback runs.
///
/// Thread model: `@unchecked Sendable` with an explicit lock. Audio callbacks
/// arrive on CoreAudio's realtime threads and on `AVAudioPlayerNode`'s completion
/// queue, neither of which is an actor; all mutable state below is guarded by
/// `lock`, and no AVFoundation call is made while holding it.
final class AudioBridge: @unchecked Sendable {
    /// Formats announced by the core in `core.ready`.
    private(set) var uplinkFormat: AudioFormat? {
        get { lock.withLock { _uplinkFormat } }
        set { lock.withLock { _uplinkFormat = newValue } }
    }
    private(set) var downlinkFormat: AudioFormat? {
        get { lock.withLock { _downlinkFormat } }
        set { lock.withLock { _downlinkFormat = newValue } }
    }

    /// One captured chunk of exactly `uplinkFormat.bytesPerFrame` bytes, PCM16LE.
    /// Called on the audio thread — do not touch UI from here.
    ///
    /// Exception: the final chunk of a turn, flushed by `stopCapture()`, may be
    /// shorter. docs/protocol.md §4 allows a short last frame, and dropping it
    /// would clip the tail of the user's last word.
    ///
    /// The callback carries no stream id or sequence number: those belong to the
    /// PTT turn, which the glue layer owns (`ptt.down` bumps the uplink stream id).
    var onCapturedChunk: ((Data) -> Void)? {
        get { lock.withLock { _onCapturedChunk } }
        set { lock.withLock { _onCapturedChunk = newValue } }
    }

    /// Every enqueued sample of `streamID` has been rendered.
    ///
    /// Fires whenever that stream's queue drains, which during a live stream can
    /// happen mid-reply if the socket under-runs. The glue layer must therefore
    /// only turn this into `audio.done` once it has also seen `audio.end` for the
    /// same stream (docs/protocol.md §3.4). Cancelled streams never fire.
    var onPlaybackFinished: ((UInt32) -> Void)? {
        get { lock.withLock { _onPlaybackFinished } }
        set { lock.withLock { _onPlaybackFinished = newValue } }
    }

    /// Capture or playback failed and the caller should surface it.
    var onError: ((Error) -> Void)? {
        get { lock.withLock { _onError } }
        set { lock.withLock { _onError = newValue } }
    }

    // MARK: Guarded state

    private let lock = NSLock()

    private var _uplinkFormat: AudioFormat?
    private var _downlinkFormat: AudioFormat?
    private var _onCapturedChunk: ((Data) -> Void)?
    private var _onPlaybackFinished: ((UInt32) -> Void)?
    private var _onError: ((Error) -> Void)?

    /// Bytes not yet emitted as a full uplink chunk. Touched on the tap thread and,
    /// on flush, by whoever calls `stopCapture()`.
    private var captureRemainder = Data()
    private var captureConverter: AVAudioConverter?
    private var captureTargetFormat: AVAudioFormat?
    private var uplinkChunkBytes = 0
    private var isCapturing = false

    /// One run of scheduled-but-not-yet-rendered buffers for a single stream id.
    ///
    /// `ticket` is what makes a completion handler safe to trust. It is minted in
    /// the *same* critical section that first counts a buffer in, and a new one is
    /// minted every time the queue for that id is reset (`cancelPlayback`,
    /// `beginPlaybackStream`). A completion therefore decrements only the run it
    /// was actually counted into: buffers scheduled before a barge-in cannot
    /// decrement the run that came after it, and cannot leave a count behind
    /// either, because a run they no longer match is simply gone.
    private struct PlaybackRun {
        let ticket: UInt64
        var pending: Int
    }

    /// streamID -> buffers scheduled but not yet rendered.
    private var pendingBuffers: [UInt32: PlaybackRun] = [:]
    /// Source of `PlaybackRun.ticket`. Only ever read and bumped under `lock`.
    private var nextPlaybackTicket: UInt64 = 0
    /// Recently cancelled stream ids, newest last. Bounded — this is only used to
    /// drop the handful of frames still in flight when a barge-in lands.
    ///
    /// Entries are removed again by `beginPlaybackStream(_:)` (the core reopened
    /// that id, so the frames behind it are new) and by `configure(uplink:downlink:)`
    /// (a fresh handshake restarts the core's numbering at 1). Without those two
    /// exits the list is an ever-growing kill list: the core resets `nextStreamId`
    /// on every `app.hello`, so after a reconnect a brand new stream inherits a
    /// stale id's ban, gets dropped whole, and never drains — no `audio.done`, and
    /// the avatar is stuck in `talking` for good.
    private var cancelledStreams: [UInt32] = []
    private var playbackFormat: AVAudioFormat?
    /// Sample rate the player node is currently wired for.
    private var playbackSampleRate: Double = 0

    // MARK: Engines

    private let captureEngine = AVAudioEngine()
    private let playbackEngine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var playbackGraphReady = false
    private var configurationObservers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        // Hardware changes (AirPods in/out, display with speakers unplugged) stop
        // the engine without an error callback; both engines have to be rebuilt.
        configurationObservers.append(
            center.addObserver(forName: .AVAudioEngineConfigurationChange,
                               object: captureEngine, queue: nil) { [weak self] _ in
                self?.handleCaptureConfigurationChange()
            })
        configurationObservers.append(
            center.addObserver(forName: .AVAudioEngineConfigurationChange,
                               object: playbackEngine, queue: nil) { [weak self] _ in
                self?.handlePlaybackConfigurationChange()
            })
    }

    deinit {
        for observer in configurationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Microphone permission

    var microphoneAuthorization: MicrophoneAuthorization {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    /// Show the microphone TCC prompt if it has not been answered yet.
    ///
    /// Requires `NSMicrophoneUsageDescription` in Info.plist (the Makefile's
    /// `app-bundle` target sets it) — without it the process is killed, not denied.
    /// A bare binary run from the terminal inherits the terminal's grant, so this
    /// only tells the truth from inside a real signed .app (spec.md §4.4).
    func requestMicrophoneAccess(_ completion: @escaping @Sendable (Bool) -> Void) {
        switch microphoneAuthorization {
        case .granted:
            completion(true)
        case .denied:
            completion(false)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in completion(granted) }
        }
    }

    // MARK: - Configuration

    /// Apply the negotiated formats. Must be called before capture or playback.
    func configure(uplink: AudioFormat, downlink: AudioFormat) throws {
        try Self.validate(uplink, label: "uplink")
        try Self.validate(downlink, label: "downlink")

        stopCapture()
        cancelPlayback(streamID: nil)

        let target = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                   sampleRate: Double(uplink.sampleRate),
                                   channels: AVAudioChannelCount(uplink.channels),
                                   interleaved: true)
        // Float32 for playback: AVAudioPlayerNode and the main mixer speak float,
        // and the mixer resamples the downlink rate to whatever the device runs at.
        let playback = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                     sampleRate: Double(downlink.sampleRate),
                                     channels: AVAudioChannelCount(downlink.channels),
                                     interleaved: false)
        guard let target, let playback else {
            throw AudioBridgeError.unsupportedFormat("CoreAudio rejected the announced rates")
        }

        lock.withLock {
            _uplinkFormat = uplink
            _downlinkFormat = downlink
            captureTargetFormat = target
            uplinkChunkBytes = uplink.bytesPerFrame
            captureRemainder.removeAll(keepingCapacity: true)
            playbackFormat = playback
            // Ordered after `cancelPlayback(streamID: nil)` above, which is what
            // put the in-flight ids on the list. This is a new negotiated session
            // and the core's stream numbering starts over, so nothing from the old
            // one may still be banned.
            cancelledStreams.removeAll(keepingCapacity: true)
        }
    }

    private static func validate(_ format: AudioFormat, label: String) throws {
        guard format.encoding == "pcm16le" else {
            throw AudioBridgeError.unsupportedFormat("\(label) encoding \(format.encoding), only pcm16le")
        }
        guard format.channels == 1 else {
            throw AudioBridgeError.unsupportedFormat("\(label) channels \(format.channels), only mono in v1")
        }
        guard format.sampleRate > 0, format.frameMillis > 0, format.bytesPerFrame > 0 else {
            throw AudioBridgeError.unsupportedFormat("\(label) has a non-positive rate or frame size")
        }
    }

    // MARK: - Capture

    /// Begin capturing. Triggers the microphone TCC prompt on first call.
    ///
    /// Idempotent: a second call while already capturing is a no-op, so a doubled
    /// key-down cannot open two taps.
    func startCapture() throws {
        let (target, chunkBytes, alreadyCapturing) = lock.withLock {
            (captureTargetFormat, uplinkChunkBytes, isCapturing)
        }
        guard !alreadyCapturing else { return }
        guard let target, chunkBytes > 0 else { throw AudioBridgeError.notConfigured }
        guard microphoneAuthorization == .granted else { throw AudioBridgeError.microphoneAccessDenied }

        let input = captureEngine.inputNode
        let hardware = input.outputFormat(forBus: 0)
        // A detached or still-waking input device reports 0 Hz; installing a tap
        // with that format traps inside AVFAudio.
        guard hardware.sampleRate > 0, hardware.channelCount > 0 else {
            throw AudioBridgeError.noInputDevice
        }
        guard let converter = AVAudioConverter(from: hardware, to: target) else {
            throw AudioBridgeError.converterUnavailable(from: "\(hardware)", to: "\(target)")
        }
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue

        lock.withLock {
            captureConverter = converter
            captureRemainder.removeAll(keepingCapacity: true)
            isCapturing = true
        }

        // ~21ms at 48kHz: one tap callback per uplink frame, no extra latency from
        // waiting for a big buffer to fill.
        input.installTap(onBus: 0, bufferSize: 1024, format: hardware) { [weak self] buffer, _ in
            self?.consumeCaptured(buffer)
        }

        do {
            captureEngine.prepare()
            try captureEngine.start()
        } catch {
            input.removeTap(onBus: 0)
            lock.withLock {
                isCapturing = false
                captureConverter = nil
            }
            throw AudioBridgeError.engineStartFailed(error)
        }
    }

    /// Stop capturing and flush the trailing partial chunk. Idempotent.
    func stopCapture() {
        let wasCapturing = lock.withLock {
            let was = isCapturing
            isCapturing = false
            return was
        }
        guard wasCapturing else { return }

        captureEngine.inputNode.removeTap(onBus: 0)
        captureEngine.stop()

        let (tail, sink) = lock.withLock { () -> (Data, ((Data) -> Void)?) in
            let tail = captureRemainder
            captureRemainder.removeAll(keepingCapacity: true)
            captureConverter = nil
            return (tail, _onCapturedChunk)
        }
        if !tail.isEmpty { sink?(tail) }
    }

    /// Called on CoreAudio's capture thread.
    private func consumeCaptured(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }

        let (converter, target, chunkBytes, capturing) = lock.withLock {
            (captureConverter, captureTargetFormat, uplinkChunkBytes, isCapturing)
        }
        guard capturing, let converter, let target, chunkBytes > 0 else { return }

        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }

        // `AVAudioConverterInputBlock` is typed `@Sendable`, but it is called
        // synchronously on this very thread before `convert` returns, so handing it
        // the tap buffer is safe — the box is what tells the compiler so.
        let source = UncheckedBox(buffer)
        nonisolated(unsafe) var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: converted, error: &conversionError) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return source.value
        }

        switch status {
        case .haveData, .inputRanDry:
            break
        case .endOfStream:
            return
        case .error:
            report(AudioBridgeError.engineStartFailed(
                conversionError ?? NSError(domain: NSOSStatusErrorDomain, code: -1)))
            return
        @unknown default:
            return
        }

        guard converted.frameLength > 0, let samples = converted.int16ChannelData else { return }
        let byteCount = Int(converted.frameLength) * Int(target.channelCount) * MemoryLayout<Int16>.size
        let pcm = Data(bytes: samples[0], count: byteCount)

        // Slice into exact frames under the lock, hand them to the sink outside it.
        var chunks: [Data] = []
        let sink: ((Data) -> Void)? = lock.withLock {
            guard isCapturing else { return nil }
            captureRemainder.append(pcm)
            while captureRemainder.count >= chunkBytes {
                // Rebase: a `Data` slice keeps the parent's indices, and the
                // consumer will reasonably expect `chunk[0]` to be the first byte.
                chunks.append(Data(captureRemainder.prefix(chunkBytes)))
                captureRemainder.removeFirst(chunkBytes)
            }
            return _onCapturedChunk
        }
        guard let sink else { return }
        for chunk in chunks { sink(chunk) }
    }

    private func handleCaptureConfigurationChange() {
        guard lock.withLock({ isCapturing }) else { return }
        audioLog.info("capture device changed mid-turn; restarting tap")
        stopCapture()
        do { try startCapture() } catch { report(error) }
    }

    // MARK: - Playback

    /// A new downlink stream is opening (`audio.begin`, docs/protocol.md §3.4).
    ///
    /// Lifts any cancellation still recorded for this id. Downlink PCM is only
    /// legal between `audio.begin` and `audio.end`, so this is the exact and only
    /// moment at which frames carrying `streamID` stop being "late frames of the
    /// cancelled stream" and start being "the new stream".
    ///
    /// Any queue still recorded for the id belongs to that previous life and is
    /// dropped with it. The core only reuses an id after the old stream ended or
    /// was cancelled, and after a reconnect it restarts numbering at 1 — so a
    /// count surviving into the new stream could only ever be wrong, and a count
    /// that starts too high never reaches zero: no `onPlaybackFinished`, no
    /// `audio.done`, and the avatar stays `talking` for good. Buffers of the old
    /// run keep their old ticket, so their completions cannot touch the new run.
    func beginPlaybackStream(_ streamID: UInt32) {
        lock.withLock {
            cancelledStreams.removeAll { $0 == streamID }
            pendingBuffers.removeValue(forKey: streamID)
        }
    }

    /// Whether late frames of `streamID` are currently being dropped. Exists for
    /// the tests around the cancellation lifecycle; nothing in the app reads it.
    func isPlaybackStreamCancelled(_ streamID: UInt32) -> Bool {
        lock.withLock { cancelledStreams.contains(streamID) }
    }

    /// Buffers of `streamID` scheduled but not yet rendered. Exists for the tests
    /// around the queue-accounting races; nothing in the app reads it.
    func pendingPlaybackBuffers(for streamID: UInt32) -> Int {
        lock.withLock { pendingBuffers[streamID]?.pending ?? 0 }
    }

    /// Queue PCM16LE for playback. Frames of a stream arrive in `sequence` order;
    /// out-of-order or late frames of a cancelled stream must be dropped.
    ///
    /// `format` carries `audio.begin`'s per-stream override; nil keeps the format
    /// negotiated in `core.ready`.
    func enqueuePlayback(_ pcm: Data, streamID: UInt32, format: AudioFormat? = nil) {
        guard !pcm.isEmpty else { return }

        if let format {
            do { try applyPlaybackFormat(format) } catch { report(error); return }
        }

        let avFormat = lock.withLock { () -> AVAudioFormat? in
            guard let playbackFormat else { return nil }
            guard !cancelledStreams.contains(streamID) else { return nil }
            return playbackFormat
        }
        guard let avFormat else {
            if lock.withLock({ playbackFormat == nil }) { report(AudioBridgeError.notConfigured) }
            return
        }

        guard let buffer = Self.makeBuffer(from: pcm, format: avFormat) else { return }

        do { try startPlaybackIfNeeded(format: avFormat) } catch { report(error); return }

        // Everything slow is done: the sample conversion above and, on the first
        // frame of a stream, a real `AVAudioEngine.start()`. Only now is the
        // buffer counted in — and the ticket it is counted under is read in the
        // very same critical section. Splitting those two (read the run, then
        // count) is what used to strand a count: a `cancelPlayback` landing in
        // between reset the queue, and the increment that followed re-created an
        // entry no completion handler would ever match.
        let ticket = lock.withLock { () -> UInt64? in
            guard !cancelledStreams.contains(streamID) else { return nil }
            if var run = pendingBuffers[streamID] {
                run.pending += 1
                pendingBuffers[streamID] = run
                return run.ticket
            }
            nextPlaybackTicket &+= 1
            pendingBuffers[streamID] = PlaybackRun(ticket: nextPlaybackTicket, pending: 1)
            return nextPlaybackTicket
        }
        guard let ticket else { return }

        player.scheduleBuffer(buffer, completionCallbackType: .dataRendered) { [weak self] _ in
            self?.bufferRendered(streamID: streamID, ticket: ticket)
        }
        if !player.isPlaying { player.play() }
    }

    /// Drop everything still queued. nil = every stream (barge-in).
    func cancelPlayback(streamID: UInt32?) {
        let hadWork = lock.withLock { () -> Bool in
            let ids = streamID.map { [$0] } ?? Array(pendingBuffers.keys)
            for id in ids where !cancelledStreams.contains(id) {
                cancelledStreams.append(id)
            }
            // Keep the ignore-list bounded; late frames arrive within milliseconds.
            if cancelledStreams.count > 32 {
                cancelledStreams.removeFirst(cancelledStreams.count - 32)
            }
            let had = !pendingBuffers.isEmpty
            // `stop()` below unschedules every stream's buffers, not just this
            // id's, so every run has to go. Dropping the runs is what invalidates
            // their tickets: a completion arriving afterwards finds no run of its
            // own to decrement, and an enqueue racing this cancel mints a fresh
            // ticket instead of resurrecting a dead one.
            pendingBuffers.removeAll(keepingCapacity: true)
            return had
        }
        guard hadWork else { return }

        // Callers are NOT serialised. `handlePlaybackConfigurationChange` reaches
        // here from an `AVAudioEngineConfigurationChange` observer registered with
        // `queue: nil`, i.e. on whichever thread posted the notification, while the
        // main actor may be inside `enqueuePlayback` — swapping headphones or
        // unplugging an external display during a reply does exactly that. The
        // ticket scheme above, not caller discipline, is what keeps the accounting
        // straight across that overlap.
        // `stop()` is the only way to unschedule buffers; it also fires their
        // completion handlers, which the ticket check discards. Never call it
        // while holding the lock.
        player.stop()
    }

    /// True while the engine is rendering audio; drives the `talking` state.
    var isPlaying: Bool {
        lock.withLock { pendingBuffers.values.contains { $0.pending > 0 } }
    }

    private func bufferRendered(streamID: UInt32, ticket: UInt64) {
        let finished = lock.withLock { () -> ((UInt32) -> Void)? in
            // A mismatched ticket means the run this buffer was counted into is
            // gone (cancelled, or the id was reopened). Its count went with it.
            guard var run = pendingBuffers[streamID], run.ticket == ticket else { return nil }
            if run.pending <= 1 {
                pendingBuffers.removeValue(forKey: streamID)
                return cancelledStreams.contains(streamID) ? nil : _onPlaybackFinished
            }
            run.pending -= 1
            pendingBuffers[streamID] = run
            return nil
        }
        finished?(streamID)
    }

    private func applyPlaybackFormat(_ format: AudioFormat) throws {
        try Self.validate(format, label: "audio.begin")
        let unchanged = lock.withLock {
            playbackFormat?.sampleRate == Double(format.sampleRate)
                && playbackFormat?.channelCount == AVAudioChannelCount(format.channels)
        }
        guard !unchanged else { return }

        guard let avFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                           sampleRate: Double(format.sampleRate),
                                           channels: AVAudioChannelCount(format.channels),
                                           interleaved: false) else {
            throw AudioBridgeError.unsupportedFormat("audio.begin rate \(format.sampleRate) rejected")
        }
        // Rewiring the player node means tearing the graph down; anything still
        // queued belongs to the previous format anyway. A stream dropped this way
        // never gets `audio.done`, same as a cancelled one — the core has already
        // moved on if it is announcing a new format.
        cancelPlayback(streamID: nil)
        playbackEngine.stop()
        lock.withLock {
            playbackFormat = avFormat
            playbackGraphReady = false
        }
    }

    private func startPlaybackIfNeeded(format: AVAudioFormat) throws {
        let needsGraph = lock.withLock { !playbackGraphReady || playbackSampleRate != format.sampleRate }
        if needsGraph {
            if player.engine == nil { playbackEngine.attach(player) }
            playbackEngine.connect(player, to: playbackEngine.mainMixerNode, format: format)
            lock.withLock {
                playbackGraphReady = true
                playbackSampleRate = format.sampleRate
            }
        }
        guard !playbackEngine.isRunning else { return }
        do {
            playbackEngine.prepare()
            try playbackEngine.start()
        } catch {
            lock.withLock { playbackGraphReady = false }
            throw AudioBridgeError.engineStartFailed(error)
        }
    }

    private func handlePlaybackConfigurationChange() {
        lock.withLock { playbackGraphReady = false }
        guard isPlaying else { return }
        audioLog.info("output device changed mid-stream; dropping the rest of the reply")
        // The reply cannot be resumed cleanly across a device switch, and the
        // protocol has no resume: drop it and let core move the avatar back to idle.
        cancelPlayback(streamID: nil)
    }

    /// PCM16LE bytes -> deinterleaved float32. arm64 is little-endian, so a native
    /// `Int16` load is already the wire order; the source may be unaligned.
    private static func makeBuffer(from pcm: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let channels = Int(format.channelCount)
        let frames = pcm.count / (2 * channels)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(frames)),
              let destination = buffer.floatChannelData
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)

        pcm.withUnsafeBytes { raw in
            for frame in 0..<frames {
                for channel in 0..<channels {
                    let offset = (frame * channels + channel) * 2
                    let sample = raw.loadUnaligned(fromByteOffset: offset, as: Int16.self)
                    destination[channel][frame] = Float(sample) / 32768.0
                }
            }
        }
        return buffer
    }

    // MARK: - Teardown

    /// Release the audio hardware. Call on disconnect, on system sleep, and before
    /// quitting — an idle running engine keeps the output device awake for nothing.
    func teardown() {
        stopCapture()
        cancelPlayback(streamID: nil)
        playbackEngine.stop()
        lock.withLock { playbackGraphReady = false }
    }

    private func report(_ error: any Error) {
        let handler = lock.withLock { _onError }
        audioLog.error("\(String(describing: error), privacy: .public)")
        handler?(error)
    }
}
