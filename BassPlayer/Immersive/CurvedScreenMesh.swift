#if os(visionOS)
import RealityKit
import simd

enum ScreenMesh {
    /// A flat or cylindrically curved screen facing +Z (towards the viewer), centred at the origin.
    /// `curvature` 0 = flat; 1 = strongly curved (radius ≈ width). Aspect is width:height.
    static func make(width: Float, height: Float, curvature: Float, flipV: Bool = false, segments: Int = 48) -> MeshResource {
        let c = max(0, min(1, curvature))
        if c < 0.01 && !flipV {
            return .generatePlane(width: width, height: height)
        }
        let flat = c < 0.01
        // Arc of a cylinder with vertical axis. Radius shrinks as curvature grows.
        let radius = flat ? 1e6 : width / (0.25 + 2.0 * c)
        let arc = width / radius                       // total angle subtended
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var indices: [UInt32] = []

        for i in 0...segments {
            let t = Float(i) / Float(segments)
            let a = (t - 0.5) * arc                    // −arc/2 … +arc/2
            let x = radius * sin(a)
            let z = radius * (1 - cos(a))              // edges bow towards the viewer (+Z)
            for j in 0...1 {
                let y = (Float(j) - 0.5) * height
                positions.append([x, y, z])
                normals.append([-sin(a), 0, cos(a)])   // towards the viewer
                let v = flipV ? 1 - Float(j) : Float(j)
                uvs.append([t, v])
            }
        }
        for i in 0..<segments {
            let base = UInt32(i * 2)
            // Counter-clockwise as seen from the viewer (+Z) so the front face is not culled.
            indices += [base, base + 2, base + 1, base + 1, base + 2, base + 3]
        }
        var d = MeshDescriptor(name: "curvedScreen")
        d.positions = MeshBuffer(positions)
        d.normals = MeshBuffer(normals)
        d.textureCoordinates = MeshBuffer(uvs)
        d.primitives = .triangles(indices)
        return (try? MeshResource.generate(from: [d])) ?? .generatePlane(width: width, height: height)
    }
}
#endif

#if os(visionOS)
extension ScreenMesh {
    /// Equirectangular VR mesh seen from inside: a full sphere (360°) or the front hemisphere
    /// (180°). `u` runs left→right across the longitude span, `v` bottom→top. Faces point inward.
    static func makeVR(radius: Float, fullSphere: Bool, flipV: Bool = false, segments: Int = 96, rings: Int = 48) -> MeshResource {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var indices: [UInt32] = []
        let lonSpan: Float = fullSphere ? 2 * .pi : .pi
        for r in 0...rings {
            let v = Float(r) / Float(rings)                 // 0 bottom … 1 top
            let lat = (v - 0.5) * .pi                       // −π/2 … +π/2
            for c in 0...segments {
                let u = Float(c) / Float(segments)
                // Longitude: centre of the span looks down −Z (straight ahead).
                let lon = (u - 0.5) * lonSpan
                let x = radius * cos(lat) * sin(lon)
                let y = radius * sin(lat)
                let z = -radius * cos(lat) * cos(lon)
                positions.append([x, y, z])
                normals.append(-simd_normalize(SIMD3<Float>(x, y, z)))
                uvs.append([u, flipV ? 1 - v : v])
            }
        }
        let stride = UInt32(segments + 1)
        for r in 0..<rings {
            for c in 0..<segments {
                let a = UInt32(r) * stride + UInt32(c)
                let b = a + 1
                let d = a + stride
                let e = d + 1
                // Inward-facing winding (viewer is inside the sphere).
                indices += [a, b, d, b, e, d]
            }
        }
        var desc = MeshDescriptor(name: fullSphere ? "vr360" : "vr180")
        desc.positions = MeshBuffer(positions)
        desc.normals = MeshBuffer(normals)
        desc.textureCoordinates = MeshBuffer(uvs)
        desc.primitives = .triangles(indices)
        return (try? MeshResource.generate(from: [desc])) ?? .generateSphere(radius: radius)
    }
}
#endif
