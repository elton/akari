import AVFoundation
import QuartzCore
import os

private let avatarLog = Logger(subsystem: "me.eltonzheng.akari", category: "avatar")

/// Unified logging plus stderr: `swift run` shows stderr, Console shows the log,
/// and a broken asset is exactly the thing that must not fail silently.
private func avatarWarn(_ message: String) {
    avatarLog.warning("\(message, privacy: .public)")
    FileHandle.standardError.write(Data("akari[avatar] warning: \(message)\n".utf8))
}

// MARK: - State traits

private extension AvatarState {
    /// `greeting` is a one-shot beat (wave, then hand back to the caller);
    /// every other state loops until the core says otherwise (avatar-states.md §1).
    var loops: Bool { self != .greeting }

    var clipFileName: String { "\(rawValue).mov" }
}

// MARK: - Root layer

/// Keeps both player layers stretched over the window. A plain `CALayer` does not
/// resize its sublayers, and the desktop windows are re-framed on every display
/// arrangement change.
private final class AvatarRootLayer: CALayer {
    /// Per-sublayer downward shift, as a fraction of the layer's height.
    ///
    /// The clips do not share where she sits inside their canvas: normalisation
    /// aligns her FACE across states (so she does not jump when the state changes),
    /// and because the states have different body lengths, aligning faces leaves
    /// different amounts of empty canvas under her — 1px in `idle` but 111px in
    /// `listening`. Rendering every clip flush to the window would leave her
    /// hovering in exactly those states.
    ///
    /// Face-alignment and bottom-alignment cannot both hold while body lengths
    /// differ; this shifts each clip down by its own gap so the bottom wins, and
    /// pays for it with up to ~60pt of face movement between states. A person
    /// shifting posture moves their head anyway; a person floating off the floor
    /// reads as broken.
    var bottomShift: [ObjectIdentifier: CGFloat] = [:] {
        didSet { setNeedsLayout() }
    }

    override func layoutSublayers() {
        super.layoutSublayers()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for sublayer in sublayers ?? [] {
            let shift = bottomShift[ObjectIdentifier(sublayer)] ?? 0
            // Layer coordinates are bottom-left origin here (the hosting view is
            // unflipped), so moving her down means lowering y.
            sublayer.frame = bounds.offsetBy(dx: 0, dy: -bounds.height * shift)
        }
        CATransaction.commit()
    }
}

// MARK: - One half of the cross-fade

/// A player plus the layer showing it. Two of these alternate; the visible one is
/// `front`, the one being loaded is `back`.
@MainActor
private final class AvatarSide {
    let player = AVQueuePlayer()
    let layer = AVPlayerLayer()

    /// Strong reference is required — the looper stops looping when released.
    private var looper: AVPlayerLooper?

    /// Clip currently loaded, so an identical transition can be skipped.
    private(set) var url: URL?
    private(set) var isOneShot = false

    init() {
        // The clips carry no audio track by design (avatar-states.md §2.2); muting
        // is belt-and-braces so a stray track can never be heard over her voice.
        player.isMuted = true
        // Local files: start on the first frame instead of buffering ahead.
        player.automaticallyWaitsToMinimizeStalling = false

        layer.player = player
        layer.videoGravity = .resizeAspect
        // The whole point of HEVC-with-alpha: no backdrop of our own.
        layer.isOpaque = false
        layer.backgroundColor = nil
        layer.opacity = 0
    }

    /// Stop decoding and drop the queue. Also the power-saving path: an idle side
    /// must not keep a decoder alive (RISK-2 measured 3.77% CPU vs 0.07% paused).
    func unload() {
        looper?.disableLooping()
        looper = nil
        player.pause()
        player.removeAllItems()
        url = nil
        isOneShot = false
    }

    func load(_ url: URL, oneShot: Bool) {
        unload()
        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        if oneShot {
            player.actionAtItemEnd = .pause
            player.insert(item, after: nil)
        } else {
            // AVPlayerLooper drives the queue; it needs `.advance`.
            player.actionAtItemEnd = .advance
            looper = AVPlayerLooper(player: player, templateItem: item)
        }
        self.url = url
        self.isOneShot = oneShot
    }
}

// MARK: - AvatarPlayer

/// Plays the pre-rendered HEVC-with-alpha loops and cross-fades between states.
///
/// Two `AVPlayerLayer`s alternate and the transition is an opacity animation:
/// `AVPlayerLooper` and `AVVideoComposition` are mutually exclusive, so a
/// composition-based dissolve would cost seamless looping (avatar-states.md §1).
///
/// One instance drives one `CALayer`, i.e. one display. A second display gets its
/// own instance — a `CALayer` has a single superlayer.
@MainActor
final class AvatarPlayer {

    /// Only failure that stops playback outright. A missing individual clip is a
    /// warning plus a fallback, never an error.
    enum AssetError: LocalizedError {
        case noClips(directory: URL)

        var errorDescription: String? {
            switch self {
            case .noClips(let directory):
                let expected = AvatarState.allCases.map(\.clipFileName).joined(separator: ", ")
                return "no avatar clip found in \(directory.path(percentEncoded: false)) "
                    + "(expected at least one of: \(expected))"
            }
        }
    }

    /// Layer to hand to a `DesktopWindow`. Holds both player layers.
    let rootLayer: CALayer

    /// Same object as `rootLayer`, typed so the per-clip bottom shift can be set.
    private let root: AvatarRootLayer

    private(set) var state: AvatarState = .idle

    /// Clip currently visible. Exposed for tests: `state` is set the moment a
    /// transition is *asked for*, so only this says what is actually on screen.
    var frontClipURL: URL? { front.url }

    /// Directory holding `<state>.mov`, i.e. `assets/akari/`.
    private let assetDirectory: URL

    /// Fires when a non-looping clip (e.g. `greeting`) reaches its end.
    var onClipFinished: ((AvatarState) -> Void)?

    /// Which clip stands in for a state whose own file is missing. Ordered by how
    /// little the substitution jars: a calm loop reads as generic, `greeting`
    /// (a wave) reads as wrong everywhere, so it goes last.
    private static let fallbackOrder: [AvatarState] = [.idle, .listening, .talking, .thinking, .greeting]

    /// How long to wait for the incoming decoder before dissolving anyway. Fading
    /// into a layer with no frames yet shows the desktop through her.
    private static let readinessTimeout: Duration = .milliseconds(250)

    /// Clip file name -> how far to shift it down, as a fraction of its height.
    ///
    /// Read from `anchors.json`, which `tools/anchor` writes next to the clips: it
    /// carries the union of her alpha bounding box across every frame, so the empty
    /// canvas beneath her is `canvasHeight - (boxY + boxHeight)`. Shifting by that
    /// fraction puts her feet on the window's bottom edge whichever state is playing.
    ///
    /// Absent or unreadable manifest means no shift — the clips still play, she just
    /// sits wherever the footage put her. Never an error: a missing manifest must not
    /// cost the user her presence on the desktop.
    private var bottomShiftByFile: [String: CGFloat] = [:]

    private var front = AvatarSide()
    private var back = AvatarSide()

    /// State -> clip actually used, after fallback resolution. Empty until `preload()`.
    private var resolvedClips: [AvatarState: URL] = [:]

    private var isPaused = false

    /// Bumped on every transition so late readiness/end callbacks from a superseded
    /// transition can be dropped.
    private var generation = 0

    /// Polls the incoming clip until it can be shown; cancelled by the next transition.
    private var readinessPoll: Task<Void, Never>?

    /// True between `back.load(...)` and the dissolve settling (committed or
    /// abandoned). Distinguishes "a clip is still on its way in" from "the last
    /// dissolve is merely still animating out", which need opposite handling when a
    /// transition is superseded.
    private var isTransitionPending = false

    /// `nonisolated(unsafe)` so `deinit` — which is not main-actor isolated — can
    /// unregister. Only ever touched on the main actor plus that one final read.
    private nonisolated(unsafe) var endObserver: (any NSObjectProtocol)?

    /// Decode `anchors.json` into per-clip bottom shifts. Best effort by design.
    private static func loadBottomShifts(in directory: URL) -> [String: CGFloat] {
        struct Manifest: Decodable {
            struct Clip: Decodable {
                let file: String
                let canvasHeight: Int
                let boxY: Int
                let boxHeight: Int
            }
            let clips: [Clip]
        }
        guard let data = try? Data(contentsOf: directory.appending(path: "anchors.json")),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else {
            return [:]
        }
        var shifts: [String: CGFloat] = [:]
        for clip in manifest.clips where clip.canvasHeight > 0 {
            let gap = clip.canvasHeight - (clip.boxY + clip.boxHeight)
            guard gap > 0 else { continue }
            shifts[clip.file] = CGFloat(gap) / CGFloat(clip.canvasHeight)
        }
        return shifts
    }

    init(assetDirectory: URL) {
        self.assetDirectory = assetDirectory
        let root = AvatarRootLayer()
        root.isOpaque = false
        root.backgroundColor = nil
        root.addSublayer(front.layer)
        root.addSublayer(back.layer)
        self.rootLayer = root
        self.root = root
        self.bottomShiftByFile = Self.loadBottomShifts(in: assetDirectory)
    }

    deinit {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    // MARK: Loading

    /// Resolve every state to a clip (falling back when a file is missing), show
    /// `idle`, and kick off alpha verification.
    ///
    /// `ffprobe` reports `yuv420p` for HEVC-with-alpha because alpha rides in an
    /// auxiliary picture layer; only AVFoundation's `.containsAlphaChannel` is
    /// authoritative (ADR-007). That check is async, so it runs in the background
    /// and reports as a warning — it must not delay the first frame.
    func preload() throws {
        let fileManager = FileManager.default
        var present: [AvatarState: URL] = [:]
        for state in AvatarState.allCases {
            let url = assetDirectory.appending(path: state.clipFileName)
            if fileManager.fileExists(atPath: url.path(percentEncoded: false)) {
                present[state] = url
            }
        }

        guard !present.isEmpty else { throw AssetError.noClips(directory: assetDirectory) }

        var resolved: [AvatarState: URL] = [:]
        for state in AvatarState.allCases {
            if let own = present[state] {
                resolved[state] = own
            } else if let standIn = Self.fallbackOrder.lazy.compactMap({ present[$0] }).first {
                resolved[state] = standIn
                avatarWarn("""
                    missing \(state.clipFileName) — falling back to \(standIn.lastPathComponent)
                    """)
            }
        }
        resolvedClips = resolved

        verifyAlpha(of: Array(Set(resolved.values)))

        // First frame with no dissolve; there is nothing to dissolve from.
        transition(to: state, duration: 0)
    }

    // MARK: Transitions

    /// How long the cross-fade into `state` should take when the core does not say.
    ///
    /// One value for every transition was wrong in both directions. The original
    /// 0.12s comes from spec.md's "3-5 frame dissolve", whose job is to *hide* the
    /// posture discontinuity between two clips — at 30fps it is under four frames,
    /// so nobody sees a transition at all. But simply making it longer hurts the one
    /// transition that must feel instant.
    ///
    /// So it is graded by what the change means to the person watching:
    ///   - `listening` answers a key press. Anything slow reads as "it didn't hear me".
    ///   - `talking` is her opening her mouth; a beat of ceremony suits it.
    ///   - `idle` is the wind-down after an answer. Nothing is waiting on it, and a
    ///     slow settle is what a person does when a conversation pauses.
    static func defaultDuration(to state: AvatarState) -> TimeInterval {
        switch state {
        case .listening: 0.18
        case .thinking:  0.25
        case .talking:   0.30
        case .greeting:  0.30
        case .idle:      0.50
        }
    }

    /// Cross-fade to `state`. Called on every `avatar.setState` control message.
    func transition(to newState: AvatarState, duration: TimeInterval? = nil) {
        let duration = duration ?? Self.defaultDuration(to: newState)
        guard let url = resolvedClips[newState] else {
            avatarWarn("transition to \(newState.rawValue) ignored: preload() has not resolved any clip")
            return
        }

        state = newState
        let oneShot = !newState.loops

        // Same looping clip already on screen — e.g. every state falls back to the
        // one asset we have. Restarting it would be a visible hitch for no gain.
        if !oneShot, front.url == url, !front.isOneShot {
            // ...but a *different* clip may still be on its way in: core said
            // `talking`, the decoder was still warming up, and 120ms later the user
            // interrupted and core said `idle`. Returning without cancelling would
            // let that pending dissolve land afterwards and loop `talking` forever —
            // the "she keeps talking to herself" break that ADR-004 exists to avoid.
            //
            // Only a *pending* transition is torn down. A dissolve that has already
            // committed is left to finish: its animation is what fades the previous
            // clip out, and its completion block is what unloads that decoder.
            if isTransitionPending { cancelPendingTransition() }
            if !isPaused, front.player.rate == 0 { front.player.play() }
            return
        }

        generation &+= 1
        let gen = generation
        readinessPoll?.cancel()
        readinessPoll = nil
        clearEndObserver()
        isTransitionPending = true

        // The back layer may still be animating out from a transition that was
        // superseded mid-fade; drop that animation before reusing it.
        back.layer.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        back.layer.opacity = 0
        back.layer.zPosition = 1
        front.layer.zPosition = 0
        CATransaction.commit()

        // Register the shift before loading so the first laid-out frame is already
        // in the right place — setting it afterwards would show one frame of her
        // hovering before it snapped down.
        root.bottomShift[ObjectIdentifier(back.layer)] = bottomShiftByFile[url.lastPathComponent] ?? 0
        back.load(url, oneShot: oneShot)
        if oneShot { installEndObserver(target: newState, generation: gen) }

        guard !isPaused else {
            // Invisible anyway: swap without burning a dissolve, stay stopped.
            commitDissolve(duration: 0, generation: gen)
            return
        }

        back.player.play()
        dissolveWhenReady(duration: duration, generation: gen)
    }

    /// Wait for the incoming clip to have frames, then dissolve.
    ///
    /// Polled rather than observed because there are two things to wait for and the
    /// first one has nothing to attach a KVO to: `AVPlayerLooper` fills the queue
    /// asynchronously, so `currentItem` is still nil right after `load(_:oneShot:)`,
    /// and only then does the item work its way to `.readyToPlay`. The whole wait is
    /// bounded by `readinessTimeout`, so a stalled decoder can never wedge the state
    /// machine.
    private func dissolveWhenReady(duration: TimeInterval, generation gen: Int) {
        readinessPoll?.cancel()
        readinessPoll = Task { @MainActor [weak self] in
            let deadline = ContinuousClock.now + Self.readinessTimeout
            while !Task.isCancelled {
                guard let self, gen == self.generation else { return }
                if let item = self.back.player.currentItem {
                    switch item.status {
                    case .readyToPlay:
                        self.commitDissolve(duration: duration, generation: gen)
                        return
                    case .failed:
                        // A clip that will not decode must not be dissolved to: the
                        // incoming layer is empty and she would vanish off the
                        // desktop. Keep showing whatever is already up.
                        self.abandonTransition(
                            gen: gen,
                            because: "clip failed to load: "
                                + (item.error?.localizedDescription ?? "unknown error"))
                        return
                    default:
                        break
                    }
                }
                if ContinuousClock.now >= deadline { break }
                try? await Task.sleep(for: .milliseconds(8))
            }
            guard let self, gen == self.generation else { return }
            guard self.back.player.currentItem != nil else {
                // Never enqueued: a corrupt asset takes AVPlayerLooper straight to
                // `.failed` and it drops every item it made.
                self.abandonTransition(gen: gen, because: "clip produced no playable item")
                return
            }
            avatarWarn("decoder still not ready after \(Self.readinessTimeout); dissolving anyway")
            self.commitDissolve(duration: duration, generation: gen)
        }
    }

    /// Drop a transition that has loaded a clip but not yet dissolved to it, so no
    /// late readiness callback can still bring that clip to the front.
    private func cancelPendingTransition() {
        readinessPoll?.cancel()
        readinessPoll = nil
        // Bumping the generation is what makes the in-flight poll — and any end
        // observer it installed — a no-op if it wakes up after this point.
        generation &+= 1
        isTransitionPending = false
        clearEndObserver()
        back.unload()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        back.layer.opacity = 0
        CATransaction.commit()
    }

    /// Give up on the incoming clip and leave the current one on screen.
    private func abandonTransition(gen: Int, because reason: String) {
        guard gen == generation else { return }
        avatarWarn("\(reason) — staying on \(front.url?.lastPathComponent ?? "nothing")")
        isTransitionPending = false
        readinessPoll = nil
        clearEndObserver()
        back.unload()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        back.layer.opacity = 0
        CATransaction.commit()
    }

    /// Animate the opacity swap and hand the roles over. The outgoing side is torn
    /// down when the animation lands, which is also what stops it decoding.
    private func commitDissolve(duration: TimeInterval, generation gen: Int) {
        guard gen == generation else { return }
        isTransitionPending = false
        readinessPoll = nil

        let incoming = back
        let outgoing = front

        CATransaction.begin()
        CATransaction.setAnimationDuration(max(0, duration))
        CATransaction.setDisableActions(duration <= 0)
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, gen == self.generation else { return }
                outgoing.unload()
            }
        }
        incoming.layer.opacity = 1
        outgoing.layer.opacity = 0
        CATransaction.commit()

        front = incoming
        back = outgoing
    }

    // MARK: End of a one-shot clip

    private func installEndObserver(target: AvatarState, generation gen: Int) {
        guard let item = back.player.currentItem else { return }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, gen == self.generation else { return }
                self.onClipFinished?(target)
            }
        }
    }

    private func clearEndObserver() {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
    }

    // MARK: Power

    /// Stop decoding entirely (occluded, screen locked, on battery).
    func pause() {
        isPaused = true
        front.player.pause()
        back.player.pause()
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        front.player.play()
    }

    // MARK: Alpha verification

    private func verifyAlpha(of urls: [URL]) {
        Task.detached(priority: .utility) {
            for url in urls {
                do {
                    let asset = AVURLAsset(url: url)
                    let alphaTracks = try await asset.loadTracks(withMediaCharacteristic: .containsAlphaChannel)
                    if alphaTracks.isEmpty {
                        avatarWarn("""
                            \(url.lastPathComponent) has no alpha channel — she will be drawn on an \
                            opaque rectangle. Re-encode it with tools/matte.
                            """)
                    }
                } catch {
                    avatarWarn("could not inspect \(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
    }
}
