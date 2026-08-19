// akari 素材工具：用 Vision 人像分割把白底视频抠成带 alpha 的 HEVC .mov
// 用法: matte <输入.mp4> <输出.mov>
import AVFoundation
import Vision
import CoreImage
import VideoToolbox
import Foundation

let inURL  = URL(fileURLWithPath: CommandLine.arguments[1])
let outURL = URL(fileURLWithPath: CommandLine.arguments[2])
try? FileManager.default.removeItem(at: outURL)

let ciCtx = CIContext(options: [.useSoftwareRenderer: false])
let asset = AVURLAsset(url: inURL)
let sem = DispatchSemaphore(value: 0)

Task {
    do {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            print("没有视频轨"); sem.signal(); return
        }
        let size = try await track.load(.naturalSize)
        let fps  = try await track.load(.nominalFrameRate)
        let W = Int(size.width), H = Int(size.height)
        print("输入 \(W)x\(H) @ \(fps)fps")

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        reader.add(output)

        let writer = try AVAssetWriter(outputURL: outURL, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevcWithAlpha,
            AVVideoWidthKey: W,
            AVVideoHeightKey: H,
            AVVideoCompressionPropertiesKey: [
                kVTCompressionPropertyKey_TargetQualityForAlpha as String: 1.0,
                AVVideoQualityKey: 0.85
            ]
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: W,
                kCVPixelBufferHeightKey as String: H
            ])
        writer.add(input)

        reader.startReading()
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let req = VNGeneratePersonSegmentationRequest()
        req.qualityLevel = .accurate
        req.outputPixelFormat = kCVPixelFormatType_OneComponent8

        var n = 0
        let queue = DispatchQueue(label: "matte")
        input.requestMediaDataWhenReady(on: queue) {
            while input.isReadyForMoreMediaData {
                guard let sbuf = output.copyNextSampleBuffer(),
                      let pbuf = CMSampleBufferGetImageBuffer(sbuf) else {
                    input.markAsFinished()
                    writer.finishWriting {
                        print("完成，共 \(n) 帧 → \(outURL.lastPathComponent)")
                        sem.signal()
                    }
                    return
                }
                let t = CMSampleBufferGetPresentationTimeStamp(sbuf)
                let handler = VNImageRequestHandler(cvPixelBuffer: pbuf, options: [:])
                var masked: CVPixelBuffer? = nil
                do {
                    try handler.perform([req])
                    if let mask = (req.results?.first)?.pixelBuffer {
                        let src  = CIImage(cvPixelBuffer: pbuf)
                        var mimg = CIImage(cvPixelBuffer: mask)
                        // mask 分辨率与原帧不同，缩放对齐
                        let sx = src.extent.width  / mimg.extent.width
                        let sy = src.extent.height / mimg.extent.height
                        mimg = mimg.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
                        // 用 mask 当 alpha：blendWithMask(前景=原帧, 背景=全透明)
                        let clear = CIImage(color: .clear).cropped(to: src.extent)
                        let out = src.applyingFilter("CIBlendWithMask", parameters: [
                            kCIInputBackgroundImageKey: clear,
                            kCIInputMaskImageKey: mimg
                        ])
                        var newBuf: CVPixelBuffer? = nil
                        CVPixelBufferCreate(nil, W, H, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &newBuf)
                        if let nb = newBuf {
                            ciCtx.render(out, to: nb)
                            masked = nb
                        }
                    }
                } catch { print("第 \(n) 帧分割失败: \(error)") }
                if let m = masked { adaptor.append(m, withPresentationTime: t) }
                else { adaptor.append(pbuf, withPresentationTime: t) }
                n += 1
            }
        }
    } catch { print("错误: \(error)"); sem.signal() }
}
sem.wait()
