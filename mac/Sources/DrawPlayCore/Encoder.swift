import CoreMedia
import Foundation
import VideoToolbox

/// Low-latency H.264 encoder producing Annex-B. Output frames: (type, bytes)
/// type 1 = SPS+PPS config, 2 = keyframe, 3 = delta frame.
final class Encoder {
    var onOutput: ((UInt8, Data) -> Void)?
    private var session: VTCompressionSession?
    private var forceKey = true
    private var frameCount: Int64 = 0

    init?(width: Int, height: Int, fps: Int, bitrate: Int) {
        let spec = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary
        guard VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
                                         codecType: kCMVideoCodecType_H264, encoderSpecification: spec,
                                         imageBufferAttributes: nil, compressedDataAllocator: nil,
                                         outputCallback: nil, refcon: nil, compressionSessionOut: &session) == noErr,
              let s = session else { return nil }
        func set(_ k: CFString, _ v: CFTypeRef) { VTSessionSetProperty(s, key: k, value: v) }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_MaxFrameDelayCount, 0 as CFNumber)
        set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
        set(kVTCompressionPropertyKey_AverageBitRate, bitrate as CFNumber)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, fps as CFNumber)
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, (fps * 2) as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_DataRateLimits, value: [bitrate * 3 / 8, 1] as CFArray)
        VTCompressionSessionPrepareToEncodeFrames(s)
    }

    func requestKeyframe() { forceKey = true }

    /// Changes the average bitrate while running (used to back off when the network can't keep up).
    func setBitrate(_ bps: Int) {
        guard let s = session else { return }
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: bps as CFNumber)
        // Allow short bursts (a keyframe, a full-screen change) up to 3x the average within one second.
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_DataRateLimits, value: [bps * 3 / 8, 1] as CFArray)
    }

    func invalidate() {
        onOutput = nil
        if let s = session { VTCompressionSessionInvalidate(s) }
        session = nil
    }

    func encode(_ pb: CVPixelBuffer) {
        guard let s = session else { return }
        var props: CFDictionary?
        if forceKey { props = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary; forceKey = false }
        let pts = CMTime(value: frameCount, timescale: 60); frameCount += 1
        timingLock.lock(); starts[pts.value] = CFAbsoluteTimeGetCurrent(); if starts.count > 64 { starts.removeAll() }; timingLock.unlock()
        VTCompressionSessionEncodeFrame(s, imageBuffer: pb, presentationTimeStamp: pts, duration: .invalid,
                                        frameProperties: props, infoFlagsOut: nil) { [weak self] status, _, sb in
            guard status == noErr, let sb, let self else { return }
            self.emit(sb)
        }
    }

    /// Average time from handing a frame to the encoder until it comes out, in milliseconds.
    var encodeMs: Double { timingLock.lock(); defer { timingLock.unlock() }; return avgEncode }
    private let timingLock = NSLock()
    private var starts: [Int64: CFAbsoluteTime] = [:]
    private var avgEncode = 0.0

    private func emit(_ sb: CMSampleBuffer) {
        let key = CMSampleBufferGetPresentationTimeStamp(sb).value
        timingLock.lock()
        if let t0 = starts.removeValue(forKey: key) { avgEncode = avgEncode == 0 ? (CFAbsoluteTimeGetCurrent() - t0) * 1000 : avgEncode * 0.9 + (CFAbsoluteTimeGetCurrent() - t0) * 100 }
        timingLock.unlock()
        let start = Data([0, 0, 0, 1])
        let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]]
        let isKey = !((atts?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
        if isKey, let fd = CMSampleBufferGetFormatDescription(sb) {
            var cfg = Data()
            for i in 0..<2 {
                var p: UnsafePointer<UInt8>?; var n = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: i, parameterSetPointerOut: &p,
                        parameterSetSizeOut: &n, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let p {
                    cfg += start; cfg += Data(bytes: p, count: n)
                }
            }
            onOutput?(1, cfg)
        }
        guard let bb = CMSampleBufferGetDataBuffer(sb) else { return }
        var len = 0; var ptr: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &ptr) == noErr,
              let ptr else { return }
        let raw = UnsafeRawPointer(ptr)
        var out = Data(); var off = 0
        while off + 4 <= len {   // AVCC (4-byte length) -> Annex-B
            let nal = Int(UInt32(bigEndian: raw.loadUnaligned(fromByteOffset: off, as: UInt32.self)))
            off += 4
            guard nal > 0, off + nal <= len else { break }
            out += start; out += Data(bytes: raw + off, count: nal)
            off += nal
        }
        onOutput?(isKey ? 2 : 3, out)
    }
}
