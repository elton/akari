import AppKit
import Foundation
import os

private let appLog = Logger(subsystem: "me.eltonzheng.akari", category: "app")

/// Assembly point: everything the module owners built, wired together.
///
/// The rule from spec.md §3.1 is that this layer is glue and holds no business
/// judgement. What lives here is therefore only plumbing — which callback feeds
/// which object — plus the two things protocol.md explicitly assigns to the app:
/// pairing `audio.end` with the moment playback actually drains, and the four
/// things a dropped connection obliges it to do (§六).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let bridge = CoreBridge()
    private let audio = AudioBridge()
    private let windows = DesktopWindowController()
    private let menu = MenuBarController()
    private let hotkey = PushToTalkHotkey()
    private let prompts = ToolPromptPresenter()
    private let core = CoreProcess()

    /// One player per display: a `CALayer` has a single superlayer, so the two
    /// 5K panels cannot share one.
    private var players: [CGDirectDisplayID: AvatarPlayer] = [:]
    private var avatarState: AvatarState = .idle

    // Uplink turn state. The stream/sequence counters live further down: they
    // are read from CoreAudio's capture thread, not from the main actor.
    private var isCapturing = false

    /// Downlink streams whose `audio.end` has arrived. `audio.done` is owed once
    /// such a stream also drains (protocol.md §3.4).
    private var endedStreams: Set<UInt32> = []
    /// Streams that drained before their `audio.end` landed — the same race from
    /// the other side.
    private var drainedStreams: Set<UInt32> = []

    private var assetDirectory: URL { Self.resolveAssetDirectory() }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        menu.install()
        menu.setCoreStatus("core: 未连接")

        wireWindows()
        wireMenu()
        wireHotkey()
        wireAudio()
        wireBridge()

        windows.start()
        requestMicrophoneAccessAtLaunch()

        // Before `bridge.connect()`, not after: the first look is a real
        // `connect(2)` on the core's socket, and the core admits one client at a
        // time (protocol.md §一). Today the core drops the probe before it can
        // take that slot — it hangs up too fast to be identified — but that is
        // the *core's* current behaviour, not a promise to this side, so the app
        // does not lean on it: it asks while it demonstrably holds no connection
        // of its own.
        //
        // The judgement is "is anybody serving that socket", never "has our
        // handshake finished by <deadline>" — the handshake routinely lands after
        // any fixed deadline (the backoff alone reaches 3.75s), and a core that is
        // up but not yet talking to us is still a core.
        core.spawnUnlessCoreIsServing { [weak self] in
            self?.bridge.state == .ready
        }

        bridge.connect()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkey.unregister()
        // Only a core this app started follows it out. One the developer launched
        // by hand (`make run-core`) keeps running: quitting the app should not
        // take down a core the app did not own, and `AKARI_SUPERVISED` — set only
        // on the children we spawn — is the same line that already decides which
        // cores run the parent watchdog.
        if core.isSupervising {
            try? bridge.send(ControlMessage(body: .appQuit))
        }
        prompts.dismissAll()
        audio.teardown()
        bridge.disconnect()
        windows.stop()
        menu.remove()
        core.terminate()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: - Wiring

    private func wireWindows() {
        windows.makeLayer = { [weak self] displayID in
            guard let self else { return CALayer() }
            let player = AvatarPlayer(assetDirectory: self.assetDirectory)
            do {
                try player.preload()
                player.transition(to: self.avatarState, duration: 0)
            } catch {
                // A missing asset directory must not take the app down: the
                // window stays, empty, and the warning says what to render.
                appLog.error("avatar assets unavailable: \(error.localizedDescription, privacy: .public)")
                FileHandle.standardError.write(Data("akari: \(error.localizedDescription)\n".utf8))
            }
            self.players[displayID] = player
            return player.rootLayer
        }
        windows.disposeLayer = { [weak self] displayID in
            self?.players.removeValue(forKey: displayID)
        }
        windows.onRenderingChanged = { [weak self] displayID, shouldRender in
            guard let player = self?.players[displayID] else { return }
            // RISK-2: an occluded AVQueuePlayer keeps decoding (3.77% CPU vs
            // 0.07% paused). Not pausing is a pure battery tax.
            if shouldRender { player.resume() } else { player.pause() }
        }
    }

    private func wireMenu() {
        menu.onQuit = { NSApp.terminate(nil) }
        menu.onToggleVisible = { [weak self] visible in
            self?.windows.setPaused(!visible)
            for window in self?.windows.allWindows ?? [] {
                if visible { window.show() } else { window.orderOut(nil) }
            }
        }
        menu.onOpenSettings = {
            // No settings surface yet; the .env file is the configuration.
            NSWorkspace.shared.open(Self.repoRoot())
        }
        menu.onTalkPressed = { [weak self] in self?.beginTurn(source: .menu) }
        menu.onTalkReleased = { [weak self] in self?.endTurn(source: .menu) }
    }

    private func wireHotkey() {
        hotkey.onDown = { [weak self] in
            self?.menu.setTalking(true)
            self?.beginTurn(source: .hotkey)
        }
        hotkey.onUp = { [weak self] in
            self?.menu.setTalking(false)
            self?.endTurn(source: .hotkey)
        }
        if !hotkey.register() {
            menu.setCoreStatus("core: 热键 ⌥空格 被占用")
            appLog.warning("push-to-talk hotkey could not be registered; use the menu item")
        }
    }

    private func wireAudio() {
        audio.onCapturedChunk = { [weak self] pcm in
            guard let self else { return }
            // Deliberately not hopped to the main actor: this runs on CoreAudio's
            // capture thread every 20ms, and `sendAudio` is nonisolated for
            // exactly that reason.
            let frame = AudioFrame(streamID: self.uplinkStreamIDForAudioThread(),
                                   sequence: self.nextUplinkSequence(),
                                   pcm: pcm)
            self.bridge.sendAudio(frame)
        }
        audio.onPlaybackFinished = { [weak self] streamID in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.playbackDrained(streamID) }
            }
        }
        audio.onError = { [weak self] error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.reportAudioError(error) }
            }
        }
    }

    private func wireBridge() {
        bridge.onStateChange = { [weak self] state in
            self?.handleConnectionState(state)
        }
        bridge.onControl = { [weak self] message in
            self?.handleControl(message)
        }
        bridge.onAudio = { [weak self] frame in
            self?.handleDownlinkAudio(frame)
        }
    }

    // MARK: - Connection state

    private func handleConnectionState(_ state: CoreBridge.ConnectionState) {
        switch state {
        case .connecting:
            menu.setCoreStatus("core: 连接中…")
        case .ready:
            menu.setCoreStatus("core: 已连接")
            if let formats = bridge.negotiatedFormats {
                do {
                    try audio.configure(uplink: formats.uplink, downlink: formats.downlink)
                } catch {
                    reportAudioError(error)
                }
            }
        case .disconnected:
            // protocol.md §六, all four, none optional.
            menu.setCoreStatus("core: 未连接")
            stopCapture()
            audio.cancelPlayback(streamID: nil)
            endedStreams.removeAll()
            drainedStreams.removeAll()
            prompts.dismissAll()
            // The only moment the app decides an avatar state for itself.
            applyAvatarState(.idle, transitionMs: nil)
        }
    }

    // MARK: - Control messages

    private func handleControl(_ message: ControlMessage) {
        switch message.body {
        case .coreReady:
            break // handled in handleConnectionState(.ready)

        case .avatarSetState(let payload):
            applyAvatarState(payload.state, transitionMs: payload.transitionMs)

        case .audioBegin(let payload):
            endedStreams.remove(payload.streamId)
            drainedStreams.remove(payload.streamId)
            // The core reopened this id, so anything the player still holds against
            // it is stale. Matters after a reconnect: the core restarts numbering at
            // 1 on every handshake, and a barge-in or a disconnect just before that
            // will have banned exactly those low ids.
            audio.beginPlaybackStream(payload.streamId)
            pendingFormats[payload.streamId] = payload.format

        case .audioEnd(let payload):
            pendingFormats.removeValue(forKey: payload.streamId)
            if drainedStreams.remove(payload.streamId) != nil {
                // Already drained; the samples were rendered before the end
                // marker arrived. Answer now.
                sendAudioDone(payload.streamId)
            } else {
                endedStreams.insert(payload.streamId)
            }

        case .audioCancel(let payload):
            audio.cancelPlayback(streamID: payload.streamId)
            if let streamId = payload.streamId {
                endedStreams.remove(streamId)
                drainedStreams.remove(streamId)
                pendingFormats.removeValue(forKey: streamId)
            } else {
                endedStreams.removeAll()
                drainedStreams.removeAll()
                pendingFormats.removeAll()
            }

        case .toolConfirmRequest(let payload):
            prompts.showConfirm(payload) { [weak self] decision in
                try? self?.bridge.send(ControlMessage(
                    body: .toolConfirmResponse(ToolConfirmResponsePayload(
                        requestId: payload.requestId, decision: decision)),
                    replyTo: message.id))
            }

        case .toolUndoable(let payload):
            prompts.showUndoable(payload) { [weak self] in
                try? self?.bridge.send(ControlMessage(
                    body: .toolUndo(ToolUndoPayload(requestId: payload.requestId)),
                    replyTo: message.id))
            }

        case .clipboardReadRequest(let payload):
            // The whole point of routing this through the app: only AppKit can
            // see the concealed/transient markers (protocol.md §3.7).
            let answer = Clipboard.read(payload)
            try? bridge.send(ControlMessage(body: .clipboardReadResponse(answer),
                                            replyTo: message.id))

        case .uiNotice(let payload):
            menu.showNotice(payload.text)
            appLog.log(level: payload.level.osLogType,
                       "[core notice] \(payload.text, privacy: .public)")

        case .appQuit:
            NSApp.terminate(nil)

        case .log(let payload):
            appLog.log(level: payload.level.osLogType,
                       "[core] \(payload.message, privacy: .public)")

        case .error:
            break // CoreBridge already logged it and closed if fatal

        default:
            break
        }
    }

    /// Per-stream format overrides from `audio.begin`, applied to the first PCM
    /// frame of the stream (protocol.md §3.4).
    private var pendingFormats: [UInt32: AudioFormat?] = [:]

    private func handleDownlinkAudio(_ frame: AudioFrame) {
        // A frame that arrives after cancel/end is a normal pipeline race and is
        // dropped silently (protocol.md §3.4).
        if endedStreams.contains(frame.streamID) { return }
        // More audio for a stream that already drained means it under-ran, not
        // that it finished. Forget the drain, or `audio.end` would answer with
        // `audio.done` while these samples are still queued.
        drainedStreams.remove(frame.streamID)
        let override = pendingFormats.removeValue(forKey: frame.streamID) ?? nil
        audio.enqueuePlayback(frame.pcm, streamID: frame.streamID, format: override)
    }

    private func playbackDrained(_ streamID: UInt32) {
        // Drains happen mid-stream whenever the socket under-runs, so this only
        // means "done" once `audio.end` has also been seen.
        if endedStreams.remove(streamID) != nil {
            sendAudioDone(streamID)
        } else {
            drainedStreams.insert(streamID)
        }
    }

    private func sendAudioDone(_ streamID: UInt32) {
        try? bridge.send(ControlMessage(body: .audioDone(AudioDonePayload(streamId: streamID))))
    }

    // MARK: - Avatar

    private func applyAvatarState(_ state: AvatarState, transitionMs: Int?) {
        avatarState = state
        menu.setAvatarState(state)
        let duration = transitionMs.map { Double($0) / 1000.0 } ?? 0.12
        for player in players.values {
            player.transition(to: state, duration: duration)
        }
    }

    // MARK: - Push to talk

    /// Settle the microphone TCC permission at launch, per spec.md §4.5 ("首启只要
    /// 麦克风"). The point is not just when the prompt appears: it is that nothing on
    /// the push-to-talk path may then wait on an answer. A prompt raised from
    /// `beginTurn` is answered seconds later, long after the key was released, and
    /// the release edge has nowhere to land — the capture starts anyway and the
    /// microphone stays open for the rest of the session.
    ///
    /// Only asked for from a real bundle. `AVCaptureDevice.requestAccess` from a
    /// bare `swift run` binary has no `NSMicrophoneUsageDescription` to show and
    /// TCC kills the process rather than denying it; that build inherits whatever
    /// the terminal was granted, which is what `make run` has always relied on.
    private func requestMicrophoneAccessAtLaunch() {
        guard audio.microphoneAuthorization == .notDetermined else { return }
        guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil else {
            appLog.warning("not a bundled app: skipping the microphone prompt, TCC follows the terminal")
            return
        }
        audio.requestMicrophoneAccess { granted in
            appLog.log(level: granted ? .info : .default,
                       "microphone access \(granted ? "granted" : "denied", privacy: .public)")
        }
    }

    private func beginTurn(source: PttSource) {
        guard bridge.state == .ready else {
            appLog.warning("push-to-talk ignored: core is not connected")
            menu.setTalking(false)
            return
        }
        guard !isCapturing else { return }

        // A plain read, never a request: authorization was settled at launch, and
        // an async step here would let a key release slip past `endTurn` (which
        // would find `isCapturing` still false) and strand the microphone open.
        switch audio.microphoneAuthorization {
        case .granted:
            break
        case .notDetermined:
            // Launch prompt still on screen, or an unbundled build. Drop the turn
            // rather than starting one the user cannot have meant to finish.
            appLog.warning("push-to-talk ignored: the microphone prompt is unanswered")
            menu.setTalking(false)
            return
        case .denied:
            reportAudioError(AudioBridgeError.microphoneAccessDenied)
            menu.setTalking(false)
            return
        }

        // Bump the turn id before the first chunk can be produced.
        uplinkStreamLock.withLock {
            uplinkStreamValue = uplinkStreamValue == UInt32.max ? 1 : uplinkStreamValue + 1
            uplinkSequenceValue = 0
        }

        // ptt.down must reach the core BEFORE the first microphone frame can.
        // startCapture() installs a tap whose callback runs on a CoreAudio thread, and
        // that thread can enqueue an uplink frame before the main actor gets around to
        // sending ptt.down — leaving the core receiving audio for a turn it does not yet
        // know has begun. Announce the turn first, then open the mic; if the mic fails to
        // open, retract the turn so the core is not left waiting for a ptt.up that the
        // guard in endTurn() would swallow.
        try? bridge.send(ControlMessage(body: .pttDown(PttPayload(source: source))))
        do {
            try audio.startCapture()
        } catch {
            try? bridge.send(ControlMessage(body: .pttUp(PttPayload(source: source))))
            reportAudioError(error)
            menu.setTalking(false)
            return
        }
        isCapturing = true
    }

    private func endTurn(source: PttSource) {
        guard isCapturing else { return }
        stopCapture()
        try? bridge.send(ControlMessage(body: .pttUp(PttPayload(source: source))))
    }

    private func stopCapture() {
        guard isCapturing else { return }
        isCapturing = false
        // Flushes the trailing partial chunk through onCapturedChunk first.
        audio.stopCapture()
    }

    private func reportAudioError(_ error: any Error) {
        appLog.error("audio: \(String(describing: error), privacy: .public)")
        if let audioError = error as? AudioBridgeError {
            menu.setCoreStatus("core: 音频错误 — \(audioError.description)")
            try? bridge.send(ControlMessage(body: .error(ErrorPayload(
                code: audioError.wireCode,
                message: audioError.description,
                fatal: audioError.isFatal))))
        } else {
            menu.setCoreStatus("core: 音频错误")
        }
    }

    // MARK: - Uplink numbering (touched from the capture thread)

    private let uplinkStreamLock = NSLock()
    private nonisolated(unsafe) var uplinkStreamValue: UInt32 = 0
    private nonisolated(unsafe) var uplinkSequenceValue: UInt32 = 0

    private nonisolated func uplinkStreamIDForAudioThread() -> UInt32 {
        uplinkStreamLock.withLock { uplinkStreamValue }
    }

    private nonisolated func nextUplinkSequence() -> UInt32 {
        uplinkStreamLock.withLock {
            let value = uplinkSequenceValue
            uplinkSequenceValue &+= 1
            return value
        }
    }

    // MARK: - Paths

    /// `AKARI_ASSETS_DIR`, then the bundle's Resources, then `<repo>/assets/akari`
    /// so `swift run` from a checkout finds the clips without any setup.
    private static func resolveAssetDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["AKARI_ASSETS_DIR"],
           !override.isEmpty {
            return URL(filePath: override)
        }
        let bundled = Bundle.main.bundleURL
            .appending(path: "Contents/Resources/akari", directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: bundled.path(percentEncoded: false)) {
            return bundled
        }
        return repoRoot().appending(path: "assets/akari", directoryHint: .isDirectory)
    }

    /// The checkout this binary was built in — a **development convenience**,
    /// and only ever a hint about where to find data.
    ///
    /// Walking up from the executable is a reasonable way to locate `assets/`
    /// while running `swift run` from a clone. It is a terrible way to locate
    /// anything the app then *executes*, because the directories above a shipped
    /// `.app` are picked by whoever put the app there, not by us. So a release
    /// build does not search at all: it answers with the bundle, which makes the
    /// bundled-resource paths the only ones that resolve. Which core is run is
    /// decided separately, and more strictly, by
    /// `CoreProcess.resolveCoreDirectory`.
    static func repoRoot() -> URL {
        #if DEBUG
        // `Bundle.main.executableURL` comes from the kernel, unlike
        // `CommandLine.arguments[0]`, which is just whatever the launcher wrote.
        var directory = (Bundle.main.executableURL ?? URL(filePath: CommandLine.arguments[0]))
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
        for _ in 0..<8 {
            let marker = directory.appending(path: "core/package.json")
            if FileManager.default.fileExists(atPath: marker.path(percentEncoded: false)) {
                return directory
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        #endif
        return Bundle.main.bundleURL
    }
}

private extension LogLevel {
    var osLogType: OSLogType {
        switch self {
        case .debug: .debug
        case .info: .info
        case .warn: .default
        case .error: .error
        }
    }
}
