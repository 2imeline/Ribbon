import CoreMedia
import VideoToolbox

/// Hardware-only H.264/HEVC encoder (Apple Silicon Media Engine). Frames go in as IOSurface-backed
/// pixel buffers straight from ScreenCaptureKit, so there are no CPU copies or color conversion.
final class Encoder: @unchecked Sendable {
    var onOutput: ((CMSampleBuffer, Encoder) -> Void)?
    private var session: VTCompressionSession?
    private let frameDuration: CMTime

    init(width: Int, height: Int, fps: Int, bitrateMbps: Int, hevc: Bool) throws {
        frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        let spec = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true] as CFDictionary
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height),
            codecType: hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
            encoderSpecification: spec, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        guard status == noErr, let s = created else {
            throw RibbonError("The hardware video encoder isn't available (error \(status)).")
        }
        session = s

        let bitrate = bitrateMbps * 1_000_000
        let props: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_AllowFrameReordering: false,  // no B-frames: lower latency, simple cuts
            kVTCompressionPropertyKey_ProfileLevel: hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel,
            kVTCompressionPropertyKey_AverageBitRate: bitrate,
            kVTCompressionPropertyKey_DataRateLimits: [bitrate / 4, 1],  // peaks of at most 2x average, in bytes per 1 s
            kVTCompressionPropertyKey_ExpectedFrameRate: fps,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: fps,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 1,  // 1 s GOP = buffer/trim granularity
            kVTCompressionPropertyKey_ColorPrimaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
            kVTCompressionPropertyKey_TransferFunction: kCVImageBufferTransferFunction_ITU_R_709_2,
            kVTCompressionPropertyKey_YCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
        ]
        for (key, value) in props { VTSessionSetProperty(s, key: key, value: value as AnyObject) }
        VTCompressionSessionPrepareToEncodeFrames(s)
    }

    func encode(_ pixelBuffer: CVPixelBuffer, at pts: CMTime) {
        guard let session else { return }
        VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: pts, duration: frameDuration,
            frameProperties: nil, infoFlagsOut: nil
        ) { [weak self] status, _, sample in
            guard status == noErr, let sample, let self else { return }
            self.onOutput?(sample, self)
        }
    }

    func invalidate() {
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil
    }

    deinit { invalidate() }
}

extension CMSampleBuffer {
    var isKeyframe: Bool {
        guard let attachments = (CMSampleBufferGetSampleAttachmentsArray(self, createIfNecessary: false) as? [[CFString: Any]])?.first
        else { return true }
        return !((attachments[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
    }

    /// Copies the PCM into memory we own, so we don't hold on to ScreenCaptureKit's buffer pool.
    func deepCopiedAudio() -> CMSampleBuffer? {
        guard let format = formatDescription, CMSampleBufferDataIsReady(self) else { return nil }
        return try? withAudioBufferList { list, _ -> CMSampleBuffer? in
            var out: CMSampleBuffer?
            guard CMAudioSampleBufferCreateWithPacketDescriptions(
                allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
                makeDataReadyCallback: nil, refcon: nil, formatDescription: format,
                sampleCount: numSamples, presentationTimeStamp: presentationTimeStamp,
                packetDescriptions: nil, sampleBufferOut: &out) == noErr, let out,
                CMSampleBufferSetDataBufferFromAudioBufferList(
                    out, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
                    flags: 0, bufferList: list.unsafePointer) == noErr
            else { return nil }
            return out
        }
    }
}
