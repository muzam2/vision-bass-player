//
//  Edge264Decode.swift
//  KSPlayer (Bass Player patch)
//
//  Software H.264 / MVC decoder for 3D Blu-ray streams (Stereo High profile), built on
//  edge264-mvc (BSD-3, Vendor/edge264-mvc). FFmpeg and VideoToolbox decode only the base
//  view of an MVC stream and drop the second eye; this decoder returns both views of every
//  picture and packs them into one full-width side-by-side NV12 frame (base | dependent),
//  which the rest of the pipeline treats like any other packed-3D file.
//

import CoreVideo
import Foundation
import Libavcodec
import Libavformat
import edge264mvc

final class Edge264Decode: DecodeProtocol {
    /// Return codes of edge264mvc.h (an anonymous C enum; spelled out so the type is unambiguous).
    private enum Code {
        static let ok: Int32 = 0, again: Int32 = -1, end: Int32 = -2, unsupported: Int32 = -3, corrupt: Int32 = -4, nomem: Int32 = -5
    }

    private var decoder: OpaquePointer?
    private let assetTrack: FFmpegAssetTrack
    private let options: KSOptions
    /// Length-prefix size of the NAL units in packets (avcC / "mp4 style"); 0 means Annex B start codes.
    private let nalLengthSize: Int
    /// SPS / PPS from the avcC extradata, sent before the first packet and again after a flush.
    private let parameterSets: [[UInt8]]
    private var parameterSetsSent = false
    private var pool: CVPixelBufferPool?
    private var poolKey = ""
    private var frame = Edge264MvcFrame()
    private var reportedStereo = false
    private var reportedBitDepth = false
    private var sentEnd = false

    // MARK: - Detection

    /// Stereo High (128) / Multiview High (118) in the codec parameters, or MVC NAL units
    /// (prefix 14, subset SPS 15, slice extension 20) in the first packet.
    static func isMVC(packet: Packet, assetTrack: FFmpegAssetTrack) -> Bool {
        guard assetTrack.codecpar.codec_id == AV_CODEC_ID_H264 else { return false }
        if assetTrack.codecpar.profile == 118 || assetTrack.codecpar.profile == 128 { return true }
        guard let core = packet.corePacket?.pointee, let data = core.data, core.size > 0 else { return false }
        var found = false
        forEachNAL(data, Int(core.size), lengthSize: nalLengthSize(for: assetTrack)) { nal, size in
            guard size > 0 else { return }
            let type = nal[0] & 0x1F
            if type == 14 || type == 15 || type == 20 { found = true }
        }
        return found
    }

    private static func nalLengthSize(for assetTrack: FFmpegAssetTrack) -> Int {
        let par = assetTrack.codecpar
        guard let ex = par.extradata, par.extradata_size >= 7, ex[0] == 1 else { return 0 }   // avcC
        return Int(ex[4] & 3) + 1
    }

    /// SPS and PPS NAL units stored in an avcC box.
    private static func avcCParameterSets(_ assetTrack: FFmpegAssetTrack) -> [[UInt8]] {
        let par = assetTrack.codecpar
        guard let ex = par.extradata, par.extradata_size >= 7, ex[0] == 1 else { return [] }
        let size = Int(par.extradata_size)
        var sets: [[UInt8]] = []
        var p = 5
        func readSets(_ count: Int) {
            for _ in 0 ..< count {
                guard p + 2 <= size else { return }
                let len = Int(ex[p]) << 8 | Int(ex[p + 1])
                p += 2
                guard len > 0, p + len <= size else { return }
                sets.append(Array(UnsafeBufferPointer(start: ex + p, count: len)))
                p += len
            }
        }
        guard p < size else { return [] }
        readSets(Int(ex[p] & 0x1F)); p += 1
        guard p < size else { return sets }
        readSets(Int(ex[p])); p += 1
        return sets
    }

    private static func forEachNAL(_ data: UnsafePointer<UInt8>, _ size: Int, lengthSize: Int, _ body: (UnsafePointer<UInt8>, Int) -> Void) {
        if lengthSize == 0 {
            var pos = edge264mvc_find_start_code(data, size)
            while pos < size {
                let start = pos + 3
                guard start <= size else { break }
                let next = start + edge264mvc_find_start_code(data + start, size - start)
                // Drop the trailing zero of a 4-byte start code belonging to the next NAL.
                var len = next - start
                while len > 0, data[start + len - 1] == 0 { len -= 1 }
                if len > 0 { body(data + start, len) }
                pos = next
            }
        } else {
            var p = 0
            while p + lengthSize <= size {
                var len = 0
                for i in 0 ..< lengthSize { len = len << 8 | Int(data[p + i]) }
                p += lengthSize
                guard len > 0, p + len <= size else { break }
                body(data + p, len)
                p += len
            }
        }
    }

    // MARK: - Lifecycle

    init?(assetTrack: FFmpegAssetTrack, options: KSOptions) {
        self.assetTrack = assetTrack
        self.options = options
        nalLengthSize = Self.nalLengthSize(for: assetTrack)
        parameterSets = Self.avcCParameterSets(assetTrack)
        var settings = Edge264MvcSettings()
        edge264mvc_default_settings(&settings)
        settings.n_threads = 0   // 3 workers per core; the decoder sleeps the idle ones
        var dec: OpaquePointer?
        guard edge264mvc_open(&dec, &settings) == Code.ok, let dec else {
            KSLog("edge264: could not open decoder")
            return nil
        }
        decoder = dec
        KSLog("edge264 \(String(cString: edge264mvc_version())) decoding \(assetTrack.codecpar.width)x\(assetTrack.codecpar.height) H.264 (MVC), NAL length size \(nalLengthSize)")
    }

    func decode() {
        doFlushCodec()
    }

    func doFlushCodec() {
        guard let decoder else { return }
        edge264mvc_flush(decoder)
        parameterSetsSent = false
        sentEnd = false
    }

    func shutdown() {
        if decoder != nil {
            edge264mvc_close(&decoder)
        }
        pool = nil
    }

    // MARK: - Decoding

    func decodeFrame(from packet: Packet, completionHandler: @escaping (Result<MEFrame, Error>) -> Void) {
        guard let decoder else { return }
        guard let core = packet.corePacket?.pointee, let data = core.data, core.size > 0 else {
            // Empty packet: end of stream — flush everything the decoder still holds.
            if !sentEnd {
                sentEnd = true
                edge264mvc_send_end(decoder)
                drain(completionHandler)
            }
            return
        }
        if !parameterSetsSent {
            parameterSetsSent = true
            for ps in parameterSets {
                ps.withUnsafeBufferPointer { buf in
                    if let base = buf.baseAddress { send(base, buf.count, pts: packet.timestamp, userData: packet.duration, completionHandler) }
                }
            }
        }
        let pts = packet.timestamp
        let duration = packet.duration
        Self.forEachNAL(data, Int(core.size), lengthSize: nalLengthSize) { nal, size in
            send(nal, size, pts: pts, userData: duration, completionHandler)
        }
        drain(completionHandler)
    }

    private func send(_ nal: UnsafePointer<UInt8>, _ size: Int, pts: Int64, userData: Int64, _ completionHandler: (Result<MEFrame, Error>) -> Void) {
        guard let decoder else { return }
        var attempts = 0
        while true {
            let r = edge264mvc_send_nal(decoder, nal, size, pts, userData)
            if r == Code.again {
                // Full: hand out the ready frames and retry (every round makes progress).
                drain(completionHandler)
                attempts += 1
                if attempts > 1000 { KSLog("edge264: decoder stuck full"); return }
                continue
            }
            if r == Code.nomem { KSLog("edge264: out of memory") }
            return   // OK, UNSUPPORTED (e.g. Blu-ray NAL 24) and CORRUPT: move on
        }
    }

    private func drain(_ completionHandler: (Result<MEFrame, Error>) -> Void) {
        guard let decoder else { return }
        while edge264mvc_receive_frame(decoder, &frame) == Code.ok {
            if let out = makeFrame() {
                completionHandler(.success(out))
            }
            edge264mvc_release_frame(decoder, &frame)
        }
    }

    // MARK: - Output

    /// Pack base | dependent view into one NV12 frame (only the base when the pair is incomplete).
    private func makeFrame() -> VideoVTBFrame? {
        let base = frame.views.0
        let dep = frame.views.1
        guard let y0 = base.planes.0, let cb0 = base.planes.1, let cr0 = base.planes.2 else { return nil }
        guard frame.bit_depth_Y == 8, frame.bit_depth_C == 8 else {
            if !reportedBitDepth { reportedBitDepth = true; KSLog("edge264: \(frame.bit_depth_Y)-bit video is not packed by this path") }
            return nil
        }
        let w = Int(frame.width_Y), h = Int(frame.height_Y)
        let wC = Int(frame.width_C), hC = Int(frame.height_C)
        guard w > 0, h > 0, wC * 2 >= w - 1, hC * 2 >= h - 1 else { return nil }   // 4:2:0 only
        let hasRight = dep.planes.0 != nil && dep.planes.1 != nil && dep.planes.2 != nil
        if hasRight, !reportedStereo {
            reportedStereo = true
            assetTrack.decodesStereoSideBySide = true
            KSLog("edge264: stereo pair decoded, output is full side-by-side \(w * 2)x\(h)")
        }
        let outW = hasRight ? w * 2 : w
        let key = "\(outW)x\(h)"
        if pool == nil || poolKey != key {
            pool = CVPixelBufferPool.create(width: Int32(outW), height: Int32(h), bytesPerRowAlignment: Int32(outW), pixelFormatType: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
            poolKey = key
        }
        guard let pool else { return nil }
        var pbOpt: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pbOpt) == kCVReturnSuccess, let pb = pbOpt else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        if let dstY = CVPixelBufferGetBaseAddressOfPlane(pb, 0), let dstUV = CVPixelBufferGetBaseAddressOfPlane(pb, 1) {
            let strideY = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
            let strideUV = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
            copyView(y: y0, cb: cb0, cr: cr0, into: dstY, dstUV, strideY: strideY, strideUV: strideUV, xOffset: 0, w: w, h: h, wC: wC, hC: hC)
            if hasRight, let y1 = dep.planes.0, let cb1 = dep.planes.1, let cr1 = dep.planes.2 {
                copyView(y: y1, cb: cb1, cr: cr1, into: dstY, dstUV, strideY: strideY, strideUV: strideUV, xOffset: w, w: w, h: h, wC: wC, hC: hC)
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])

        let out = VideoVTBFrame(fps: assetTrack.nominalFrameRate, isDovi: false)
        out.corePixelBuffer = pb
        out.timebase = assetTrack.timebase
        out.timestamp = base.pts
        out.duration = base.user_data
        out.position = 0
        out.size = 0
        return out
    }

    /// Copy one view's planar 4:2:0 picture into the NV12 destination at a horizontal offset.
    private func copyView(y: UnsafePointer<UInt8>, cb: UnsafePointer<UInt8>, cr: UnsafePointer<UInt8>,
                          into dstY: UnsafeMutableRawPointer, _ dstUV: UnsafeMutableRawPointer,
                          strideY: Int, strideUV: Int, xOffset: Int, w: Int, h: Int, wC: Int, hC: Int) {
        let srcStrideY = Int(frame.stride_Y), srcStrideC = Int(frame.stride_C)
        for row in 0 ..< h {
            memcpy(dstY + row * strideY + xOffset, y + row * srcStrideY, w)
        }
        let pairs = min(wC, (strideUV - xOffset) / 2)
        for row in 0 ..< hC {
            let s0 = cb + row * srcStrideC
            let s1 = cr + row * srcStrideC
            let d = (dstUV + row * strideUV + xOffset).assumingMemoryBound(to: UInt8.self)
            var i = 0
            while i < pairs {
                d[2 * i] = s0[i]
                d[2 * i + 1] = s1[i]
                i += 1
            }
        }
    }
}
