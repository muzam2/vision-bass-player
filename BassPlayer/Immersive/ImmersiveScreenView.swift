#if os(visionOS)
import SwiftUI
import RealityKit
import AVFoundation
import ARKit

/// The cinema screen in an ImmersiveSpace. Drag to move, pinch to resize, two-hand rotate to tilt.
///
/// Rendering: the active player pushes every decoded frame through `ImmersiveScreenBridge`
/// into an `ImmersiveFrameFeed`, whose `AVSampleBufferVideoRenderer` backs a RealityKit
/// `VideoMaterial` on the screen mesh (flat / curved / VR sphere). Side-by-side and over-under
/// 3D is declared on the frames themselves (Apple Projected Media Profile view packing), so the
/// system renders one eye per lens. MV-HEVC via the AVPlayer backend uses RealityKit's own
/// `VideoPlayerComponent`.
struct ImmersiveScreenView: View {
    @EnvironmentObject private var model: ImmersiveScreenModel
    @State private var screen = ModelEntity()
    @State private var videoEntity = Entity()
    @State private var root = Entity()
    @State private var dome = ModelEntity()
    @State private var state = ScreenState()
    @State private var dragStart: SIMD3<Float>?
    @State private var scaleStart: Double?
    @State private var tiltStart: Double?

    /// Mutable bookkeeping shared with the RealityKit update closure.
    final class ScreenState {
        var feed: ImmersiveFrameFeed?
        var material: VideoMaterial?
        var lastMeshKey = ""
        var lastDomeDim: Double = -1
        var lastProjection: ScreenProjection = .flat
        var arSession: ARKitSession?
        var worldTracking: WorldTrackingProvider?
        var avPlayerBound: AVPlayer?
        var lastStatusLog = Date.distantPast
    }

    var body: some View {
        RealityView { content in
            // Black dome around the viewer. Radius is far beyond the visible/rendered area so
            // there is no horizon, seam or edge fall-off anywhere in either lens, whatever the
            // immersion style. Negative X scale turns the sphere inside-out so we see its inner face.
            dome.model = ModelComponent(mesh: .generateSphere(radius: 200), materials: [UnlitMaterial(color: .black)])
            dome.scale = [-1, 1, 1]
            content.add(dome)
            root.addChild(screen)
            root.addChild(videoEntity)
            content.add(root)

            if let feed = ImmersiveFrameFeed() {
                state.feed = feed
                state.material = VideoMaterial(videoRenderer: feed.renderer)
                DiagLog.log("video material created", "immersive")
            } else {
                DiagLog.log("no Metal device; cinema screen cannot render", "immersive")
            }
            applyMesh(force: true)
            applyTransform()
            screen.components.set(InputTargetComponent())
            screen.generateCollisionShapes(recursive: false)
            bindBridge()

            // Head tracking for recentre; the device anchor needs no user permission.
            Task { @MainActor in
                let session = ARKitSession()
                let world = WorldTrackingProvider()
                do {
                    try await session.run([world])
                    state.arSession = session
                    state.worldTracking = world
                    try? await Task.sleep(for: .milliseconds(300))
                    recentre()
                } catch {
                    DiagLog.log("world tracking unavailable (\(error))", "immersive")
                }
            }

            _ = content.subscribe(to: SceneEvents.Update.self) { _ in
                MainActor.assumeIsolated { frameTick() }
            }
        } update: { _ in
            applyMesh(force: false)
            applyTransform()
            applyDome()
            screen.generateCollisionShapes(recursive: false)
        }
        .onChange(of: model.recentreRequest) { _, _ in recentre() }
        .gesture(dragGesture)
        .simultaneousGesture(magnifyGesture)
        .simultaneousGesture(rotateGesture)
        .onAppear {
            model.isOpen = true
            DiagLog.log("cinema screen opened", "immersive")
        }
        .onDisappear {
            model.isOpen = false
            ImmersiveScreenBridge.shared.pushFrame = nil
            state.feed?.flush()
            DiagLog.log("cinema screen closed (pushed \(state.feed?.pushed ?? 0), dropped \(state.feed?.dropped ?? 0))", "immersive")
        }
    }

    /// Route the player's frames into the feed.
    private func bindBridge() {
        guard let feed = state.feed else { return }
        ImmersiveScreenBridge.shared.pushFrame = { pixelBuffer, time, doviTexture in
            MainActor.assumeIsolated {
                feed.push(pixelBuffer: pixelBuffer, time: time, doviTexture: doviTexture)
            }
        }
    }

    // MARK: - Per-frame

    private func frameTick() {
        let bridge = ImmersiveScreenBridge.shared

        // MV-HEVC / AVPlayer path: let RealityKit render the video (stereo if the file has it).
        if let player = bridge.avPlayer {
            if state.avPlayerBound !== player {
                var comp = VideoPlayerComponent(avPlayer: player)
                comp.desiredViewingMode = .stereo
                comp.isPassthroughTintingEnabled = false
                videoEntity.components.set(comp)
                state.avPlayerBound = player
                screen.isEnabled = false
                videoEntity.isEnabled = true
                DiagLog.log("AVPlayer video component bound", "immersive")
            }
            // VideoPlayerComponent renders 1 m tall; scale to the configured screen size.
            let h = Float(model.screenHeight)
            videoEntity.scale = [h, h, 1]
            return
        } else if state.avPlayerBound != nil {
            videoEntity.components.remove(VideoPlayerComponent.self)
            state.avPlayerBound = nil
            videoEntity.isEnabled = false
            screen.isEnabled = true
        }

        guard let feed = state.feed else { return }
        if feed.stereo != bridge.stereoFormat { feed.stereo = bridge.stereoFormat }
        if feed.projection != bridge.projection { feed.projection = bridge.projection }
        if bridge.projection != state.lastProjection {
            state.lastProjection = bridge.projection
            applyMesh(force: true)
            applyTransform()
        }

        // Follow the eye aspect once we know the frame size.
        let (w, h) = feed.frameSize
        if w > 0, h > 0 {
            let a = bridge.stereoFormat.displayAspect(frameWidth: Double(w), frameHeight: Double(h))
            if abs(a - model.aspect) > 0.01 { model.aspect = a }
        }

        let now = Date()
        if now.timeIntervalSince(state.lastStatusLog) > 10 {
            state.lastStatusLog = now
            DiagLog.log("status: pushed \(feed.pushed) dropped \(feed.dropped) frame \(w)x\(h) renderer \(feed.renderer.status.rawValue) ready \(feed.renderer.isReadyForMoreMediaData) src \(bridge.pushFrame == nil ? "unbound" : "bound")", "immersive")
        }
    }

    // MARK: - Geometry

    private func applyMesh(force: Bool) {
        let projection = ImmersiveScreenBridge.shared.projection
        let key = "\(projection.rawValue)-\(model.width)-\(model.screenHeight)-\(model.curvature)-\(model.flipV)"
        guard force || key != state.lastMeshKey else { return }
        state.lastMeshKey = key
        let mesh: MeshResource
        switch projection {
        case .flat:
            mesh = ScreenMesh.make(width: Float(model.width), height: Float(model.screenHeight),
                                   curvature: Float(model.curvature), flipV: model.flipV)
        case .vr180:
            mesh = ScreenMesh.makeVR(radius: 20, fullSphere: false, flipV: model.flipV)
        case .vr360:
            mesh = ScreenMesh.makeVR(radius: 20, fullSphere: true, flipV: model.flipV)
        }
        let material: any RealityKit.Material
        if let m = state.material { material = m } else { material = UnlitMaterial(color: .black) }
        if screen.model == nil {
            screen.model = ModelComponent(mesh: mesh, materials: [material])
        } else {
            screen.model?.mesh = mesh
        }
    }

    private func applyTransform() {
        if ImmersiveScreenBridge.shared.projection.isImmersiveVideo {
            // VR: sphere centred on the head, yaw only (tilt would tip the horizon).
            root.position = model.headPosition
            root.orientation = simd_quatf(angle: Float(model.yaw * .pi / 180), axis: [0, 1, 0])
        } else {
            // Rotate the offset around the viewer so yaw swings the screen around you.
            let yawQ = simd_quatf(angle: Float(model.yaw * .pi / 180), axis: [0, 1, 0])
            let offset = yawQ.act(SIMD3<Float>(0, 0, -Float(model.distance)))
            root.position = SIMD3<Float>(model.headPosition.x, 0, model.headPosition.z) + offset + SIMD3<Float>(0, Float(model.height), 0)
            root.orientation = model.orientation
        }
    }

    /// Dome opacity follows "room dim" so passthrough can show through in mixed immersion.
    private func applyDome() {
        guard model.roomDim != state.lastDomeDim else { return }
        state.lastDomeDim = model.roomDim
        var m = UnlitMaterial(color: .black)
        m.blending = .transparent(opacity: .init(floatLiteral: Float(model.roomDim)))
        dome.model?.materials = [m]
    }

    /// Place the screen (or VR sphere) straight ahead of where the user is looking now.
    private func recentre() {
        guard let world = state.worldTracking,
              let anchor = world.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()) else { return }
        let t = anchor.originFromAnchorTransform
        let p = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        let f = -SIMD3<Float>(t.columns.2.x, t.columns.2.y, t.columns.2.z)
        model.recentre(headPosition: p, headForward: f)
    }

    // MARK: - Gestures

    private var dragGesture: some Gesture {
        DragGesture()
            .targetedToEntity(screen)
            .onChanged { value in
                if dragStart == nil { dragStart = root.position }
                guard let start = dragStart else { return }
                guard !ImmersiveScreenBridge.shared.projection.isImmersiveVideo else { return }
                let delta = value.convert(value.translation3D, from: .local, to: .scene)
                let p = start + delta - SIMD3<Float>(model.headPosition.x, 0, model.headPosition.z)
                model.distance = Double(max(0.5, simd_length(SIMD2<Float>(p.x, p.z))))
                model.height = Double(p.y)
                model.yaw = Double(atan2(-p.x, -p.z) * 180 / .pi)
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

/// Open / close button for the cinema screen (used by the player chrome).
struct ImmersiveScreenToggle: View {
    @EnvironmentObject private var model: ImmersiveScreenModel
    @Environment(\.openImmersiveSpace) private var openSpace
    @Environment(\.dismissImmersiveSpace) private var dismissSpace
    var compact = false

    var body: some View {
        Button {
            Task {
                if model.isOpen {
                    await dismissSpace()
                } else {
                    let result = await openSpace(id: ImmersiveScreenSpace.id)
                    DiagLog.log("openImmersiveSpace → \(result)", "immersive")
                }
            }
        } label: {
            if compact {
                Image(systemName: model.isOpen ? "rectangle.inset.filled.on.rectangle" : "rectangle.on.rectangle")
            } else {
                Label(model.isOpen ? "Close cinema screen" : "Cinema screen", systemImage: "rectangle.inset.filled.on.rectangle")
            }
        }
    }
}

/// Screen placement, picture and room controls. Shown inline on the player's remote panel
/// (while the cinema screen is open) and in a sheet from the player controls.
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
                HStack {
                    Button("Recentre") { model.recentreRequest += 1 }
                    Button("Reset placement") { model.reset() }
                }
            }
            Section("Picture") {
                Toggle("Flip vertically", isOn: $model.flipV)
                Text("Brightness, contrast and saturation controls return once the native cinema path is confirmed on the headset.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Room") {
                Toggle("Full immersion (hide passthrough)", isOn: $model.darkRoom)
                LabeledSlider("Room dim", value: $model.roomDim, range: 0...1, unit: "")
                    .disabled(model.darkRoom)
            }
        }
        .formStyle(.grouped)
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
