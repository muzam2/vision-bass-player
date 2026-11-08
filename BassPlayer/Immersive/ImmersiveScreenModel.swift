#if os(visionOS)
import Foundation
import SwiftUI
import RealityKit

/// Shared state for the immersive cinema screen: geometry, placement and environment.
/// Persisted so the screen comes back where you left it.
@MainActor
final class ImmersiveScreenModel: ObservableObject {
    private let d = UserDefaults.standard

    @Published var isOpen = false
    @Published var aspect: Double = 16.0 / 9.0

    /// Screen width in metres. Height follows the video aspect ratio.
    @Published var width: Double { didSet { d.set(width, forKey: "imm.width") } }
    /// Distance in front of you (metres) and height relative to eye level.
    @Published var distance: Double { didSet { d.set(distance, forKey: "imm.distance") } }
    @Published var height: Double { didSet { d.set(height, forKey: "imm.height") } }
    /// Tilt in degrees: positive leans the top of the screen away (good for lying down).
    @Published var tilt: Double { didSet { d.set(tilt, forKey: "imm.tilt") } }
    @Published var yaw: Double { didSet { d.set(yaw, forKey: "imm.yaw") } }
    /// 0 = flat, 1 = tightly curved.
    @Published var curvature: Double { didSet { d.set(curvature, forKey: "imm.curve") } }
    /// Full immersion (default). The black dome is always present; this additionally hides passthrough.
    @Published var darkRoom: Bool { didSet { d.set(darkRoom, forKey: "imm.dark") } }
    /// Flip texture vertically if the picture renders upside down.
    @Published var flipV: Bool { didSet { d.set(flipV, forKey: "imm.flipV") } }
    @Published var hdr: Bool { didSet { d.set(hdr, forKey: "imm.hdr") } }

    init() {
        func num(_ k: String, _ def: Double) -> Double { d.object(forKey: k) == nil ? def : d.double(forKey: k) }
        width = num("imm.width", 4.0)
        distance = num("imm.distance", 3.0)
        height = num("imm.height", 0.3)
        tilt = num("imm.tilt", 0)
        yaw = num("imm.yaw", 0)
        curvature = num("imm.curve", 0.3)
        darkRoom = d.object(forKey: "imm.dark") == nil ? true : d.bool(forKey: "imm.dark")
        flipV = d.bool(forKey: "imm.flipV")
        hdr = d.object(forKey: "imm.hdr") == nil ? true : d.bool(forKey: "imm.hdr")
    }

    var screenHeight: Double { width / aspect }

    func reset() {
        width = 4; distance = 3; height = 0.3; tilt = 0; yaw = 0; curvature = 0.3
    }

    /// Orientation from yaw (around Y) then tilt (around X).
    var orientation: simd_quatf {
        let y = simd_quatf(angle: Float(yaw * .pi / 180), axis: [0, 1, 0])
        let t = simd_quatf(angle: Float(-tilt * .pi / 180), axis: [1, 0, 0])
        return y * t
    }

    var position: SIMD3<Float> {
        [0, Float(height), -Float(distance)]
    }
}
#endif
