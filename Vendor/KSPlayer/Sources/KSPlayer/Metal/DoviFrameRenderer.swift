//
//  DoviFrameRenderer.swift
//  KSPlayer (vendored fork, Bass Player)
//
//  Lets a host render the player's current frame — with Dolby Vision profile 5 mapping applied —
//  into its own Metal texture, e.g. for a RealityKit screen that can't use the player view.
//
import CoreVideo
import Foundation
import Metal

@MainActor
public final class DoviFrameRenderer {
    private let render = MetalRender()
    private var texture: MTLTexture?

    public init() {}

    /// True when `frame` needs the Dolby Vision mapping (profile 5 style base layer).
    public static func needsMapping(_ frame: VideoVTBFrame) -> Bool {
        frame.dovi?.needsMapping == true
    }

    /// Output pixel format of `render(frame:)` textures: 10-bit, PQ-encoded BT.2020.
    public static let outputPixelFormat: MTLPixelFormat = .bgr10a2Unorm

    /// Renders the frame into an internal texture (reused while the size is unchanged) and returns it.
    /// Returns nil when the frame has no renderable pixel buffer.
    public func render(frame: VideoVTBFrame) -> MTLTexture? {
        guard let pixelBuffer = frame.corePixelBuffer else { return nil }
        let w = Int(pixelBuffer.width), h = Int(pixelBuffer.height)
        guard w > 0, h > 0 else { return nil }
        if texture == nil || texture!.width != w || texture!.height != h {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.outputPixelFormat, width: w, height: h, mipmapped: false)
            desc.usage = [.renderTarget, .shaderRead]
            desc.storageMode = .private
            texture = MetalRender.device.makeTexture(descriptor: desc)
        }
        guard let texture else { return nil }
        render.render(pixelBuffer: pixelBuffer, into: texture, dovi: frame.dovi?.needsMapping == true ? frame.dovi : nil)
        return texture
    }
}
