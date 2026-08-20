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
    /// Built before `settings` because the store takes it: the 形象 section's
    /// wallpaper switch has to be able to reach the real desktop, and the store
    /// is what the switch talks to.
    private lazy var wallpaper = WallpaperController(directory: WallpaperCatalog.defaultDirectory())
    private lazy var settings = SettingsStore(wallpaper: wallpaper)
    private lazy var settingsWindow = SettingsWindowController(store: settings)

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
        wireSettings()
        wireMenu()
        wireHotkey()
        wireAudio()
        wireBridge()

        windows.start()
        // Only two Bools cross this line on purpose (Wallpaper.swift): the
        // module needs "the switch is on" and "the question was answered", and
        // nothing else. A missing artwork file logs and leaves the desktop alone.
        wallpaper.applyAtLaunch(enabled: settings.avatar.wallpaperEnabled,
                                consented: settings.avatar.wallpaperConsented)
        requestMicrophoneAccessAtLaunch()
        // Deferred one runloop turn past `applicationDidFinishLaunching`.
        // Ordering a window to the front from inside launch does not survive:
        // measured on macOS 26, the settings window and its onboarding sheet
        // came up behind the app that was frontmost even with
        // `orderFrontRegardless()`, because the launch itself reorders after
        // this method returns. Running it after that is what makes it stick.
        Task { @MainActor in self.presentFirstRunOnboardingIfNeeded() }

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
        menu.onOpenSettings = { [weak self] in
            self?.settingsWindow.show()
        }
        menu.onTalkPressed = { [weak self] in self?.beginTurn(source: .menu) }
        menu.onTalkReleased = { [weak self] in self?.endTurn(source: .menu) }
    }

    private func wireSettings() {
        settings.send = { [weak self] message in
            try? self?.bridge.send(message)
        }

        // The 形象 section edits exactly the value the window controller takes,
        // so this is an assignment and not a translation. Once here for what was
        // persisted, then on every accepted change — `onAvatarSettingsChanged`
        // deliberately does not fire at construction time.
        //
        // Assigned before `windows.start()`, so the first windows are built in
        // the mode the user last chose instead of appearing on the desktop layer
        // and jumping.
        windows.presentation = settings.avatar.presentation
        settings.onAvatarSettingsChanged = { [weak self] value in
            self?.windows.presentation = value.presentation
        }
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
            settings.coreConnected()
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
            settings.coreDisconnected()
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

        case .settingsState, .settingsProbeResult:
            settings.handle(message)

        case .credentialsRequest(let payload):
            // The one frame that carries a secret (protocol.md §3.10). It goes
            // out on this connection and no other: `bridge` only ever dials the
            // socket `SocketTrust` approved, which is rule 3 of that section.
            // Nothing here logs the answer — the payload types print themselves
            // without the values, and this line does not print them either.
            let answer = settings.answer(payload)
            try? bridge.send(ControlMessage(body: .credentialsProvide(answer),
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
        // The core may specify a duration; when it does not, the length is decided
        // by what the transition means (AvatarPlayer.defaultDuration), not by one
        // constant for every state.
        let duration = transitionMs.map { Double($0) / 1000.0 }
            ?? AvatarPlayer.defaultDuration(to: state)
        for player in players.values {
            player.transition(to: state, duration: duration)
        }
    }

    // MARK: - Microphone

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

    // MARK: - First run

    /// ADR-009 accepted "the user configures two sets of credentials" on exactly
    /// one condition, and this is it: 「首启引导需要把这件事讲清楚，不能让用户以为
    /// 配一个就能用」.
    ///
    /// Without it a user with nothing configured is told nothing. The only
    /// feedback that exists is a `ui.notice` for the missing DashScope key, and
    /// `MenuBarController.showNotice` writes that into a menu item and paints the
    /// connection status back over it five seconds later — invisible unless the
    /// menu happens to be open at that moment. The Cloudflare half produces no
    /// notice at all, so the text route can be dead with nothing on screen
    /// anywhere saying why.
    ///
    /// This runs after the microphone prompt is asked for, not before: TCC's
    /// alert is the one thing that must not queue behind a window of ours.
    private func presentFirstRunOnboardingIfNeeded() {
        guard FirstRunOnboarding.shouldPresent(defaults: .standard, rows: settings.rows) else {
            return
        }
        appLog.info("first run: no credentials in the keychain, opening settings")

        // The explanation goes *inside* the window, and the window is raised
        // above every other application until the user dismisses it.
        //
        // Both halves were forced by measurement on a real first launch:
        //
        // - An `LSUIElement` app does not get activation it did not earn by
        //   being clicked on. Neither `NSApp.activate()`, nor
        //   `orderFrontRegardless()`, nor promoting to `.regular` with
        //   `setActivationPolicy`, nor any of them a runloop turn later, put
        //   this window in front of the browser that happened to be frontmost.
        //   All were tried; all left it buried while the "already shown"
        //   preference was spent anyway, so the user was never going to see the
        //   explanation on this launch or any other. A raised window level is
        //   the one thing the window server honours from a background app.
        // - The explanation is therefore a banner in the window rather than the
        //   `NSAlert` sheet this started as. Nothing has to be reconciled with
        //   the raised window level, and it reads better anyway: it sits above
        //   the very fields it is telling the user to fill in, instead of
        //   covering them.
        settings.onOnboardingDismissed = { [weak self] in
            self?.settingsWindow.window?.level = .normal
            FirstRunOnboarding.markPresented(defaults: .standard)
            appLog.info("first run: onboarding dismissed")
        }
        settings.presentOnboarding(FirstRunOnboarding.text)
        let window = settingsWindow.prepareWindow()
        window.level = .floating
        settingsWindow.show()
        // Recorded on dismissal, not here. Recording it first was the safer
        // looking order — it cannot loop — but it is what made the failure above
        // permanent: nobody saw the explanation and the flag said it had been
        // given. Dismissal is the only evidence it reached anyone, and a launch
        // that explains itself twice is much the cheaper of the two failures.
    }

    // MARK: - Push to talk

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

/// The first-run explanation, as the settings window renders it.
struct FirstRunOnboardingText: Equatable {
    let title: String
    let body: String
    let dismissTitle: String
}

/// Whether this launch is the one that has to explain the two-credential split.
///
/// A separate type so the decision is testable without a window, a Keychain or a
/// launch — the AppDelegate keeps only the part that puts it on screen.
enum FirstRunOnboarding {
    /// An explicit preference, deliberately **not** "does a `.env` exist".
    /// Every development checkout has one, so that test would silence the
    /// onboarding precisely on the machines where it is being written, and leave
    /// it unexercised until a real user hit it.
    static let defaultsKey = "akari.onboardingShown"

    static func shouldPresent(defaults: UserDefaults, rows: [CredentialRow]) -> Bool {
        if defaults.bool(forKey: defaultsKey) { return false }
        return !hasAnyStoredCredential(rows)
    }

    static func markPresented(defaults: UserDefaults) {
        defaults.set(true, forKey: defaultsKey)
    }

    /// Only what the app can see in its own Keychain counts.
    ///
    /// `.denied` counts as "configured" even though no value came back: a
    /// Keychain that would not open is *cannot tell*, not *nothing there*, and
    /// interrupting someone whose Keychain is merely locked is worse than
    /// staying quiet — the settings window is one menu click away either way.
    ///
    /// A `.env` deliberately does not count. The core reads it and the settings
    /// window offers to import from it, but it belongs to whoever built the
    /// checkout, not to the person launching the app.
    static func hasAnyStoredCredential(_ rows: [CredentialRow]) -> Bool {
        rows.contains { row in
            switch row.stored {
            case .set, .denied: true
            case .unset, .cleared: false
            }
        }
    }

    static var text: FirstRunOnboardingText {
        FirstRunOnboardingText(title: title, body: explanation, dismissTitle: "知道了，去填")
    }

    static let title = "akari 要两套凭据，各管一半"

    /// Says the thing ADR-009 promised would be said: one is not enough, and
    /// which half stops working without which key.
    static let explanation = """
        语音和文本走的是两个不同的服务，配好一个不代表另一个能用 —— 得各配各的。

        · 语音对话 —— 阿里云百炼 DashScope 的 API Key。
          没有它，说话不会有回应。（选它是因为只有它把 VAD 和打断放在服务端做，实测首个音频包 473ms。）

        · 文本与看截图 —— 你自己的 Cloudflare 账号 ID 和 API Token，
          token 必须给 Workers AI「编辑」权限：只给「读取」时能列出模型、跑推理会 403。
          用你自己的账号，是为了不把作者的凭据打包进应用里。

        · 本地模型是断网或额度用尽时的兜底，要先下 22.8 GB 权重，可以以后再说。

        每一组下面都有「保存并测试」，填完当场就知道通不通。
        """
}
