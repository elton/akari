import AVFoundation
import Foundation
import Testing

@testable import AkariApp

/// Writes a tiny silent H.264 movie so the player has two *distinct* clips to
/// choose between. The real assets are HEVC-with-alpha, but nothing under test
/// here cares about the codec — only about which file ends up in front.
private func writeClip(to url: URL, gray: UInt8) async throws {
    let size = 64
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: size,
        AVVideoHeightKey: size,
    ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)

    for frame in 0..<12 {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, size, size, kCVPixelFormatType_32BGRA, nil, &buffer)
        let pixels = buffer!
        CVPixelBufferLockBaseAddress(pixels, [])
        memset(CVPixelBufferGetBaseAddress(pixels), Int32(gray),
               CVPixelBufferGetBytesPerRow(pixels) * size)
        CVPixelBufferUnlockBaseAddress(pixels, [])
        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
        adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 12))
    }
    input.markAsFinished()
    await writer.finishWriting()
}

/// `idle.mov` and `talking.mov`, deliberately different files so a fallback
/// cannot mask which one is on screen.
private func makeClipDirectory() async throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "akari-avatar-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try await writeClip(to: directory.appending(path: "idle.mov"), gray: 40)
    try await writeClip(to: directory.appending(path: "talking.mov"), gray: 200)
    return directory
}

@MainActor
private func waitForFront(_ player: AvatarPlayer, toBe url: URL, timeout: Duration = .seconds(3)) async {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if player.frontClipURL == url { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
}

/// Regression: `transition(to:)` used to take a shortcut when the requested loop
/// was already in front, without cancelling a transition that was still waiting
/// for its decoder. The superseded clip then dissolved in anyway and looped —
/// "she keeps talking to herself" after the user has already interrupted.
@Test @MainActor func interruptedTransitionDoesNotLandLater() async throws {
    let directory = try await makeClipDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let idle = directory.appending(path: "idle.mov")

    let player = AvatarPlayer(assetDirectory: directory)
    try player.preload()
    await waitForFront(player, toBe: idle)
    #expect(player.frontClipURL == idle)

    // core: talking → (decoder still warming up) → user interrupts → core: idle
    player.transition(to: .talking)
    player.transition(to: .idle)

    // Long enough for the readiness poll, its 250ms timeout, and the dissolve.
    try await Task.sleep(for: .milliseconds(800))
    #expect(player.state == .idle)
    #expect(player.frontClipURL == idle, "superseded talking.mov dissolved in after the interrupt")
}

/// The shortcut itself must survive: repeating a state the player is already
/// showing is a legal no-op (protocol.md §3.2) and must not restart the clip.
@Test @MainActor func repeatedStateKeepsTheSameClipPlaying() async throws {
    let directory = try await makeClipDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let idle = directory.appending(path: "idle.mov")

    let player = AvatarPlayer(assetDirectory: directory)
    try player.preload()
    await waitForFront(player, toBe: idle)

    player.transition(to: .idle)
    try await Task.sleep(for: .milliseconds(100))
    #expect(player.frontClipURL == idle)
}
