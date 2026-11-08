import SwiftUI
import AVKit

/// Picks the backend for an item: FFmpeg (KSPlayer) by default, AVPlayer as fallback.
struct PlayerView: View {
    let item: MediaItem
    /// Called with the next item when playback ends and autoplay is on.
    var onPlayNext: ((MediaItem) -> Void)? = nil

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var bassLink: BassLink
    @State private var resolved: MediaItem?
    @State private var resolveError: String?

    var body: some View {
        Group {
            if let resolved, let url = library.url(for: resolved) {
                switch library.effectiveBackend(for: resolved) {
                case .ffmpeg:
                    FFmpegPlayerView(item: resolved, url: url) {
                        if library.autoplayNext, let next = library.next(after: item) { onPlayNext?(next) }
                    }
                case .avplayer:
                    AVPlayerBackendView(item: resolved, url: url)
                }
            } else if let err = resolveError {
                ContentUnavailableView("Can't play this", systemImage: "exclamationmark.triangle", description: Text(err))
            } else if resolved != nil {
                ContentUnavailableView("No stream URL", systemImage: "exclamationmark.triangle",
                                       description: Text("The server did not provide a playable file for this item."))
            } else {
                ProgressView("Fetching stream…")
            }
        }
        .task(id: item.id) {
            resolved = nil
            resolveError = nil
            do { resolved = try await library.resolve(item) } catch { resolveError = error.localizedDescription }
        }
        .navigationTitle(item.title)
        #if os(visionOS)
        .toolbar {
            ToolbarItem(placement: .bottomOrnament) {
                HStack(spacing: 16) {
                    ImmersiveScreenToggle()
                    stereoPicker
                    projectionPicker
                }
            }
        }
        #else
        .toolbar {
            ToolbarItem(placement: .automatic) { stereoPicker }
        }
        #endif
    }

    /// Flat / VR180 / VR360 for the cinema screen.
    private var projectionPicker: some View {
        Picker(selection: Binding(
            get: { library.projectionOverride(for: item) ?? library.effectiveProjection(for: item) },
            set: { library.setProjectionOverride($0 == (item.projection ?? .flat) ? nil : $0, for: item) }
        )) {
            ForEach(ScreenProjection.allCases) { Text($0.label).tag($0) }
        } label: {
            Label("Projection", systemImage: "globe")
        }
        .pickerStyle(.menu)
    }

    /// 3D packing override. "Auto" shows what was detected.
    private var stereoPicker: some View {
        let detected = item.stereo?.label ?? "2D"
        return Picker(selection: Binding(
            get: { library.stereoOverride(for: item) },
            set: { library.setStereoOverride($0, for: item) }
        )) {
            Text("Auto (\(detected))").tag(StereoFormat.auto)
            ForEach(StereoFormat.allCases.filter { $0 != .auto }) { Text($0.label).tag($0) }
        } label: {
            Label("3D", systemImage: "view.3d")
        }
        .pickerStyle(.menu)
    }
}

/// AVPlayer backend (MP4/MOV, H.264/HEVC, AAC/AC‑3/E‑AC‑3; other files via server remux).
struct AVPlayerBackendView: View {
    let item: MediaItem
    let url: URL

    @EnvironmentObject private var bassLink: BassLink
    @StateObject private var controller: PlayerController

    init(item: MediaItem, url: URL) {
        self.item = item
        self.url = url
        _controller = StateObject(wrappedValue: PlayerController(bassLink: BassLinkHolder.shared))
    }

    var body: some View {
        VStack(spacing: 0) {
            VideoPlayer(player: controller.player)
                .aspectRatio(16/9, contentMode: .fit)

            HStack(spacing: 16) {
                Text(item.title).font(.headline)
                Spacer()
                Label(controller.tapInstalled ? "Bass tap on" : "Bass tap off",
                      systemImage: controller.tapInstalled ? "waveform" : "waveform.slash")
                    .foregroundStyle(controller.tapInstalled ? .green : .secondary)
                Text(controller.status).font(.footnote).foregroundStyle(.secondary)
            }
            .padding()
        }
        .onAppear {
            if bassLink.state == .off { bassLink.start() }
            controller.load(url: url)
            ImmersiveScreenBridge.shared.frameSource = nil
            ImmersiveScreenBridge.shared.stereoFormat = .mono
            ImmersiveScreenBridge.shared.avPlayer = controller.player
        }
        .onDisappear {
            controller.stop()
            ImmersiveScreenBridge.shared.avPlayer = nil
        }
    }
}

/// Lets `PlayerView` reach the app-wide `BassLink` at `@StateObject` init time.
/// Set once in `BassPlayerApp`.
enum BassLinkHolder {
    static var shared: BassLink!
}
