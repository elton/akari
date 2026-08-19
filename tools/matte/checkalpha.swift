import AVFoundation
import Foundation

let path = CommandLine.arguments[1]
let asset = AVURLAsset(url: URL(fileURLWithPath: path))
let sem = DispatchSemaphore(value: 0)

Task {
    do {
        let tracks = try await asset.loadTracks(withMediaCharacteristic: .containsAlphaChannel)
        let vtracks = try await asset.loadTracks(withMediaType: .video)
        print("视频轨数量: \(vtracks.count)")
        print("带 alpha 的轨数量: \(tracks.count)")
        if let t = vtracks.first {
            let size = try await t.load(.naturalSize)
            let fps  = try await t.load(.nominalFrameRate)
            print("尺寸: \(Int(size.width))x\(Int(size.height))   帧率: \(fps)")
        }
        print(tracks.isEmpty
              ? "❌ AVFoundation 判定：不含 alpha 通道"
              : "✅ AVFoundation 判定：含 alpha 通道，可直接用 AVPlayerLayer 透明合成")
    } catch { print("错误: \(error)") }
    sem.signal()
}
sem.wait()
