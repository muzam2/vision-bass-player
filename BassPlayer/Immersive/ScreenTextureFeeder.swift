#if os(visionOS)
import Foundation
import RealityKit
import CoreImage
import CoreVideo
import Metal

/// Copies decoded video frames (CVPixelBuffer from KSPlayer / VideoToolbox) into a RealityKit
/// texture every render tick. CoreImage does the YUV→RGB and HDR colour handling for us, so
/// NV12, P010 (10-bit HDR10/HLG), BGRA and friends all work without custom shaders.
@MainActor
final class ScreenTextureFeeder {
    private(set) var texture: TextureResource?
    private var queue: TextureResource.DrawableQueue?
    private var queueSize: (Int, Int) = (0, 0)
    private let device = MTLCreateSystemDefaultDevice()!
    private lazy var ciContext = CIContext(mtlDevice: device, options: [
        .cacheIntermediates: false,
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) as Any,
        .workingFormat: CIFormat.RGBAh,
    ])
    private var lastFrameId: Int?
    private(set) var frameCount = 0
    /// Set by the view once the texture has been bound to the screen material.
    var materialApplied = false

    /// True → 16-bit float drawables (HDR passes through to the display). False → 8-bit sRGB.
    var hdr = true

    /// Called once per RealityKit frame. Cheap when there is no new video frame.
    func tick(frameSource: (() -> ScreenFrame?)?) {
        guard let source = frameSource, let frame = source() else { return }
        // Skip if the player handed us the same frame as last tick.
        if frame.id == lastFrameId { return }
        lastFrameId = frame.id

        let image: CIImage
        let w: Int, h: Int
        if let pb = frame.pixelBuffer {
            w = CVPixelBufferGetWidth(pb); h = CVPixelBufferGetHeight(pb)
            image = CIImage(cvPixelBuffer: pb)
        } else if let tex = frame.pqTexture {
            // Dolby Vision frames arrive pre-mapped as PQ BT.2020; tell CoreImage so it linearises correctly.
            w = tex.width; h = tex.height
            let pq = CGColorSpace(name: CGColorSpace.itur_2100_PQ) ?? CGColorSpaceCreateDeviceRGB()
            guard let ci = CIImage(mtlTexture: tex, options: [.colorSpace: pq]) else { return }
            image = ci.oriented(.downMirrored)   // Metal textures are top-left origin; CI is bottom-left
        } else {
            return
        }
        guard w > 0, h > 0 else { return }
        if queueSize != (w, h) || queue == nil {
            rebuildQueue(width: w, height: h)
        }
        guard let queue, let drawable = try? queue.nextDrawable() else { return }

        let colorSpace = hdr
            ? (CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) ?? CGColorSpaceCreateDeviceRGB())
            : (CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB())
        ciContext.render(image, to: drawable.texture, commandBuffer: nil, bounds: image.extent, colorSpace: colorSpace)
        drawable.present()
        frameCount += 1
    }

    private func rebuildQueue(width: Int, height: Int) {
        let format: MTLPixelFormat = hdr ? .rgba16Float : .bgra8Unorm_srgb
        let desc = TextureResource.DrawableQueue.Descriptor(
            pixelFormat: format,
            width: width,
            height: height,
            usage: [.shaderRead, .renderTarget],
            mipmapsMode: .none
        )
        do {
            let q = try TextureResource.DrawableQueue(desc)
            q.allowsNextDrawableTimeout = true
            if let texture {
                texture.replace(withDrawables: q)
            } else {
                // Seed with a 1×1 black texture, then swap in the drawable queue.
                let seed = try TextureResource(dimensions: .dimensions(width: 1, height: 1),
                                               format: .raw(pixelFormat: .bgra8Unorm),
                                               contents: .init(mipmapLevels: [
                                                   .mip(data: Data([0, 0, 0, 255]), bytesPerRow: 4)
                                               ]))
                seed.replace(withDrawables: q)
                texture = seed
            }
            queue = q
            queueSize = (width, height)
        } catch {
            print("ScreenTextureFeeder: drawable queue failed (\(error)); falling back to 8-bit")
            if hdr { hdr = false; rebuildQueue(width: width, height: height) }
        }
    }
}
#endif
