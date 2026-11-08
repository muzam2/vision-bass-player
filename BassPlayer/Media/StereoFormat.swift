import Foundation
import CoreGraphics

/// How a 3D film is packed. Detected from server metadata and file names; the user can override.
enum StereoFormat: String, CaseIterable, Identifiable, Codable {
    case auto          // use detection (only meaningful as a user choice)
    case mono          // force 2D
    case sbsHalf       // half-width side-by-side (most common 3D rips, 1920×1080 frame)
    case sbsFull       // full-width side-by-side (3840×1080 frame)
    case tabHalf       // half-height top-and-bottom
    case tabFull       // full-height top-and-bottom
    case mvHEVC        // Apple spatial / MV-HEVC (two coded views; AVPlayer renders it)
    case mvcPacked     // Blu-ray 3D MVC: decoded by edge264-mvc into full SBS (base | dependent); 2D if that fails

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .mono: return "2D"
        case .sbsHalf: return "3D · Half SBS"
        case .sbsFull: return "3D · Full SBS"
        case .tabHalf: return "3D · Half TAB"
        case .tabFull: return "3D · Full TAB"
        case .mvHEVC: return "3D · MV-HEVC"
        case .mvcPacked: return "3D · MVC (Blu-ray)"
        }
    }

    /// True for formats where one frame contains both eyes side by side / stacked.
    var isPacked: Bool {
        switch self {
        case .sbsHalf, .sbsFull, .tabHalf, .tabFull: return true
        default: return false
        }
    }

    var isStereo: Bool { isPacked || self == .mvHEVC }

    /// Normalised rect of the LEFT eye within a packed frame (texture space, origin top-left).
    var leftEyeRect: CGRect {
        switch self {
        case .sbsHalf, .sbsFull: return CGRect(x: 0, y: 0, width: 0.5, height: 1)
        case .tabHalf, .tabFull: return CGRect(x: 0, y: 0, width: 1, height: 0.5)
        default: return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
    }

    var rightEyeRect: CGRect {
        switch self {
        case .sbsHalf, .sbsFull: return CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        case .tabHalf, .tabFull: return CGRect(x: 0, y: 0.5, width: 1, height: 0.5)
        default: return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
    }

    /// Display aspect of ONE eye given the packed frame's pixel aspect.
    func displayAspect(frameWidth: Double, frameHeight: Double) -> Double {
        guard frameWidth > 0, frameHeight > 0 else { return 16.0 / 9.0 }
        let frame = frameWidth / frameHeight
        switch self {
        case .sbsHalf, .tabHalf: return frame          // squeezed by 2, so the full frame aspect is the eye aspect
        case .sbsFull: return frame / 2
        case .tabFull: return frame * 2
        default: return frame
        }
    }

    // MARK: - Detection

    /// Jellyfin `Video3DFormat` values.
    static func fromJellyfin(_ s: String?) -> StereoFormat? {
        switch s?.lowercased() {
        case "halfsidebyside": return .sbsHalf
        case "fullsidebyside": return .sbsFull
        case "halftopandbottom": return .tabHalf
        case "fulltopandbottom": return .tabFull
        case "mvc": return .mvcPacked
        default: return nil
        }
    }

    /// Best guess from file name / title tokens and the frame size. Conservative: returns nil
    /// unless something explicitly says 3D.
    static func detect(name: String?, path: String?, width: Int?, height: Int?, codecTag: String?) -> StereoFormat? {
        let text = ((name ?? "") + " " + (path ?? "")).lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        let tokens = Set(text.split(separator: " ").map(String.init))
        func has(_ t: String...) -> Bool { t.contains { tokens.contains($0) } }

        if has("mvhevc", "mv hevc", "spatial") || text.contains("mv hevc") || (codecTag ?? "").lowercased().contains("hvc1") && text.contains("spatial") {
            return .mvHEVC
        }
        let says3D = has("3d") || text.contains(" 3d ")
        if has("hsbs", "h sbs", "halfsbs", "half sbs", "sbs50") || text.contains("half sbs") { return .sbsHalf }
        if has("fsbs", "fullsbs") || text.contains("full sbs") { return .sbsFull }
        if has("hou", "htab", "halfou", "half ou", "half tab") || text.contains("half ou") { return .tabHalf }
        if has("fou", "ftab", "fullou", "full ou", "full tab") { return .tabFull }
        if has("mvc", "frame packed", "framepacked") { return .mvcPacked }
        if has("sbs") { return (width ?? 0) >= 3000 ? .sbsFull : .sbsHalf }
        if has("ou", "tab") && says3D { return (height ?? 0) >= 1900 ? .tabFull : .tabHalf }
        if says3D, let w = width, let h = height, h > 0 {
            let ar = Double(w) / Double(h)
            if ar > 3.0 { return .sbsFull }          // e.g. 3840×1080
            if ar < 1.0 { return .tabFull }          // e.g. 1920×2160
            return .sbsHalf                          // "3D" with a normal frame: assume half SBS
        }
        return nil
    }
}
