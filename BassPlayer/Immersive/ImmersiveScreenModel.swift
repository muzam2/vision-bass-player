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
    /// Last RealityKit frame tick while open. The system can take the space down (Digital Crown,
    /// device removed) without delivering onDisappear; a stale tick with `isOpen` reveals that.
    var lastTick = Date.distantPast
    var isStale: Bool { isOpen && Date().timeIntervalSince(lastTick) > 2 }
    @Published var aspect: Double = 16.0 / 9.0
    /// Bumped by the UI to ask the view to recentre on the current head pose.
    @Published var recentreRequest = 0
    /// Bumped when the player goes away while the screen is open (RootView dismisses the space).
    @Published var closeRequest = 0

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
    /// Picture controls for the cinema screen (applied in CoreImage). 0 = neutral.
    @Published var brightness: Double { didSet { d.set(brightness, forKey: "imm.brightness") } }
    @Published var contrast: Double { didSet { d.set(contrast, forKey: "imm.contrast") } }
    @Published var saturation: Double { didSet { d.set(saturation, forKey: "imm.saturation") } }
    /// Extra exposure for HDR content in stops (4XVR's "HDR luminance").
    @Published var hdrBoost: Double { didSet { d.set(hdrBoost, forKey: "imm.hdrBoost") } }
    /// 0 = see the room, 1 = black (dome opacity). Only visible when full immersion is off.
    @Published var roomDim: Double { didSet { d.set(roomDim, forKey: "imm.roomDim") } }
    /// Where the user's head is (set by recentre); VR spheres are centred here.
    @Published var headPosition: SIMD3<Float> = [0, 1.4, 0]

    /// Cinema defaults: a screen spanning ~85° of view, like the "giant screen" modes of the
    /// commercial players, in a black void.
    static let defaultWidth = 6.5
    static let defaultDistance = 3.5
    static let defaultCurve = 0.0   // flat; curve is a slider on the cinema panel

    init() {
        let d = UserDefaults.standard
        // Layout v2 (2026-11-08): the first version's 4 m screen was a TV, not a cinema; values
        // saved by the broken settings popover are discarded once.
        if d.integer(forKey: "imm.layoutVersion") < 3 {
            for k in ["imm.width", "imm.distance", "imm.height", "imm.tilt", "imm.yaw", "imm.curve"] { d.removeObject(forKey: k) }
            d.set(3, forKey: "imm.layoutVersion")
        }
        // Layout v4: height became an offset from the gaze line and tilt the gaze pitch.
        if d.integer(forKey: "imm.layoutVersion") < 4 {
            for k in ["imm.height", "imm.tilt"] { d.removeObject(forKey: k) }
            d.set(4, forKey: "imm.layoutVersion")
        }
        func num(_ k: String, _ def: Double) -> Double { d.object(forKey: k) == nil ? def : d.double(forKey: k) }
        width = num("imm.width", Self.defaultWidth)
        distance = num("imm.distance", Self.defaultDistance)
        height = num("imm.height", 0)          // metres above/below the gaze line
        tilt = num("imm.tilt", 0)
        yaw = num("imm.yaw", 0)
        curvature = num("imm.curve", Self.defaultCurve)
        darkRoom = d.object(forKey: "imm.dark") == nil ? true : d.bool(forKey: "imm.dark")
        flipV = d.bool(forKey: "imm.flipV")
        hdr = d.object(forKey: "imm.hdr") == nil ? true : d.bool(forKey: "imm.hdr")
        brightness = num("imm.brightness", 0)
        contrast = num("imm.contrast", 1)
        saturation = num("imm.saturation", 1)
        hdrBoost = num("imm.hdrBoost", 0)
        roomDim = num("imm.roomDim", 1)
    }

    var pictureIsNeutral: Bool { brightness == 0 && contrast == 1 && saturation == 1 && hdrBoost == 0 }

    func resetPicture() { brightness = 0; contrast = 1; saturation = 1; hdrBoost = 0 }

    var screenHeight: Double { width / aspect }

    /// Defaults for size and shape, then the screen is put back on the current gaze line.
    func reset() {
        width = Self.defaultWidth; distance = Self.defaultDistance
        height = 0; curvature = Self.defaultCurve
        recentreRequest += 1
    }

    /// Put the screen on the line the user is looking along right now, at the current distance:
    /// yaw from the horizontal heading, tilt from the pitch (so lying down and looking at the
    /// ceiling puts the screen above you, facing down). Height offset is cleared.
    func recentre(headPosition p: SIMD3<Float>, headForward f: SIMD3<Float>) {
        headPosition = p
        let fh = SIMD3<Float>(f.x, 0, f.z)
        if simd_length(fh) > 0.01 {
            yaw = Double(atan2(-fh.x, -fh.z) * 180 / .pi)
        }
        tilt = Double(asin(max(-1, min(1, f.y))) * 180 / .pi)
        height = 0
        DiagLog.log(String(format: "recentre: head (%.2f, %.2f, %.2f) yaw %.0f° pitch %.0f°", p.x, p.y, p.z, yaw, tilt), "immersive")
    }

    /// Yaw (around Y) then tilt (around X). Positive tilt raises the screen above the eye line
    /// and turns it to face down at the viewer; negative lowers it.
    var orientation: simd_quatf {
        let y = simd_quatf(angle: Float(yaw * .pi / 180), axis: [0, 1, 0])
        let t = simd_quatf(angle: Float(tilt * .pi / 180), axis: [1, 0, 0])
        return y * t
    }

    /// Screen centre: `distance` along the tilted gaze line from the head, plus the height offset.
    var position: SIMD3<Float> {
        let t = Float(tilt * .pi / 180)
        let yawQ = simd_quatf(angle: Float(yaw * .pi / 180), axis: [0, 1, 0])
        let ahead = yawQ.act(SIMD3<Float>(0, 0, -Float(distance) * cos(t)))
        return SIMD3<Float>(headPosition.x, headPosition.y, headPosition.z) + ahead + SIMD3<Float>(0, Float(distance) * sin(t) + Float(height), 0)
    }
}
#endif
