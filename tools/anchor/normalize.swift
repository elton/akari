// akari asset tool: rewrite every clip so the character is the same size in all of them.
//
// The problem: clips come from stills that were composed differently, so she is framed
// at different sizes even when the canvases match. Switching state then makes her visibly
// jump. Fixing this in the player means every consumer has to carry the correction; fixing
// it in the assets means the player just plays them.
//
// Why align on the FACE and not the alpha bounding box: the bounding box is polluted by
// gesture. In `greeting` she raises a hand, which widens the box and can raise its top edge;
// in `idle` her arms sit low. The face is the one landmark that is present, complete and
// stable in every clip — and it is also what the eye actually tracks, so matching face size
// is what "she doesn't jump" really means perceptually.
//
// Detection runs over sampled frames and takes the MEDIAN, not a single frame: the detector
// wobbles by a pixel or two between frames, and a single-frame reading would bake that
// jitter into a permanent scale factor.
//
// Usage: normalize <out-dir> <clip.mov> [clip.mov ...]

import AVFoundation
import CoreImage
import Foundation
import Vision

struct FaceMetrics {
    let path: String
    let name: String
    let canvas: CGSize
    /// Median face rect across sampled frames, pixels, origin top-left.
    let face: CGRect
    let samples: Int
    let fps: Float
}

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("usage: normalize <out-dir> <clip.mov> [clip.mov ...]\n".data(using: .utf8)!)
    exit(2)
}
let outDir = URL(fileURLWithPath: args[1], isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let clips = Array(args.dropFirst(2))

let sem = DispatchSemaphore(value: 0)

func median(_ xs: [CGFloat]) -> CGFloat {
    guard !xs.isEmpty else { return 0 }
    let s = xs.sorted()
    return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
}

func measureFace(_ path: String) async throws -> FaceMetrics? {
    let url = URL(fileURLWithPath: path)
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }
    let size = try await track.load(.naturalSize)
    let fps = try await track.load(.nominalFrameRate)

    let reader = try AVAssetReader(asset: asset)
    let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ])
    reader.add(out)
    reader.startReading()

    var xs: [CGFloat] = [], ys: [CGFloat] = [], ws: [CGFloat] = [], hs: [CGFloat] = []
    var idx = 0
    let req = VNDetectFaceRectanglesRequest()
    while let sbuf = out.copyNextSampleBuffer() {
        defer { idx += 1 }
        // Sample ~12 frames spread across the clip; detection is the expensive part.
        guard idx % 20 == 0, let pbuf = CMSampleBufferGetImageBuffer(sbuf) else { continue }
        let handler = VNImageRequestHandler(cvPixelBuffer: pbuf, options: [:])
        try? handler.perform([req])
        guard let f = (req.results?.first) else { continue }
        // Vision returns normalised coords with origin bottom-left; convert to top-left pixels.
        let bb = f.boundingBox
        xs.append(bb.origin.x * size.width)
        ys.append((1 - bb.origin.y - bb.height) * size.height)
        ws.append(bb.width * size.width)
        hs.append(bb.height * size.height)
    }
    guard !hs.isEmpty else { return nil }
    return FaceMetrics(
        path: path,
        name: url.deletingPathExtension().lastPathComponent,
        canvas: size,
        face: CGRect(x: median(xs), y: median(ys), width: median(ws), height: median(hs)),
        samples: hs.count,
        fps: fps)
}

Task {
    var metrics: [FaceMetrics] = []
    for c in clips {
        do {
            if let m = try await measureFace(c) {
                metrics.append(m)
                print(String(format: "%-12s canvas %4.0fx%-5.0f  face %.0fx%.0f at (%.0f,%.0f)  %d samples",
                             (m.name as NSString).utf8String!, m.canvas.width, m.canvas.height,
                             m.face.width, m.face.height, m.face.origin.x, m.face.origin.y, m.samples))
            } else {
                FileHandle.standardError.write("\(c): no face detected\n".data(using: .utf8)!)
            }
        } catch {
            FileHandle.standardError.write("\(c): \(error)\n".data(using: .utf8)!)
        }
    }
    guard !metrics.isEmpty else { sem.signal(); return }

    // Target: the SMALLEST face becomes the reference, so every other clip is scaled DOWN.
    // Scaling down only discards detail; scaling up would invent it and soften those clips.
    let ref = metrics.min(by: { $0.face.height < $1.face.height })!
    // Output canvas: 3:4 at 1080 tall, the ratio the stills were generated at.
    let outW = 810.0, outH = 1080.0
    // Put the face centre at a fixed spot in the output frame, taken from the reference clip.
    let refCX = ref.face.midX / ref.canvas.width
    let refCY = ref.face.midY / ref.canvas.height

    print(String(format: "\nreference: %s (smallest face, %.0fpx tall)", (ref.name as NSString).utf8String!, ref.face.height))
    print(String(format: "output canvas %.0fx%.0f, face centre pinned at (%.3f, %.3f)\n", outW, outH, refCX, refCY))

    print("ffmpeg plan:")
    for m in metrics {
        let s = ref.face.height / m.face.height          // scale so faces match
        let sw = m.canvas.width * s, sh = m.canvas.height * s
        // After scaling, translate so this clip's face centre lands on the pinned point.
        let faceCX = m.face.midX * s, faceCY = m.face.midY * s
        let dx = outW * refCX - faceCX
        let dy = outH * refCY - faceCY
        print(String(format: "  %-12s scale %.4f× → %.0fx%.0f, offset (%.0f, %.0f)",
                     (m.name as NSString).utf8String!, s, sw, sh, dx, dy))

        let outPath = outDir.appendingPathComponent(m.name + ".mov").path
        // Composite the scaled clip onto a transparent canvas at the computed offset.
        // overlay is used rather than pad because the offset is frequently NEGATIVE — the
        // clip must be shifted up/left so its face lands on the pinned point, which means
        // cropping off part of the source. pad cannot express that and silently clamps to 0,
        // leaving those clips misaligned.
        // format=rgba keeps alpha through the chain; hevc_videotoolbox with alpha_quality 1.0
        // writes it back out (0.1 would wreck hair edges — see tools/matte).
        // NOTE: two traps in this one filter graph, both silent.
        // 1. The transparent background must be an UNBOUNDED source. Giving it a duration
        //    (d=1) together with overlay's shortest=1 truncates the clip to that duration —
        //    it cut 251-frame clips down to 25 frames.
        // 2. The background must carry the input's frame rate (r=). color defaults to 25fps
        //    and overlay adopts it, silently downsampling 30fps clips to 25fps.
        let fc = String(format:
            "color=c=0x000000@0.0:s=%dx%d:r=%d,format=rgba[bg];" +
            "[0:v]scale=%d:%d,format=rgba[fg];" +
            "[bg][fg]overlay=%d:%d:format=auto:shortest=1,format=rgba",
            Int(outW), Int(outH), Int(m.fps.rounded()),
            Int(sw.rounded()), Int(sh.rounded()),
            Int(dx.rounded()), Int(dy.rounded()))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        p.arguments = ["-v", "error", "-i", m.path,
                       "-filter_complex", fc,
                       "-c:v", "hevc_videotoolbox", "-alpha_quality", "1.0", "-q:v", "70",
                       "-tag:v", "hvc1", "-an", outPath, "-y"]
        try? p.run()
        p.waitUntilExit()
        print("      → \(outPath) (exit \(p.terminationStatus))")
    }
    sem.signal()
}
sem.wait()
