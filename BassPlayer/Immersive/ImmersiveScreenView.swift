#if os(visionOS)
import SwiftUI
import RealityKit
import AVFoundation
import ARKit

/// The cinema: a black void with a very large screen and nothing else. While it is open the
/// player window is dismissed (playback lives in `LibraryStore.playback`, not in the window);
/// a floating glass control panel under the screen appears on tap and fades while playing;
/// subtitles float just below the picture. Leaving the cinema brings the window back.
///
/// Rendering: the active player pushes every decoded frame through `ImmersiveScreenBridge`
/// into an `ImmersiveFrameFeed`, whose `AVSampleBufferVideoRenderer` backs a RealityKit
/// `VideoMaterial` on the screen mesh (flat / curved / VR sphere). Side-by-side and over-under
/// 3D is declared on the frames themselves (Apple Projected Media Profile view packing), so the
/// system renders one eye per lens. MV-HEVC via the AVPlayer backend uses RealityKit's own
/// `VideoPlayerComponent`.
struct ImmersiveScreenView: View {
    @EnvironmentObject private var model: ImmersiveScreenModel
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var screen = ModelEntity()
    @State private var videoEntity = Entity()
    @State private var root = Entity()
    @State private var dome = ModelEntity()
    @State private var tapCatcher = ModelEntity()
    /// Head-relative anchor for the control panel (yaw only), ~1.3 m in front, below eye level.
    @State private var hud = Entity()
    @State private var state = ScreenState()
    @State private var dragStart: SIMD3<Float>?
    @State private var scaleStart: Double?
    @State private var showControls = true
    @State private var hideTask: Task<Void, Never>?

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
        var controls: Entity?
        var subtitles: Entity?
        var lastAspectLog = ""
    }

    /// Marks the entities a tap on which shows/hides the panel (not the panel itself).
    struct TapToggleComponent: Component {}

    private static let controlsID = "controls"
    private static let subtitlesID = "subtitles"
    /// SwiftUI points per metre for RealityView attachments at scale 1.
    private static let pointsPerMetre: Float = 1360

    var body: some View {
        RealityView { content, attachments in
            TapToggleComponent.registerComponent()
            // Black dome around the viewer. Radius is far beyond the visible/rendered area so
            // there is no horizon, seam or edge fall-off anywhere in either lens, whatever the
            // immersion style. Negative X scale turns the sphere inside-out so we see its inner face.
            dome.model = ModelComponent(mesh: .generateSphere(radius: 200), materials: [UnlitMaterial(color: .black)])
            dome.scale = [-1, 1, 1]
            content.add(dome)
            root.addChild(screen)
            root.addChild(videoEntity)
            // Invisible wall behind the screen so a tap anywhere around it toggles the controls.
            tapCatcher.components.set(InputTargetComponent())
            tapCatcher.components.set(CollisionComponent(shapes: [.generateBox(width: 60, height: 40, depth: 0.05)]))
            tapCatcher.components.set(TapToggleComponent())
            tapCatcher.position = [0, 0, -1.5]
            root.addChild(tapCatcher)
            content.add(root)
            content.add(hud)

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
            screen.components.set(TapToggleComponent())
            screen.generateCollisionShapes(recursive: false)
            bindBridge()

            if let controls = attachments.entity(for: Self.controlsID) {
                state.controls = controls
                hud.addChild(controls)
            }
            if let subs = attachments.entity(for: Self.subtitlesID) {
                state.subtitles = subs
                root.addChild(subs)
            }
            placeAttachments()

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
        } update: { _, _ in
            applyMesh(force: false)
            applyTransform()
            applyDome()
            placeAttachments()
            screen.generateCollisionShapes(recursive: false)
            state.controls?.isEnabled = showControls
        } attachments: {
            Attachment(id: Self.controlsID) {
                ImmersiveControlPanel(debugLine: debugLine, onInteract: { scheduleHide() })
            }
            Attachment(id: Self.subtitlesID) {
                SubtitleOverlay(model: library.playback.coordinator.subtitleModel, fontSize: 44)
                    .frame(width: 1800, height: 360, alignment: .bottom)
            }
        }
        .onChange(of: model.recentreRequest) { _, _ in recentre() }
        .onChange(of: library.playback.state) { _, s in
            if s == .bufferFinished { scheduleHide() } else { showControls = true }
        }
        .gesture(tapGesture)
        .simultaneousGesture(dragGesture)
        .simultaneousGesture(magnifyGesture)
        .onAppear {
            model.isOpen = true
            showControls = true
            scheduleHide()
            // The picture lives here now: close the player window, keep the film running.
            if library.playback.isActive {
                library.playback.detachedForImmersive = true
                dismissWindow(id: PlayerWindow.id)
            }
            DiagLog.log("cinema screen opened (playback active: \(library.playback.isActive))", "immersive")
        }
        .onDisappear {
            model.isOpen = false
            ImmersiveScreenBridge.shared.pushFrame = nil
            state.feed?.flush()
            let playback = library.playback
            let wasDetached = playback.detachedForImmersive
            playback.detachedForImmersive = false
            if wasDetached, let item = playback.item {
                openWindow(id: PlayerWindow.id, value: item)
            }
            DiagLog.log("cinema screen closed (pushed \(state.feed?.pushed ?? 0), dropped \(state.feed?.dropped ?? 0), reopen window: \(wasDetached && playback.item != nil))", "immersive")
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

    private func scheduleHide() {
        showControls = true
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            if library.playback.state == .bufferFinished { showControls = false }
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

        // Follow the eye aspect once we know the frame size (clamped: a bad value makes the
        // screen a sliver or a tower, which is worse than a wrong aspect).
        let (w, h) = feed.frameSize
        if w > 0, h > 0 {
            let raw = bridge.stereoFormat.displayAspect(frameWidth: Double(w), frameHeight: Double(h))
            let a = min(4.0, max(1.0, raw))
            if abs(a - model.aspect) > 0.01 {
                model.aspect = a
                let msg = "aspect \(String(format: "%.3f", raw)) → \(String(format: "%.3f", a)) from \(w)x\(h) stereo=\(bridge.stereoFormat.rawValue)"
                if msg != state.lastAspectLog { state.lastAspectLog = msg; DiagLog.log(msg, "immersive") }
            }
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

    /// Control panel ~1.3 m in front of the viewer, below eye level, facing them (yaw from the
    /// screen so it sits under the picture); subtitles just inside the screen's bottom edge,
    /// scaled with the screen.
    private func placeAttachments() {
        let vr = ImmersiveScreenBridge.shared.projection.isImmersiveVideo
        let halfH = vr ? 0.9 : Float(model.screenHeight) / 2
        let yawQ = simd_quatf(angle: Float(model.yaw * .pi / 180), axis: [0, 1, 0])
        let head = model.headPosition
        hud.position = SIMD3<Float>(head.x, 0, head.z) + yawQ.act(SIMD3<Float>(0, 0, -1.35)) + SIMD3<Float>(0, head.y - 0.45, 0)
        hud.orientation = yawQ * simd_quatf(angle: -0.35, axis: [1, 0, 0])
        if let c = state.controls {
            c.scale = SIMD3<Float>(repeating: 1)
            c.position = .zero
            c.orientation = simd_quatf(angle: 0, axis: [1, 0, 0])
        }
        if let subs = state.subtitles {
            let k = vr ? max(0.8, Float(model.distance) / 2.2) : Float(model.width) * 0.8 / (1800 / Self.pointsPerMetre)
            subs.scale = SIMD3<Float>(repeating: k)
            subs.position = [0, -halfH + (360 / Self.pointsPerMetre) * k / 2 + 0.05 * k, vr ? -Float(model.distance) + 0.2 : 0.03]
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

    private var tapGesture: some Gesture {
        SpatialTapGesture()
            .targetedToEntity(where: .has(TapToggleComponent.self))
            .onEnded { _ in
                if showControls { showControls = false; hideTask?.cancel() } else { scheduleHide() }
            }
    }

    /// One line of live state for the panel (the log is the full story).
    private var debugLine: String {
        let f = state.feed
        let (w, h) = f?.frameSize ?? (0, 0)
        let st = f.map { "\($0.renderer.status.rawValue)" } ?? "-"
        return String(format: "frames %d (dropped %d) · %dx%d · aspect %.2f · screen %.1f×%.1f m @ %.1f m · tilt %.0f° · renderer %@%@",
                      f?.pushed ?? 0, f?.dropped ?? 0, w, h, model.aspect, model.width, model.screenHeight, model.distance, model.tilt, st,
                      f?.lastError.map { " · \($0)" } ?? "")
    }

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
                model.width = min(14, max(1, s * Double(value.magnification)))
            }
            .onEnded { _ in scaleStart = nil }
    }

}

/// The floating panel under the cinema screen: transport + menus, screen size / distance,
/// recentre, exit, stop.
struct ImmersiveControlPanel: View {
    var debugLine: String = ""
    var onInteract: () -> Void = {}
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var model: ImmersiveScreenModel
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    var body: some View {
        VStack(spacing: 14) {
            if let item = library.playback.item, let session = library.playback.session {
                HStack(spacing: 14) {
                    Text(item.title).font(.title3.weight(.semibold)).lineLimit(1)
                    Spacer()
                    BassStatusChip(session: session)
                    StopButton {
                        // Close the cinema first; the player window comes back and finishes the stop.
                        DiagLog.log("stop pressed (cinema)", "player")
                        library.playback.stopAfterCinema = true
                        Task { await dismissImmersiveSpace() }
                    }
                }
                TransportBar(item: item, playback: library.playback, session: session)
            } else {
                HStack {
                    Text("Nothing playing").font(.title3).foregroundStyle(.secondary)
                    Spacer()
                    Button { Task { await dismissImmersiveSpace() } } label: { Label("Exit cinema", systemImage: "rectangle.on.rectangle") }
                        .buttonStyle(.borderedProminent)
                }
            }
            HStack(spacing: 14) {
                Label("Size", systemImage: "arrow.up.left.and.arrow.down.right")
                Slider(value: $model.width, in: 1...14).frame(width: 170)
                Label("Distance", systemImage: "arrow.left.and.right")
                Slider(value: $model.distance, in: 1...10).frame(width: 170)
                Label("Curve", systemImage: "rectangle.portrait.and.arrow.right")
                Slider(value: $model.curvature, in: 0...1).frame(width: 120)
                Button("Recentre") { model.recentreRequest += 1 }
                Button("Reset") { model.reset() }
                Spacer()
                Button {
                    Task { await dismissImmersiveSpace() }
                } label: {
                    Label("Exit cinema", systemImage: "rectangle.on.rectangle")
                }
                .buttonStyle(.borderedProminent)
            }
            .font(.callout)
            .labelStyle(.iconOnly)
            if !debugLine.isEmpty {
                Text(debugLine).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(24)
        .frame(width: 1240)
        .glassBackgroundEffect()
        .onChange(of: model.width) { _, _ in onInteract() }
        .onChange(of: model.distance) { _, _ in onInteract() }
        .onChange(of: model.curvature) { _, _ in onInteract() }
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
                Label(model.isOpen ? "Exit cinema" : "Cinema", systemImage: "rectangle.inset.filled.on.rectangle")
            }
        }
        .help(model.isOpen ? "Exit cinema" : "Cinema screen")
    }
}

/// Screen placement, picture and room controls (sheet from the player window).
struct ImmersiveScreenSettings: View {
    @EnvironmentObject private var model: ImmersiveScreenModel

    var body: some View {
        Form {
            Section("Screen") {
                LabeledSlider("Width", value: $model.width, range: 1...14, unit: "m")
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
