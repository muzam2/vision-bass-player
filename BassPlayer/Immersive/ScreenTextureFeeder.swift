#if os(visionOS)
import Foundation
import RealityKit
import CoreImage
import CoreVideo
import Metal

/// Copies decoded video frames into RealityKit textures every render tick. CoreImage does the
/// YUV→RGB and HDR colour handling, so NV12, P010 (10-bit HDR10/HLG), BGRA and friends all work.
/// For packed 3D (side-by-side / top-bottom) it crops each eye into its own texture.
@MainActor
final class ScreenTextureFeeder {
    /// Left eye (or the whole picture for 2D).
    private(set) var leftTexture: TextureResource?
    /// Right eye; only populated for packed stereo.
    private(set) var rightTexture: TextureResource?

    private var leftQueue: TextureResource.DrawableQueue?
    private var rightQueue: TextureResource.DrawableQueue?
    private var queueSize: (Int, Int) = (0, 0)
    private var queueStereo = false
    private let device = MTLCreateSystemDefaultDevice()!
    private lazy var ciContext = CIContext(mtlDevice: device, options: [
        .cacheIntermediates: false,
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) as Any,
        .workingFormat: CIFormat.RGBAh,
    ])
    private var lastFrameId: Int?
    private(set) var frameCount = 0
    /// Set by the view once textures have been bound to the screen material.
    var materialApplied = false
    /// Bumped whenever the texture objects change (view must rebind the material).
    private(set) var textureGeneration = 0

    /// True → 16-bit float drawables (HDR passes through to the display). False → 8-bit sRGB.
    var hdr = true

    /// Pixel size of the full source frame as last seen (for aspect calculations).
    private(set) var sourceSize: (Int, Int) = (0, 0)

    /// Called once per RealityKit frame. Cheap when there is no new video frame.
    func tick(frameSource: (() -> ScreenFrame?)?, stereo: StereoFormat) {
        guard let source = frameSource, let frame = source() else { return }
        if frame.id == lastFrameId { return }
        lastFrameId = frame.id

        let image: CIImage
        let w: Int, h: Int
        if let pb = frame.pixelBuffer {
            w = CVPixelBufferGetWidth(pb); h = CVPixelBufferGetHeight(pb)
            image = CIImage(cvPixelBuffer: pb)
        } else if let tex = frame.pqTexture {
            w = tex.width; h = tex.height
            let pq = CGColorSpace(name: CGColorSpace.itur_2100_PQ) ?? CGColorSpaceCreateDeviceRGB()
            guard let ci = CIImage(mtlTexture: tex, options: [.colorSpace: pq]) else { return }
            image = ci.oriented(.downMirrored)   // Metal textures are top-left origin; CI is bottom-left
        } else {
            return
        }
        guard w > 0, h > 0 else { return }
        sourceSize = (w, h)

        let packed = stereo.isPacked
        // Eye crop rects in CI coordinates (origin bottom-left).
        let leftRect = ciRect(stereo.leftEyeRect, w: w, h: h)
        let rightRect = ciRect(stereo.rightEyeRect, w: w, h: h)
        let eyeW = Int(leftRect.width), eyeH = Int(leftRect.height)

        if queueSize != (eyeW, eyeH) || queueStereo != packed || leftQueue == nil {
            rebuildQueues(width: eyeW, height: eyeH, stereo: packed)
        }
        let colorSpace = hdr
            ? (CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) ?? CGColorSpaceCreateDeviceRGB())
            : (CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB())

        if let q = leftQueue, let drawable = try? q.nextDrawable() {
            let eye = image.cropped(to: leftRect).transformed(by: .init(translationX: -leftRect.minX, y: -leftRect.minY))
            ciContext.render(eye, to: drawable.texture, commandBuffer: nil, bounds: eye.extent, colorSpace: colorSpace)
            drawable.present()
        }
        if packed, let q = rightQueue, let drawable = try? q.nextDrawable() {
            let eye = image.cropped(to: rightRect).transformed(by: .init(translationX: -rightRect.minX, y: -rightRect.minY))
            ciContext.render(eye, to: drawable.texture, commandBuffer: nil, bounds: eye.extent, colorSpace: colorSpace)
            drawable.present()
        }
        frameCount += 1
    }

    /// Unit rect with top-left origin → CI pixel rect with bottom-left origin.
    private func ciRect(_ r: CGRect, w: Int, h: Int) -> CGRect {
        let W = CGFloat(w), H = CGFloat(h)
        return CGRect(x: r.minX * W, y: (1 - r.maxY) * H, width: r.width * W, height: r.height * H).integral
    }

    private func rebuildQueues(width: Int, height: Int, stereo: Bool) {
        let format: MTLPixelFormat = hdr ? .rgba16Float : .bgra8Unorm_srgb
        func makeQueue() throws -> TextureResource.DrawableQueue {
            let desc = TextureResource.DrawableQueue.Descriptor(pixelFormat: format, width: width, height: height,
                                                                usage: [.shaderRead, .renderTarget], mipmapsMode: .none)
            let q = try TextureResource.DrawableQueue(desc)
            q.allowsNextDrawableTimeout = true
            return q
        }
        func seedTexture() throws -> TextureResource {
            try TextureResource(dimensions: .dimensions(width: 1, height: 1),
                                format: .raw(pixelFormat: .bgra8Unorm),
                                contents: .init(mipmapLevels: [.mip(data: Data([0, 0, 0, 255]), bytesPerRow: 4)]))
        }
        do {
            let lq = try makeQueue()
            if leftTexture == nil { leftTexture = try seedTexture(); textureGeneration += 1 }
            leftTexture?.replace(withDrawables: lq)
            leftQueue = lq
            if stereo {
                let rq = try makeQueue()
                if rightTexture == nil { rightTexture = try seedTexture(); textureGeneration += 1 }
                rightTexture?.replace(withDrawables: rq)
                rightQueue = rq
            } else {
                rightQueue = nil
            }
            queueSize = (width, height)
            queueStereo = stereo
        } catch {
            print("ScreenTextureFeeder: drawable queue failed (\(error)); falling back to 8-bit")
            if hdr { hdr = false; rebuildQueues(width: width, height: height, stereo: stereo) }
        }
    }
}
#endif
