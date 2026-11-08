//
//  DoviMetadata.swift
//  KSPlayer (vendored fork, Bass Player)
//
//  Per-frame Dolby Vision RPU data needed to display profile 5 (IPT-PQ-C2) content:
//  the per-component reshaping curves (polynomial / MMR) and the colour matrices.
//  Mirrors libplacebo's `pl_dovi_metadata`, flattened into one float array for Metal.
//
import Foundation
import Libavcodec
import simd

public struct DoviMetadata: Sendable {
    /// Flat layout consumed by `displayDoviNV12Texture` / `displayDoviYUVTexture` in Shaders.metal.
    /// Keep the offsets in sync with the shader.
    public enum Layout {
        public static let numPivots = 0            // [3]
        public static let pivots = 3               // [3][9]
        public static let method = 30              // [3][8]   0 = polynomial, 1 = MMR
        public static let polyCoef = 54            // [3][8][3]
        public static let mmrOrder = 126           // [3][8]
        public static let mmrConstant = 150        // [3][8]
        public static let mmrCoef = 174            // [3][8][3][7]
        public static let nonlinear = 678          // 3x3 row-major  (YCC → LMS', PQ-encoded)
        public static let nonlinearOffset = 687    // [3]
        public static let linear = 690             // 3x3 row-major  (LMS → RGB, linear)
        public static let count = 699
    }

    public var values: [Float]
    /// Profile 5 base layers are not HDR10-compatible and need this mapping; profile 7/8 do not.
    public let needsMapping: Bool
    public let profile: Int
    public let blBitDepth: Int
    public let signalFullRange: Bool

    public init(values: [Float], needsMapping: Bool, profile: Int, blBitDepth: Int, signalFullRange: Bool) {
        self.values = values
        self.needsMapping = needsMapping
        self.profile = profile
        self.blBitDepth = blBitDepth
        self.signalFullRange = signalFullRange
    }

    /// Build from FFmpeg's AV_FRAME_DATA_DOVI_METADATA side data.
    /// `blCompatibilityId` comes from the stream's dvcC/dvvC (0 = profile 5 style, needs mapping).
    public init?(avMetadata data: UnsafePointer<AVDOVIMetadata>, profile: Int, blCompatibilityId: Int) {
        guard let header = av_dovi_get_header(data),
              let mapping = av_dovi_get_mapping(data),
              let color = av_dovi_get_color(data)
        else { return nil }

        let h = header.pointee
        let blBitDepth = Int(h.bl_bit_depth)
        let pivotScale = Float((1 << max(1, blBitDepth)) - 1)
        let coefScale = Float(1 << Int(h.coef_log2_denom))

        var v = [Float](repeating: 0, count: Layout.count)

        // Three reshaping curves (Y/I, Cb/P, Cr/T).
        let curves: [AVDOVIReshapingCurve] = withUnsafeBytes(of: mapping.pointee.curves) {
            Array($0.bindMemory(to: AVDOVIReshapingCurve.self).prefix(3))
        }
        for (c, curve) in curves.enumerated() {
            let n = Int(curve.num_pivots)
            v[Layout.numPivots + c] = Float(n)
            let pivots: [UInt16] = withUnsafeBytes(of: curve.pivots) { Array($0.bindMemory(to: UInt16.self).prefix(9)) }
            for i in 0..<9 { v[Layout.pivots + c * 9 + i] = Float(pivots[i]) / pivotScale }

            let mappingIdc: [UInt32] = withUnsafeBytes(of: curve.mapping_idc) { Array($0.bindMemory(to: UInt32.self).prefix(8)) }
            let polyOrder: [UInt8] = withUnsafeBytes(of: curve.poly_order) { Array($0.bindMemory(to: UInt8.self).prefix(8)) }
            let polyCoef: [Int64] = withUnsafeBytes(of: curve.poly_coef) { Array($0.bindMemory(to: Int64.self).prefix(24)) }   // [8][3]
            let mmrOrder: [UInt8] = withUnsafeBytes(of: curve.mmr_order) { Array($0.bindMemory(to: UInt8.self).prefix(8)) }
            let mmrConstant: [Int64] = withUnsafeBytes(of: curve.mmr_constant) { Array($0.bindMemory(to: Int64.self).prefix(8)) }
            let mmrCoef: [Int64] = withUnsafeBytes(of: curve.mmr_coef) { Array($0.bindMemory(to: Int64.self).prefix(168)) }   // [8][3][7]

            for p in 0..<8 {
                let isMMR = mappingIdc[p] == AV_DOVI_MAPPING_MMR.rawValue
                v[Layout.method + c * 8 + p] = isMMR ? 1 : 0
                let order = Int(polyOrder[p])
                for k in 0..<3 {
                    v[Layout.polyCoef + (c * 8 + p) * 3 + k] = k <= order ? Float(polyCoef[p * 3 + k]) / coefScale : 0
                }
                v[Layout.mmrOrder + c * 8 + p] = Float(mmrOrder[p])
                v[Layout.mmrConstant + c * 8 + p] = Float(mmrConstant[p]) / coefScale
                for o in 0..<3 {
                    for j in 0..<7 {
                        v[Layout.mmrCoef + ((c * 8 + p) * 3 + o) * 7 + j] = Float(mmrCoef[(p * 3 + o) * 7 + j]) / coefScale
                    }
                }
            }
        }

        // Colour matrices (AVRational → float), row-major as stored.
        let ycc: [AVRational] = withUnsafeBytes(of: color.pointee.ycc_to_rgb_matrix) { Array($0.bindMemory(to: AVRational.self).prefix(9)) }
        let yccOff: [AVRational] = withUnsafeBytes(of: color.pointee.ycc_to_rgb_offset) { Array($0.bindMemory(to: AVRational.self).prefix(3)) }
        let lms: [AVRational] = withUnsafeBytes(of: color.pointee.rgb_to_lms_matrix) { Array($0.bindMemory(to: AVRational.self).prefix(9)) }
        func f(_ r: AVRational) -> Float { r.den == 0 ? 0 : Float(r.num) / Float(r.den) }
        for i in 0..<9 {
            v[Layout.nonlinear + i] = f(ycc[i])
            v[Layout.linear + i] = f(lms[i])
        }
        for i in 0..<3 { v[Layout.nonlinearOffset + i] = f(yccOff[i]) }

        self.values = v
        self.profile = profile
        self.blBitDepth = blBitDepth
        self.signalFullRange = h.bl_video_full_range_flag != 0
        // Profile 5 (and any stream whose base layer isn't HDR10/HLG/SDR compatible) needs the mapping.
        self.needsMapping = blCompatibilityId == 0 || profile == 5
    }
}
