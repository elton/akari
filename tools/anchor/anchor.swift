// akari asset tool: measure where the character actually sits inside each clip.
//
// Clips do not share a canvas ratio, and even clips that do share one frame the
// character at different sizes, because the stills they came from were composed
// differently. Aligning clips by canvas makes her jump in size on every state
// change. Aligning by the character's own bounding box does not.
//
// This walks the alpha channel of every frame and takes the UNION of the per-frame
// bounding boxes — the union, not the first frame, because gestures (a raised hand,
// drifting hair) push the silhouette outward partway through a clip. The union is
// the box that is guaranteed to contain her at every instant.
//
// Output is a manifest the player reads at load time.
//
// Usage: anchor <out.json> <clip.mov> [clip.mov ...]

import AVFoundation
import CoreImage
import Foundation

struct ClipAnchor: Codable {
    let name: String
    let file: String
    let canvasWidth: Int
    let canvasHeight: Int
    /// Union of per-frame alpha bounding boxes, in pixels, origin top-left.
    let boxX: Int
    let boxY: Int
    let boxWidth: Int
    let boxHeight: Int
    let frameCount: Int
    let duration: Double
    let fps: Double
}

struct Manifest: Codable {
    let version: Int
    let clips: [ClipAnchor]
}

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("usage: anchor <out.json> <clip.mov> [clip.mov ...]\n".data(using: .utf8)!)
    exit(2)
}
let outPath = args[1]
let clipPaths = Array(args.dropFirst(2))

let ciCtx = CIContext(options: [.useSoftwareRenderer: false])
let sem = DispatchSemaphore(value: 0)
var anchors: [ClipAnchor] = []

/// Scan one frame's alpha channel and return its tight bounding box, or nil if fully transparent.
/// Works on a downscaled copy: we only need the box, and full-res scanning of every frame is wasteful.
func alphaBox(_ pixelBuffer: CVPixelBuffer, scale: Int) -> (Int, Int, Int, Int)? {
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
    let w = CVPixelBufferGetWidth(pixelBuffer)
    let h = CVPixelBufferGetHeight(pixelBuffer)
    let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
    let ptr = base.assumingMemoryBound(to: UInt8.self)

    var minX = w, minY = h, maxX = -1, maxY = -1
    // BGRA: alpha is byte 3. Threshold at 8/255 to ignore matting noise at the edges.
    var y = 0
    while y < h {
        let row = ptr + y * stride
        var x = 0
        while x < w {
            if row[x * 4 + 3] > 8 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
            x += scale
        }
        y += scale
    }
    guard maxX >= 0 else { return nil }
    return (minX, minY, maxX - minX + 1, maxY - minY + 1)
}

Task {
    for path in clipPaths {
        let url = URL(fileURLWithPath: path)
        let name = url.deletingPathExtension().lastPathComponent
        do {
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                FileHandle.standardError.write("\(name): no video track\n".data(using: .utf8)!)
                continue
            }
            let size = try await track.load(.naturalSize)
            let fps = try await track.load(.nominalFrameRate)
            let dur = try await asset.load(.duration)
            let W = Int(size.width), H = Int(size.height)

            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ])
            reader.add(output)
            reader.startReading()

            var uMinX = W, uMinY = H, uMaxX = -1, uMaxY = -1
            var frames = 0
            while let sbuf = output.copyNextSampleBuffer() {
                defer { frames += 1 }
                guard let pbuf = CMSampleBufferGetImageBuffer(sbuf) else { continue }
                // Sample every 2nd pixel; the box only needs to be accurate to ~2px.
                guard let (bx, by, bw, bh) = alphaBox(pbuf, scale: 2) else { continue }
                if bx < uMinX { uMinX = bx }
                if by < uMinY { uMinY = by }
                if bx + bw - 1 > uMaxX { uMaxX = bx + bw - 1 }
                if by + bh - 1 > uMaxY { uMaxY = by + bh - 1 }
            }
            guard uMaxX >= 0 else {
                FileHandle.standardError.write("\(name): every frame is fully transparent\n".data(using: .utf8)!)
                continue
            }
            anchors.append(ClipAnchor(
                name: name, file: url.lastPathComponent,
                canvasWidth: W, canvasHeight: H,
                boxX: uMinX, boxY: uMinY,
                boxWidth: uMaxX - uMinX + 1, boxHeight: uMaxY - uMinY + 1,
                frameCount: frames,
                duration: CMTimeGetSeconds(dur),
                fps: Double(fps)))
            let bw = uMaxX - uMinX + 1, bh = uMaxY - uMinY + 1
            print(String(format: "%-12s %4dx%-5d  box (%d,%d,%d,%d)  height %.3f of canvas  %d frames",
                         (name as NSString).utf8String!, W, H, uMinX, uMinY, bw, bh,
                         Double(bh) / Double(H), frames))
        } catch {
            FileHandle.standardError.write("\(name): \(error)\n".data(using: .utf8)!)
        }
    }

    // Report the scale each clip needs so the character renders at a consistent height.
    if let tallest = anchors.max(by: { $0.boxHeight < $1.boxHeight }) {
        print("\nTo render her at a consistent size, scale each clip by (relative to \(tallest.name)):")
        for a in anchors {
            let s = Double(tallest.boxHeight) / Double(a.boxHeight)
            print(String(format: "  %-12s %.4f×", (a.name as NSString).utf8String!, s))
        }
    }

    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try! enc.encode(Manifest(version: 1, clips: anchors))
    try! data.write(to: URL(fileURLWithPath: outPath))
    print("\nwrote \(outPath)")
    sem.signal()
}
sem.wait()
