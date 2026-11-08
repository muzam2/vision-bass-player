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
            DiagLog.log("open \(item.source.rawValue) · \(item.title) · \(item.container ?? "?")/\(item.videoCodec ?? "?") \(item.width ?? 0)x\(item.height ?? 0) \(item.videoRange ?? "") stereo=\(item.stereo?.rawValue ?? "-")", "player")
            do { resolved = try await library.resolve(item) } catch {
                resolveError = error.localizedDescription
                DiagLog.log("resolve failed: \(error.localizedDescription)", "player")
            }
        }
        .navigationTitle(item.title)
        #if os(visionOS)
        .toolbar(.hidden, for: .navigationBar)   // the player chrome carries its own title + controls
        #else
        .toolbar {
            ToolbarItem(placement: .automatic) { StereoPickerMenu(item: item) }
        }
        #endif
    }
}

/// Flat / VR180 / VR360 for the cinema screen.
struct ProjectionPickerMenu: View {
    let item: MediaItem
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        Menu {
            Picker("Projection", selection: Binding(
                get: { library.projectionOverride(for: item) ?? library.effectiveProjection(for: item) },
                set: { library.setProjectionOverride($0 == (item.projection ?? .flat) ? nil : $0, for: item) }
            )) {
                ForEach(ScreenProjection.allCases) { Text($0.label).tag($0) }
            }
        } label: {
            Image(systemName: library.effectiveProjection(for: item) == .flat ? "globe" : "globe.badge.chevron.backward")
        }
        .help("Projection")
    }
}

/// 3D packing override. "Auto" shows what was detected.
struct StereoPickerMenu: View {
    let item: MediaItem
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        let detected = item.stereo?.label ?? "2D"
        Menu {
            Picker("3D", selection: Binding(
                get: { library.stereoOverride(for: item) },
                set: { library.setStereoOverride($0, for: item) }
            )) {
                Text("Auto (\(detected))").tag(StereoFormat.auto)
                ForEach(StereoFormat.allCases.filter { $0 != .auto }) { Text($0.label).tag($0) }
            }
        } label: {
            Image(systemName: library.effectiveStereo(for: item).isPacked || library.effectiveStereo(for: item) == .mvHEVC ? "view.3d" : "view.2d")
        }
        .help("3D format")
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
                #if os(visionOS)
                ImmersiveScreenToggle()
                #endif
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
            ImmersiveScreenBridge.shared.pushFrame = nil
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
