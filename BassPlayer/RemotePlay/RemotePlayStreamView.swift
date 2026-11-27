import SwiftUI
import AVFoundation
#if canImport(UIKit)
import UIKit
#endif

/// The stream: the console's picture in a window (visionOS) or full screen (tvOS), with a
/// small control strip. Closing the window ends the session, except when the picture moves to
/// the cinema screen.
struct RemotePlayStreamView: View {
    @ObservedObject private var rp = RemotePlayController.shared
    @AppStorage("rp.showStats") private var showStats = false
    @State private var loginPin = ""
    #if os(visionOS)
    @EnvironmentObject private var immersive: ImmersiveScreenModel
    @Environment(\.openImmersiveSpace) private var openSpace
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var scene: UIWindowScene?
    #endif
    #if os(tvOS)
    @Environment(\.dismiss) private var dismiss
    #endif

    var body: some View {
        ZStack {
            Color.black
            RemotePlayLayerView(sink: rp.frameSink)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
            overlay
            if showStats { statsOverlay }
        }
        .ignoresSafeArea()
        #if os(visionOS)
        .handlesGameControllerEvents(matching: .gamepad)
        .ornament(attachmentAnchor: .scene(.bottom)) { controls.padding(12).glassBackgroundEffect() }
        .background(WindowSceneProbe { s in if let s { scene = s } })
        .onReceive(NotificationCenter.default.publisher(for: UIScene.didDisconnectNotification)) { n in
            guard let scene, (n.object as? UIWindowScene) === scene else { return }
            if !rp.cinemaShowing {
                DiagLog.log("stream window closed; ending the session", "rp")
                rp.disconnect()
            }
        }
        #else
        .overlay(alignment: .bottom) { controls.padding(.bottom, 40) }
        #endif
        .alert("Console passcode", isPresented: Binding(get: { rp.loginPinRequest != nil }, set: { if !$0 { rp.loginPinRequest = nil } })) {
            SecureField("Passcode", text: $loginPin)
            Button("Send") { rp.submitLoginPin(loginPin); loginPin = "" }
            Button("Cancel", role: .cancel) { rp.disconnect() }
        } message: {
            Text(rp.loginPinRequest?.incorrect == true ? "That passcode was wrong. Try again." : "The user on the console has a login passcode.")
        }
    }

    @ViewBuilder
    private var overlay: some View {
        switch rp.state {
        case .waking, .connecting:
            VStack(spacing: 16) {
                ProgressView().controlSize(.large)
                Text(rp.state == .waking ? "Waking \(rp.activeConsole?.displayName ?? "the console")…" : "Connecting…")
                    .font(.title3)
            }
        case .failed(let text):
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                Text(text).multilineTextAlignment(.center).frame(maxWidth: 600)
                HStack {
                    if let c = rp.activeConsole {
                        Button("Try again") { rp.connect(c) }
                    }
                    Button("Close") { close() }
                }
            }
            .padding(32)
        case .idle:
            VStack(spacing: 12) {
                Text("Not connected").font(.title3)
                Button("Close") { close() }
            }
        case .streaming:
            if rp.controllerName == nil {
                VStack {
                    Label("Connect a controller in Settings › Bluetooth", systemImage: "gamecontroller")
                        .padding(12)
                        .background(.black.opacity(0.6), in: Capsule())
                    Spacer()
                }
                .padding(.top, 24)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 16) {
            #if os(visionOS)
            Button {
                Task {
                    rp.cinemaShowing = true
                    rp.frameSink.setCinema(true)
                    let result = await openSpace(id: ImmersiveScreenSpace.id)
                    if case .opened = result {
                        dismissWindow(id: RemotePlayWindow.id)
                    } else {
                        rp.cinemaShowing = false
                        rp.frameSink.setCinema(false)
                    }
                    DiagLog.log("remote play cinema → \(result)", "rp")
                }
            } label: { Label("Cinema", systemImage: "rectangle.inset.filled.on.rectangle") }
                .disabled(rp.state != .streaming || immersive.isOpen)
            #endif
            Button { showStats.toggle() } label: { Label("Stats", systemImage: "chart.bar") }
            Button { rp.sleepConsole() } label: { Label("Rest mode", systemImage: "moon.fill") }
                .disabled(rp.state != .streaming)
            Button(role: .destructive) { rp.disconnect(); close() } label: { Label("Disconnect", systemImage: "xmark.circle") }
        }
        .labelStyle(.titleAndIcon)
    }

    private var statsOverlay: some View {
        VStack {
            HStack {
                RemotePlayStatsLabel(stats: rp.stats)
                    .padding(10)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
                Spacer()
            }
            Spacer()
        }
        .padding(20)
    }

    private func close() {
        #if os(visionOS)
        dismissWindow(id: RemotePlayWindow.id)
        #else
        dismiss()
        #endif
    }
}

/// Only this redraws once a second.
private struct RemotePlayStatsLabel: View {
    @ObservedObject var stats: RemotePlayStats
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(stats.size) · \(stats.fps) fps")
            Text("lost \(stats.lost) · decode errors \(stats.failed)")
            Text("audio \(stats.audioMs) ms · underruns \(stats.underruns)")
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.white)
    }
}

/// UIView backed by an `AVSampleBufferDisplayLayer` that the frame sink enqueues into.
struct RemotePlayLayerView: UIViewRepresentable {
    let sink: RemotePlayFrameSink

    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
        var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
    }

    func makeUIView(context: Context) -> LayerView {
        let v = LayerView()
        v.backgroundColor = .black
        v.displayLayer.videoGravity = .resizeAspect
        sink.attach(v.displayLayer)
        return v
    }

    func updateUIView(_ uiView: LayerView, context: Context) {
        sink.attach(uiView.displayLayer)
    }

    static func dismantleUIView(_ uiView: LayerView, coordinator: ()) {
        RemotePlayController.shared.frameSink.detach(uiView.displayLayer)
    }
}
