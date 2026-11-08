#if os(visionOS)
import AVFoundation
import CoreMedia
import CoreVideo
import Metal
import KSPlayer

/// Hands decoded frames to RealityKit the way Apple's own players do it: each frame becomes a
/// CMSampleBuffer tagged with Apple Projected Media Profile extensions (view packing for
/// side-by-side / over-under 3D, projection for 180°/360°) and is enqueued on an
/// `AVSampleBufferVideoRenderer`. A `VideoMaterial(videoRenderer:)` on the screen mesh then
/// renders it — stereo per eye, HDR, colour conversion all done by the system. This replaces the
/// earlier CoreImage → DrawableQueue → shader-graph path, which produced a magenta (failed
/// material) screen on the device.
///
/// Frames come in three flavours:
///  - VideoToolbox frames: already a CVPixelBuffer, enqueued as-is.
///  - Software frames (VP9 from YouTube, odd codecs): planar Metal textures, repacked into a
///    bi-planar CVPixelBuffer with two small compute kernels (FrameConvert.metal).
///  - Dolby Vision profile 5: the app's DoVi shader output (PQ BT.2020, bgr10a2), blitted into a
///    10-bit RGB CVPixelBuffer with PQ colour tags.
@MainActor
final class ImmersiveFrameFeed {
    let renderer = AVSampleBufferVideoRenderer()

    var stereo: StereoFormat = .mono { didSet { if stereo != oldValue { formatCache = nil } } }
    var projection: ScreenProjection = .flat { didSet { if projection != oldValue { formatCache = nil } } }

    /// Size of the last frame pushed (full packed frame), for the screen's aspect ratio.
    private(set) var frameSize: (width: Int, height: Int) = (0, 0)
    private(set) var pushed = 0
    private(set) var dropped = 0
    private(set) var lastError: String?

    private var formatCache: CMFormatDescription?
    private var formatKey = ""

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var textureCache: CVMetalTextureCache?
    private var pool: CVPixelBufferPool?
    private var poolKey = ""
    private var copyPipeline: MTLComputePipelineState?
    private var interleavePipeline: MTLComputePipelineState?
    private var loggedKinds = Set<String>()

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        commandQueue = queue
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        if let lib = device.makeDefaultLibrary() {
            if let f = lib.makeFunction(name: "copyPlane") { copyPipeline = try? device.makeComputePipelineState(function: f) }
            if let f = lib.makeFunction(name: "interleaveChroma") { interleavePipeline = try? device.makeComputePipelineState(function: f) }
        }
        DiagLog.log("feed ready; kernels copy=\(copyPipeline != nil) interleave=\(interleavePipeline != nil)", "immersive")
    }

    func flush() {
        renderer.flush()
    }

    // MARK: - Entry point

    /// Push one decoded frame. `doviTexture` is the colour-mapped output for Dolby Vision
    /// profile 5 (takes precedence over the pixel buffer).
    func push(pixelBuffer source: PixelBufferProtocol, time: CMTime, doviTexture: MTLTexture?) {
        let cv: CVPixelBuffer?
        if let doviTexture {
            cv = convert(doviTexture: doviTexture)
            logOnce("dovi", "Dolby Vision frames \(doviTexture.width)x\(doviTexture.height) → ARGB2101010 PQ")
        } else if let hw = source.cvPixelBuffer {
            cv = hw
            logOnce("hw", "hardware frames \(source.width)x\(source.height) fmt \(fourCC(CVPixelBufferGetPixelFormatType(hw)))")
        } else {
            cv = convert(software: source)
        }
        guard let cv else { dropped += 1; return }
        enqueue(cv, time: time)
    }

    private func enqueue(_ pb: CVPixelBuffer, time: CMTime) {
        guard renderer.isReadyForMoreMediaData else { dropped += 1; return }
        do {
            let desc = try formatDescription(for: pb)
            let timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
            let sample = try CMSampleBuffer(imageBuffer: pb, formatDescription: desc, sampleTiming: timing)
            // KSPlayer already paces frames with its own clock; the renderer's timebase runs on
            // host time and would otherwise hold frames back or drop them.
            sample.sampleAttachments[0][.displayImmediately] = true
            renderer.enqueue(sample)
            pushed += 1
            frameSize = (CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb))
            if pushed == 1 { DiagLog.log("first frame enqueued \(frameSize.width)x\(frameSize.height) stereo=\(stereo.rawValue) proj=\(projection.rawValue)", "immersive") }
            if renderer.status == .failed {
                let e = renderer.error?.localizedDescription ?? "unknown"
                if lastError != e { lastError = e; DiagLog.log("renderer failed: \(e); flushing", "immersive") }
                renderer.flush()
            }
        } catch {
            dropped += 1
            let e = error.localizedDescription
            if lastError != e { lastError = e; DiagLog.log("enqueue failed: \(e)", "immersive") }
        }
    }

    // MARK: - Format description with APMP tags

    private func formatDescription(for pb: CVPixelBuffer) throws -> CMFormatDescription {
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let key = "\(w)x\(h)-\(CVPixelBufferGetPixelFormatType(pb))-\(stereo.rawValue)-\(projection.rawValue)"
        if let formatCache, formatKey == key { return formatCache }
        let base = try CMVideoFormatDescription(imageBuffer: pb)
        var ext = base.extensions
        switch stereo {
        case .sbsHalf, .sbsFull: ext[.viewPackingKind] = .viewPackingKind(.sideBySide)
        case .tabHalf, .tabFull: ext[.viewPackingKind] = .viewPackingKind(.overUnder)
        default: break
        }
        switch projection {
        case .flat:
            ext[.projectionKind] = .projectionKind(.rectilinear)
            ext[.horizontalFieldOfView] = .number(UInt32(65 * 1000))
        case .vr180:
            ext[.projectionKind] = .projectionKind(.halfEquirectangular)
            ext[.horizontalFieldOfView] = .number(UInt32(180 * 1000))
        case .vr360:
            ext[.projectionKind] = .projectionKind(.equirectangular)
            ext[.horizontalFieldOfView] = .number(UInt32(360 * 1000))
        }
        let desc = try CMVideoFormatDescription(videoCodecType: base.mediaSubType, width: w, height: h, extensions: ext)
        formatCache = desc
        formatKey = key
        DiagLog.log("format \(key)", "immersive")
        return desc
    }

    // MARK: - Software frames → bi-planar CVPixelBuffer

    private func convert(software src: PixelBufferProtocol) -> CVPixelBuffer? {
        let planes = src.textures()
        guard planes.count == 2 || planes.count == 3 else {
            logOnce("sw-unsupported", "software frame with \(planes.count) plane(s) not supported for the cinema screen")
            return nil
        }
        let tenBit = src.bitDepth > 8
        let full = src.isFullRangeVideo
        let fmt: OSType = tenBit
            ? (full ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
            : (full ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        guard let pb = dequeue(width: src.width, height: src.height, format: fmt) else { return nil }
        setColor(pb, primaries: src.colorPrimaries, transfer: src.transferFunction, matrix: src.yCbCrMatrix)
        guard let dstY = metalTexture(pb, plane: 0, format: tenBit ? .r16Unorm : .r8Unorm),
              let dstUV = metalTexture(pb, plane: 1, format: tenBit ? .rg16Unorm : .rg8Unorm),
              let cmd = commandQueue.makeCommandBuffer() else { return nil }
        // LSB-aligned 10-bit (yuv420p10) must move up 6 bits for P010; P010 itself has leftShift 0.
        var scale: Float = (tenBit && src.leftShift > 0) ? Float(1 << src.leftShift) : 1
        logOnce("sw", "software frames \(src.width)x\(src.height) planes=\(planes.count) \(src.bitDepth)-bit shift=\(src.leftShift) → \(fourCC(fmt))")
        if planes.count == 2 && scale == 1 {
            guard let blit = cmd.makeBlitCommandEncoder() else { return nil }
            Self.copy(blit, from: planes[0], to: dstY)
            Self.copy(blit, from: planes[1], to: dstUV)
            blit.endEncoding()
        } else {
            guard let copy = copyPipeline, let inter = interleavePipeline, let enc = cmd.makeComputeCommandEncoder() else {
                logOnce("sw-nokernel", "compute kernels unavailable; software frames skipped")
                return nil
            }
            enc.setComputePipelineState(copy)
            enc.setTexture(planes[0], index: 0)
            enc.setTexture(dstY, index: 1)
            enc.setBytes(&scale, length: MemoryLayout<Float>.size, index: 0)
            dispatch(enc, copy, width: dstY.width, height: dstY.height)
            if planes.count == 3 {
                enc.setComputePipelineState(inter)
                enc.setTexture(planes[1], index: 0)
                enc.setTexture(planes[2], index: 1)
                enc.setTexture(dstUV, index: 2)
                enc.setBytes(&scale, length: MemoryLayout<Float>.size, index: 0)
                dispatch(enc, inter, width: dstUV.width, height: dstUV.height)
            } else {
                enc.setComputePipelineState(copy)
                enc.setTexture(planes[1], index: 0)
                enc.setTexture(dstUV, index: 1)
                enc.setBytes(&scale, length: MemoryLayout<Float>.size, index: 0)
                dispatch(enc, copy, width: dstUV.width, height: dstUV.height)
            }
            enc.endEncoding()
        }
        cmd.commit()
        cmd.waitUntilCompleted()
        return pb
    }

    private func dispatch(_ enc: MTLComputeCommandEncoder, _ pipeline: MTLComputePipelineState, width: Int, height: Int) {
        let w = pipeline.threadExecutionWidth
        let h = max(1, pipeline.maxTotalThreadsPerThreadgroup / w)
        let tg = MTLSize(width: w, height: h, depth: 1)
        let grid = MTLSize(width: (width + w - 1) / w, height: (height + h - 1) / h, depth: 1)
        enc.dispatchThreadgroups(grid, threadsPerThreadgroup: tg)
    }

    // MARK: - Dolby Vision → 10-bit RGB CVPixelBuffer

    private func convert(doviTexture tex: MTLTexture) -> CVPixelBuffer? {
        guard tex.pixelFormat == .bgr10a2Unorm else {
            logOnce("dovi-fmt", "unexpected DoVi texture format \(tex.pixelFormat.rawValue)")
            return nil
        }
        guard let pb = dequeue(width: tex.width, height: tex.height, format: kCVPixelFormatType_ARGB2101010LEPacked) else { return nil }
        setColor(pb, primaries: kCVImageBufferColorPrimaries_ITU_R_2020, transfer: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, matrix: nil)
        guard let dst = metalTexture(pb, plane: 0, format: .bgr10a2Unorm),
              let cmd = commandQueue.makeCommandBuffer(), let blit = cmd.makeBlitCommandEncoder() else { return nil }
        Self.copy(blit, from: tex, to: dst)
        blit.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        return pb
    }

    // MARK: - Helpers

    /// Texture copy clamped to the smaller of the two sizes (odd frame sizes round differently
    /// between FFmpeg planes and CoreVideo planes; a mismatched whole-texture copy is fatal).
    private static func copy(_ blit: MTLBlitCommandEncoder, from src: MTLTexture, to dst: MTLTexture) {
        let size = MTLSize(width: min(src.width, dst.width), height: min(src.height, dst.height), depth: 1)
        blit.copy(from: src, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: size,
                  to: dst, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
    }

    private func dequeue(width: Int, height: Int, format: OSType) -> CVPixelBuffer? {
        let key = "\(width)x\(height)-\(format)"
        if pool == nil || poolKey != key {
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: format,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                kCVPixelBufferMetalCompatibilityKey: true,
            ]
            var p: CVPixelBufferPool?
            let r = CVPixelBufferPoolCreate(kCFAllocatorDefault, [kCVPixelBufferPoolMinimumBufferCountKey: 4] as CFDictionary, attrs as CFDictionary, &p)
            guard r == kCVReturnSuccess, let p else {
                logOnce("pool-\(key)", "pixel buffer pool failed (\(r)) for \(key)")
                return nil
            }
            pool = p
            poolKey = key
        }
        var pb: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb) == kCVReturnSuccess else { return nil }
        return pb
    }

    private func metalTexture(_ pb: CVPixelBuffer, plane: Int, format: MTLPixelFormat) -> MTLTexture? {
        guard let cache = textureCache else { return nil }
        let w = CVPixelBufferGetWidthOfPlane(pb, plane), h = CVPixelBufferGetHeightOfPlane(pb, plane)
        var cvTex: CVMetalTexture?
        let r = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pb, nil, format, w, h, plane, &cvTex)
        guard r == kCVReturnSuccess, let cvTex, let tex = CVMetalTextureGetTexture(cvTex) else {
            logOnce("tex-\(plane)-\(format.rawValue)", "CVMetalTexture failed (\(r)) plane \(plane)")
            return nil
        }
        return tex
    }

    private func setColor(_ pb: CVPixelBuffer, primaries: CFString?, transfer: CFString?, matrix: CFString?) {
        if let primaries { CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, primaries, .shouldPropagate) }
        if let transfer { CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, transfer, .shouldPropagate) }
        if let matrix { CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate) }
    }

    private func logOnce(_ kind: String, _ message: String) {
        guard !loggedKinds.contains(kind) else { return }
        loggedKinds.insert(kind)
        DiagLog.log(message, "immersive")
    }

    private func fourCC(_ v: OSType) -> String {
        let bytes = [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)]
        return String(bytes: bytes, encoding: .ascii) ?? String(v)
    }
}
#endif
