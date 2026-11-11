import CoreMedia
import Foundation
import ScreenCaptureKit

/// Captures one display with ScreenCaptureKit as NV12 frames.
final class Capture: NSObject, SCStreamOutput {
    var onFrame: ((CVPixelBuffer) -> Void)?
    private var stream: SCStream?

    func start(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int) async throws {
        var found: SCDisplay?
        for _ in 0..<20 {   // the new virtual display can take a moment to show up
            let c = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            found = c.displays.first { $0.displayID == displayID }
            if found != nil { break }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        guard let display = found else { throw NSError(domain: "drawplay", code: 1, userInfo: [NSLocalizedDescriptionKey: "virtual display not visible to ScreenCaptureKit"]) }
        let cfg = SCStreamConfiguration()
        cfg.width = width; cfg.height = height
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        cfg.showsCursor = true
        cfg.queueDepth = 3
        let s = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: cfg, delegate: nil)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "capture"))
        try await s.startCapture()
        stream = s
    }

    func stop() async {
        onFrame = nil
        try? await stream?.stopCapture()
        stream = nil
    }

    func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = atts.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        onFrame?(pb)
    }
}
