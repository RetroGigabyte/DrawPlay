import CoreMedia
import CoreVideo
import Foundation

/// `drawplayd --probe-encode --quality high [--noise]`: feeds 4 seconds of 60 fps video to the encoder in real time and
/// reports the bitrate it produced and the time it needs per frame. Default content is a scrolling page of text beside a
/// photo-like area (heavy but realistic); `--noise` is the impossible worst case. Needs no permissions.
public enum EncoderProbe {
    public static func run(quality: VideoQuality, width: Int, height: Int, noise: Bool, video: Bool = false) -> String {
        let fps = 60, frames = 240
        let target = Int(Double(width * height * fps) * quality.bitsPerPixel)
        guard let enc = Encoder(width: width, height: height, fps: fps, bitrate: target) else { return "could not create the encoder" }
        var bytes = 0, out = 0
        let lock = NSLock()
        enc.onOutput = { type, data in lock.lock(); if type != 1 { bytes += data.count; out += 1 }; lock.unlock() }

        // One tall image of content; each frame is a window onto it, 8 pixels further down (a scroll).
        let tall = height + frames * 8 + 64
        var luma = [UInt8](repeating: 235, count: width * tall)
        var seed = UInt64(0x9E3779B97F4A7C15)
        func rnd() -> UInt64 { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return seed >> 33 }
        let textWidth = (noise || video) ? 0 : Int(Double(width) * 0.7)
        if video {          // smooth shapes plus film grain over the whole frame, panning 24 px per frame
            for y in 0..<tall { for x in 0..<width {
                let shape = 128.0 + 60.0 * sin(Double(x) / 90.0) * cos(Double(y) / 70.0) + 30.0 * sin(Double(x + y) / 23.0)
                luma[y * width + x] = UInt8(max(16, min(235, shape + Double(rnd() % 17) - 8)))
            } }
        } else if noise { for i in 0..<luma.count { luma[i] = UInt8(truncatingIfNeeded: rnd()) } }
        else {
            for band in stride(from: 0, to: tall - 24, by: 24) {
                for cell in stride(from: 8, to: textWidth - 12, by: 12) where rnd() % 100 > 15 {      // a glyph: 7 x 11 random strokes
                    for gy in 0..<11 { for gx in 0..<7 where rnd() % 100 < 45 { luma[(band + 6 + gy) * width + cell + gx] = 20 } }
                }
            }
            for y in 0..<tall { for x in textWidth..<width {                                          // photo-like: smooth gradient + fine grain
                luma[y * width + x] = UInt8(truncatingIfNeeded: 40 + (x - textWidth) * 150 / max(1, width - textWidth) + (y / 6) % 60 + Int(rnd() % 7))
            } }
        }

        func makeFrame(_ n: Int) -> CVPixelBuffer? {
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &pb)
            guard let b = pb else { return nil }
            CVPixelBufferLockBaseAddress(b, [])
            let y = CVPixelBufferGetBaseAddressOfPlane(b, 0)!.assumingMemoryBound(to: UInt8.self)
            let yStride = CVPixelBufferGetBytesPerRowOfPlane(b, 0)
            luma.withUnsafeBufferPointer { src in
                for row in 0..<height { let off = video ? (n * 24) % 300 : n * 8
                    memcpy(y + row * yStride, src.baseAddress! + (row + (video ? 0 : off)) * width + (video ? off : 0), width - (video ? 300 : 0)) }
            }
            let uv = CVPixelBufferGetBaseAddressOfPlane(b, 1)!
            memset(uv, 128, CVPixelBufferGetBytesPerRowOfPlane(b, 1) * CVPixelBufferGetHeightOfPlane(b, 1))
            CVPixelBufferUnlockBaseAddress(b, [])
            return b
        }

        let t0 = Date()
        for i in 0..<frames {
            guard let f = makeFrame(i) else { return "could not make a test frame" }
            enc.encode(f)
            let due = t0.addingTimeInterval(Double(i + 1) / Double(fps))
            if due > Date() { Thread.sleep(forTimeInterval: due.timeIntervalSinceNow) }       // real-time pace
        }
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline { lock.lock(); let n = out; lock.unlock(); if n >= frames { break }; Thread.sleep(forTimeInterval: 0.02) }
        lock.lock(); let total = bytes, got = out; lock.unlock()
        let mbps = Double(total) * 8 / (Double(max(got, 1)) / Double(fps)) / 1_000_000
        return String(format: "%@ (%@): target %.1f Mbit/s, produced %.1f Mbit/s, %d of %d frames out, %.1f ms per frame (budget 16.7)",
                      quality.label, noise ? "noise" : (video ? "video-like" : "text + photo"), Double(target) / 1_000_000, mbps, got, frames, enc.encodeMs)
    }
}
