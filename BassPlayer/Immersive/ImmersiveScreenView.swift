#if os(visionOS)
import SwiftUI
import RealityKit

/// The cinema screen in an ImmersiveSpace. Video frames are pulled from whichever player is
/// active via `ImmersiveScreenBridge`. Drag to move, pinch to resize, two-hand rotate to tilt.
struct ImmersiveScreenView: View {
    @EnvironmentObject private var model: ImmersiveScreenModel
    @State private var feeder = ScreenTextureFeeder()
    @State private var screen = ModelEntity()
    @State private var root = Entity()
    @State private var dome = ModelEntity()
    @State private var lastMeshKey = ""
    @State private var dragStart: SIMD3<Float>?
    @State private var scaleStart: Double?
    @State private var tiltStart: Double?

    var body: some View {
        RealityView { content in
            feeder.hdr = model.hdr
            // Black dome around the viewer. Radius is far beyond the visible/rendered area so
            // there is no horizon, seam or edge fall-off anywhere in either lens, whatever the
            // immersion style. Negative X scale turns the sphere inside-out so we see its inner face.
            dome.model = ModelComponent(mesh: .generateSphere(radius: 200), materials: [UnlitMaterial(color: .black)])
            dome.scale = [-1, 1, 1]
            content.add(dome)
            root.addChild(screen)
            content.add(root)
            applyMesh(force: true)
            applyTransform()
            screen.components.set(InputTargetComponent())
            screen.generateCollisionShapes(recursive: false)

            // Pull a new video frame every render tick.
            _ = content.subscribe(to: SceneEvents.Update.self) { _ in
                // Scene updates arrive on the main thread.
                MainActor.assumeIsolated {
                    feeder.tick(frameSource: ImmersiveScreenBridge.shared.frameSource)
                    if let t = feeder.texture, !feeder.materialApplied {
                        var m = UnlitMaterial()
                        m.color = .init(tint: .white, texture: .init(t))
                        screen.model?.materials = [m]
                        feeder.materialApplied = true
                    }
                    // Follow the video's aspect ratio once we know it.
                    if let src = ImmersiveScreenBridge.shared.frameSource, let f = src() {
                        var w = 0, h = 0
                        if let pb = f.pixelBuffer { w = CVPixelBufferGetWidth(pb); h = CVPixelBufferGetHeight(pb) }
                        else if let t = f.pqTexture { w = t.width; h = t.height }
                        if w > 0, h > 0 {
                            let a = Double(w) / Double(h)
                            if abs(a - model.aspect) > 0.01 { model.aspect = a }
                        }
                    }
                }
            }
        } update: { _ in
            applyMesh(force: false)
            applyTransform()
            screen.generateCollisionShapes(recursive: false)
        }
        .gesture(dragGesture)
        .simultaneousGesture(magnifyGesture)
        .simultaneousGesture(rotateGesture)
        .onAppear { model.isOpen = true }
        .onDisappear { model.isOpen = false }
    }

    // MARK: - Geometry

    private func applyMesh(force: Bool) {
        let key = "\(model.width)-\(model.screenHeight)-\(model.curvature)-\(model.flipV)"
        guard force || key != lastMeshKey else { return }
        lastMeshKey = key
        let mesh = ScreenMesh.make(width: Float(model.width), height: Float(model.screenHeight),
                                   curvature: Float(model.curvature), flipV: model.flipV)
        if screen.model == nil {
            var mat = UnlitMaterial(color: .black)
            if let t = feeder.texture { mat.color = .init(tint: .white, texture: .init(t)) }
            screen.model = ModelComponent(mesh: mesh, materials: [mat])
        } else {
            screen.model?.mesh = mesh
        }
    }

    private func applyTransform() {
        root.position = model.position
        root.orientation = model.orientation
    }

    // MARK: - Gestures

    private var dragGesture: some Gesture {
        DragGesture()
            .targetedToEntity(screen)
            .onChanged { value in
                if dragStart == nil { dragStart = root.position }
                guard let start = dragStart else { return }
                let delta = value.convert(value.translation3D, from: .local, to: .scene)
                let p = start + delta
                model.distance = Double(-p.z)
                model.height = Double(p.y)
                // Sideways drags become yaw around the viewer instead of off-centre placement.
                model.yaw = Double(-atan2(p.x, -p.z) * 180 / .pi)
            }
            .onEnded { _ in dragStart = nil }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .targetedToEntity(screen)
            .onChanged { value in
                if scaleStart == nil { scaleStart = model.width }
                guard let s = scaleStart else { return }
                model.width = min(12, max(1, s * Double(value.magnification)))
            }
            .onEnded { _ in scaleStart = nil }
    }

    private var rotateGesture: some Gesture {
        RotateGesture3D(constrainedToAxis: .x)
            .targetedToEntity(screen)
            .onChanged { value in
                if tiltStart == nil { tiltStart = model.tilt }
                guard let t = tiltStart else { return }
                let angle = value.rotation.angle.degrees
                let sign: Double = value.rotation.axis.x >= 0 ? 1 : -1
                model.tilt = max(-60, min(60, t - sign * angle))
            }
            .onEnded { _ in tiltStart = nil }
    }
}

/// Button + settings popover shown in the player on visionOS.
struct ImmersiveScreenToggle: View {
    @EnvironmentObject private var model: ImmersiveScreenModel
    @Environment(\.openImmersiveSpace) private var openSpace
    @Environment(\.dismissImmersiveSpace) private var dismissSpace
    @State private var showSettings = false

    var body: some View {
        HStack(spacing: 12) {
            Button {
                Task {
                    if model.isOpen {
                        await dismissSpace()
                    } else {
                        _ = await openSpace(id: ImmersiveScreenSpace.id)
                    }
                }
            } label: {
                Label(model.isOpen ? "Close cinema screen" : "Cinema screen", systemImage: "rectangle.inset.filled.on.rectangle")
            }
            Button {
                showSettings.toggle()
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .popover(isPresented: $showSettings) {
                ImmersiveScreenSettings().frame(width: 380)
            }
        }
    }
}

struct ImmersiveScreenSettings: View {
    @EnvironmentObject private var model: ImmersiveScreenModel

    var body: some View {
        Form {
            Section("Screen") {
                LabeledSlider("Width", value: $model.width, range: 1...12, unit: "m")
                LabeledSlider("Distance", value: $model.distance, range: 1...10, unit: "m")
                LabeledSlider("Height", value: $model.height, range: -2...3, unit: "m")
                LabeledSlider("Tilt", value: $model.tilt, range: -60...60, unit: "°")
                LabeledSlider("Curve", value: $model.curvature, range: 0...1, unit: "")
                Button("Reset placement") { model.reset() }
            }
            Section("Picture") {
                Toggle("HDR output", isOn: $model.hdr)
                Toggle("Flip vertically", isOn: $model.flipV)
                Toggle("Full immersion (hide passthrough)", isOn: $model.darkRoom)
            }
        }
        .padding()
    }
}

private struct LabeledSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let unit: String
    init(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String) {
        self.label = label; _value = value; self.range = range; self.unit = unit
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack { Text(label); Spacer(); Text(String(format: "%.1f%@", value, unit)).foregroundStyle(.secondary) }
            Slider(value: $value, in: range)
        }
    }
}

enum ImmersiveScreenSpace {
    static let id = "cinema-screen"
}
#endif
