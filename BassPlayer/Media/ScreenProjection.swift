import Foundation

/// How the picture is mapped into space on the Vision Pro: a flat screen, or VR video wrapped
/// on a half or full sphere around you. Detected from file names; user can override.
enum ScreenProjection: String, CaseIterable, Identifiable, Codable {
    case flat, vr180, vr360
    var id: String { rawValue }
    var label: String {
        switch self {
        case .flat: return "Flat screen"
        case .vr180: return "VR 180°"
        case .vr360: return "VR 360°"
        }
    }
    var isImmersiveVideo: Bool { self != .flat }

    /// Conservative detection from name/path tokens. Returns nil when nothing says VR.
    static func detect(name: String?, path: String?) -> ScreenProjection? {
        let text = ((name ?? "") + " " + (path ?? "")).lowercased()
            .replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "-", with: " ")
        let tokens = Set(text.split(separator: " ").map(String.init))
        if tokens.contains("360") || tokens.contains("vr360") || text.contains("equirect") || tokens.contains("mono360") { return .vr360 }
        if tokens.contains("180") || tokens.contains("vr180") || tokens.contains("180x180") || tokens.contains("mkx200") || tokens.contains("fisheye") { return .vr180 }
        return nil
    }

    /// VR files usually say how the eyes are packed: `_LR` / `3dh` = full SBS, `_TB` / `3dv` = full TAB.
    static func detectStereoForVR(name: String?, path: String?) -> StereoFormat? {
        let text = ((name ?? "") + " " + (path ?? "")).lowercased()
            .replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "-", with: " ")
        let tokens = Set(text.split(whereSeparator: { $0 == " " || $0 == "_" }).map(String.init))
        if tokens.contains("lr") || tokens.contains("3dh") || tokens.contains("sbs") { return .sbsFull }
        if tokens.contains("tb") || tokens.contains("3dv") || tokens.contains("ou") { return .tabFull }
        if tokens.contains("mono") { return .mono }
        return nil
    }
}
