import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import VideoToolbox

/// Decodes Remote Play's live H.264 / HEVC stream with VideoToolbox and hands every picture to
/// `onFrame` as soon as it is out of the decoder (no reordering, no clock: a game wants the
/// newest frame now). chiaki delivers Annex-B access units; the codec header (parameter sets)
/// comes first on its own and again with every keyframe.
///
/// Runs entirely on the caller's thread (chiaki's video thread): decoding is synchronous, so the
/// result of each frame is known before the callback returns and a failed frame can ask the
/// console for a keyframe.
final class RemotePlayVideoDecoder {
    enum Codec: String { case h264 = "H.264", hevc = "HEVC" }

    /// Decoded picture and the host time it came out of the decoder.
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?

    private(set) var codec: Codec
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var parameterSets: [Data] = []

    // Stats, read (inexactly) from the main thread.
    private let statsLock = NSLock()
    private var _decoded = 0
    private var _failed = 0
    private var _lost = 0
    private var _width = 0
    private var _height = 0
    private var _hdr = false

    struct Stats { var decoded = 0, failed = 0, lost = 0, width = 0, height = 0, hdr = false }
    var stats: Stats {
        statsLock.lock(); defer { statsLock.unlock() }
        return Stats(decoded: _decoded, failed: _failed, lost: _lost, width: _width, height: _height, hdr: _hdr)
    }

    init(hevc: Bool) {
        codec = hevc ? .hevc : .h264
    }

    deinit { invalidate() }

    func invalidate() {
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        format = nil
    }

    /// One callback's worth of stream. Returns false if the picture could not be decoded.
    func decode(_ buffer: UnsafeBufferPointer<UInt8>, framesLost: Int32, recovered: Bool) -> Bool {
        if framesLost > 0 { bump { $0._lost += Int(framesLost) } }
        let nals = Self.splitAnnexB(buffer)
        guard !nals.isEmpty else { return true }

        // The console may answer an H.265 request with H.264 (auto-downgrade); trust the stream.
        if let first = nals.first, let detected = Self.detectCodec(first), detected != codec, session == nil {
            DiagLog.log("stream is \(detected.rawValue), not \(codec.rawValue) as requested", "rp")
            codec = detected
            parameterSets = []
        }

        var picture: [UnsafeBufferPointer<UInt8>] = []
        var keyframe = false
        var params: [Data] = []
        for nal in nals {
            guard let header = nal.first else { continue }
            switch codec {
            case .h264:
                let type = header & 0x1F
                switch type {
                case 7, 8: params.append(Data(nal))
                case 9: continue                 // access unit delimiter
                case 5: keyframe = true; picture.append(nal)
                default: picture.append(nal)
                }
            case .hevc:
                let type = (header >> 1) & 0x3F
                switch type {
                case 32, 33, 34: params.append(Data(nal))
                case 35: continue                // access unit delimiter
                case 16...21: keyframe = true; picture.append(nal)
                default: picture.append(nal)
                }
            }
        }

        if !params.isEmpty {
            if params != parameterSets {
                parameterSets = params
                if !rebuildSession() { return false }
            }
        }
        guard !picture.isEmpty else { return true }
        guard let session, let format else { return false }   // no header yet: ask for a keyframe

        _ = keyframe
        guard let sample = makeSample(picture, format: format) else { bump { $0._failed += 1 }; return false }
        var ok = false
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [._1xRealTimePlayback],
                                                       infoFlagsOut: nil) { [weak self] st, _, image, _, _ in
            guard let self else { return }
            if st == noErr, let image {
                ok = true
                self.onFrame?(image, CMClockGetTime(CMClockGetHostTimeClock()))
            }
        }
        if status != noErr || !ok {
            bump { $0._failed += 1 }
            if status == kVTInvalidSessionErr { invalidate(); _ = rebuildSession() }
            return false
        }
        bump { $0._decoded += 1 }
        return true
    }

    private func bump(_ f: (RemotePlayVideoDecoder) -> Void) {
        statsLock.lock(); f(self); statsLock.unlock()
    }

    // MARK: - Session

    private func rebuildSession() -> Bool {
        invalidate()
        guard let desc = Self.formatDescription(codec: codec, parameterSets: parameterSets) else {
            DiagLog.log("could not build a \(codec.rawValue) format from \(parameterSets.count) parameter sets", "rp")
            return false
        }
        format = desc
        let dims = CMVideoFormatDescriptionGetDimensions(desc)
        let ext = CMFormatDescriptionGetExtensions(desc) as? [String: Any]
        let transfer = ext?[kCMFormatDescriptionExtension_TransferFunction as String] as? String
        let hdr = transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
            || transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
        statsLock.lock(); _width = Int(dims.width); _height = Int(dims.height); _hdr = hdr; statsLock.unlock()

        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var s: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: desc,
                                                  decoderSpecification: nil,
                                                  imageBufferAttributes: attrs as CFDictionary,
                                                  outputCallback: nil, decompressionSessionOut: &s)
        guard status == noErr, let s else {
            DiagLog.log("VTDecompressionSessionCreate failed (\(status))", "rp")
            return false
        }
        VTSessionSetProperty(s, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = s
        DiagLog.log("decoder ready: \(codec.rawValue) \(dims.width)x\(dims.height)\(hdr ? " HDR" : "")", "rp")
        return true
    }

    private func makeSample(_ nals: [UnsafeBufferPointer<UInt8>], format: CMVideoFormatDescription) -> CMSampleBuffer? {
        // AVCC/HVCC framing: 4-byte big-endian length before each NAL unit.
        let total = nals.reduce(0) { $0 + 4 + $1.count }
        guard let mem = malloc(total) else { return nil }
        var offset = 0
        for nal in nals {
            var len = UInt32(nal.count).bigEndian
            memcpy(mem + offset, &len, 4)
            if let base = nal.baseAddress { memcpy(mem + offset + 4, base, nal.count) }
            offset += 4 + nal.count
        }
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: mem, blockLength: total,
                                                        blockAllocator: kCFAllocatorMalloc, customBlockSource: nil,
                                                        offsetToData: 0, dataLength: total, flags: 0, blockBufferOut: &block)
        guard status == kCMBlockBufferNoErr, let block else { free(mem); return nil }
        var sample: CMSampleBuffer?
        var size = total
        status = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                                           sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
                                           sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard status == noErr else { return nil }
        return sample
    }

    // MARK: - Annex-B

    /// NAL units between start codes (00 00 01 or 00 00 00 01), without the start codes.
    static func splitAnnexB(_ buf: UnsafeBufferPointer<UInt8>) -> [UnsafeBufferPointer<UInt8>] {
        guard let base = buf.baseAddress, buf.count > 3 else { return [] }
        let n = buf.count
        var starts: [(payload: Int, code: Int)] = []
        var i = 0
        while i + 2 < n {
            if base[i] == 0, base[i + 1] == 0 {
                if base[i + 2] == 1 {
                    starts.append((i + 3, i))
                    i += 3
                    continue
                } else if base[i + 2] == 0, i + 3 < n, base[i + 3] == 1 {
                    starts.append((i + 4, i))
                    i += 4
                    continue
                }
            }
            i += 1
        }
        var out: [UnsafeBufferPointer<UInt8>] = []
        for (k, s) in starts.enumerated() {
            var end = k + 1 < starts.count ? starts[k + 1].code : n
            // Trailing zero bytes belong to the next start code or padding.
            while end > s.payload, base[end - 1] == 0 { end -= 1 }
            if end > s.payload { out.append(UnsafeBufferPointer(start: base + s.payload, count: end - s.payload)) }
        }
        return out
    }

    /// Codec from a parameter-set NAL, if the first unit is one.
    private static func detectCodec(_ nal: UnsafeBufferPointer<UInt8>) -> Codec? {
        guard let b = nal.first else { return nil }
        let hevcType = (b >> 1) & 0x3F
        if hevcType == 32 || hevcType == 33 { return .hevc }   // VPS / SPS
        let avcType = b & 0x1F
        if avcType == 7 { return .h264 }
        return nil
    }

    private static func formatDescription(codec: Codec, parameterSets: [Data]) -> CMVideoFormatDescription? {
        let ordered: [Data]
        switch codec {
        case .h264:
            let sps = parameterSets.filter { ($0.first ?? 0) & 0x1F == 7 }
            let pps = parameterSets.filter { ($0.first ?? 0) & 0x1F == 8 }
            guard !sps.isEmpty, !pps.isEmpty else { return nil }
            ordered = [sps[0]] + pps
        case .hevc:
            func type(_ d: Data) -> UInt8 { ((d.first ?? 0) >> 1) & 0x3F }
            let vps = parameterSets.filter { type($0) == 32 }
            let sps = parameterSets.filter { type($0) == 33 }
            let pps = parameterSets.filter { type($0) == 34 }
            guard !vps.isEmpty, !sps.isEmpty, !pps.isEmpty else { return nil }
            ordered = [vps[0], sps[0]] + pps
        }
        // The CoreMedia calls take C arrays of pointers; copy each set into its own buffer.
        let copies: [UnsafeMutablePointer<UInt8>] = ordered.map { d in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: d.count)
            d.copyBytes(to: p, count: d.count)
            return p
        }
        defer { copies.forEach { $0.deallocate() } }
        let pointers: [UnsafePointer<UInt8>] = copies.map { UnsafePointer($0) }
        let sizes = ordered.map(\.count)
        var desc: CMFormatDescription?
        let status: OSStatus = pointers.withUnsafeBufferPointer { ptrs in
            sizes.withUnsafeBufferPointer { sz in
                switch codec {
                case .h264:
                    return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: kCFAllocatorDefault, parameterSetCount: ordered.count,
                        parameterSetPointers: ptrs.baseAddress!, parameterSetSizes: sz.baseAddress!,
                        nalUnitHeaderLength: 4, formatDescriptionOut: &desc)
                case .hevc:
                    return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault, parameterSetCount: ordered.count,
                        parameterSetPointers: ptrs.baseAddress!, parameterSetSizes: sz.baseAddress!,
                        nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &desc)
                }
            }
        }
        guard status == noErr else {
            DiagLog.log("format description from parameter sets failed (\(status))", "rp")
            return nil
        }
        return desc
    }
}
